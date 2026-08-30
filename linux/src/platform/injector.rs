//! Text injection into the focused application.
//!
//! Port of `ClipboardInjector.swift`. The macOS build's first strategy is the
//! Accessibility API: read `AXValue` off the focused control and write the
//! transcript straight into it. Wayland has nothing comparable and never will —
//! letting one client read another's text field is exactly what the security
//! model exists to prevent. The closest equivalent is to synthesise the text
//! as keystrokes through the virtual-keyboard protocol, which is what `wtype`
//! does, so that takes the first slot in the strategy order.
//!
//! Strategies, in order:
//!   1. **Type** the text with `wtype`. Works in every focused text field,
//!      including terminals, and never touches the clipboard.
//!   2. **Paste**: copy with `wl-copy`, synthesise the paste shortcut, then
//!      restore the previous clipboard — the direct analogue of the macOS
//!      pasteboard fallback, including its snapshot/restore and its
//!      terminal-aware delays.

use std::io::Write;
use std::process::{Command, Stdio};
use std::time::Duration;

use crate::core::settings::{InjectionMode, InjectionSettings};
use crate::core::state_machine::TextInjecting;
use crate::platform::compositor;

/// Longer paste delay for terminals, whose PTY handles paste asynchronously.
const TERMINAL_PASTE_DELAY: Duration = Duration::from_millis(80);
/// Upper bound on a transcript handed to `wtype` as a single argument. The
/// kernel caps one argv entry at 128 KiB (`MAX_ARG_STRLEN`); anything near
/// that is pasted instead.
const MAX_TYPED_BYTES: usize = 16 * 1024;
/// Terminals may read the clipboard well after the paste key is delivered.
const TERMINAL_RESTORE_DELAY: Duration = Duration::from_millis(1_500);

/// One clipboard MIME type and its bytes, for snapshot/restore.
struct ClipboardSnapshot {
    mime: String,
    bytes: Vec<u8>,
}

pub struct Injector {
    settings: InjectionSettings,
}

impl Injector {
    pub fn new(settings: InjectionSettings) -> Self {
        Self { settings }
    }
}

impl TextInjecting for Injector {
    fn inject(&self, text: &str) {
        let text = text.trim().to_string();
        if text.is_empty() {
            return;
        }
        let settings = self.settings.clone();

        // Injection sleeps between the copy, the paste, and the restore. Doing
        // that on the GTK main loop would freeze the overlay mid-animation, so
        // the whole sequence runs on its own thread.
        std::thread::Builder::new()
            .name("text-injection".to_string())
            .spawn(move || perform_injection(&text, &settings))
            .map(|_| ())
            .unwrap_or_else(|err| tracing::error!("could not spawn injection thread: {err}"));
    }
}

fn perform_injection(text: &str, settings: &InjectionSettings) {
    let focused = compositor::focused_window();
    let is_terminal = focused.app_id().is_some_and(compositor::is_terminal);
    if is_terminal {
        tracing::info!("focused window is a terminal; using terminal-aware injection");
    }

    match settings.mode {
        InjectionMode::TypeOnly => {
            // The user ruled the clipboard out, so a newline here is typed as
            // the Return key it asks for, submit risk and all.
            if !type_text(text) {
                tracing::error!("typing failed and type-only mode forbids the paste fallback");
            }
        }
        InjectionMode::PasteOnly => paste_text(text, settings, is_terminal),
        InjectionMode::Smart => {
            if !is_safe_to_type(text) {
                tracing::info!("transcript is not safe to type; pasting instead");
                paste_text(text, settings, is_terminal);
            } else if type_text(text) {
                tracing::info!("text injected by typing");
            } else {
                tracing::info!("typing unavailable; falling back to paste");
                paste_text(text, settings, is_terminal);
            }
        }
    }
}

/// Whether `text` can be typed keystroke by keystroke without surprises.
///
/// There is no keystroke that means "newline" — `wtype` types one as the
/// Return key, which in a chat box or a search field submits the form instead
/// of inserting a line break. The macOS build never has this problem: both of
/// its strategies (AX `AXValue` and Command-V) insert a newline as text.
/// Pasting is the closest Linux equivalent, so multi-line transcripts take
/// that route.
fn is_safe_to_type(text: &str) -> bool {
    !text.contains(['\n', '\r']) && text.len() <= MAX_TYPED_BYTES
}

// ---------------------------------------------------------------------------
// Strategy 1: type the text
// ---------------------------------------------------------------------------

/// Types `text` via `wtype`. Returns false when wtype is missing or fails, so
/// the caller can fall back to pasting.
///
/// The transcript goes in argv, never on stdin, and that matters. `wtype -`
/// types stdin in 100-character batches, and because it assigns keycodes to
/// characters as it first meets them, it uploads a *new, larger* keymap
/// between batches and starts sending key events immediately. Clients apply a
/// keymap asynchronously, so every character first seen after the 100th
/// arrives while the client still holds the previous keymap: it carries no
/// keysym and is silently dropped, and the one that lands on wire keycode 28 —
/// `KEY_ENTER` — is read as a bare Return by clients that map hardware codes
/// directly (Chromium and Electron do), submitting the field halfway through
/// the transcript. Passing the text as an argument takes wtype's other path,
/// which resolves every keysym up front and uploads the keymap exactly once,
/// before the first keystroke.
fn type_text(text: &str) -> bool {
    if text.len() > MAX_TYPED_BYTES {
        tracing::warn!(
            "transcript is {} bytes, too long to pass to wtype as an argument",
            text.len()
        );
        return false;
    }

    // `--` ends option parsing, so a transcript starting with a dash is typed
    // rather than read as a flag. Command::arg hands the text to execve
    // verbatim — no shell — so quotes and dashes inside it need no escaping.
    let output = Command::new("wtype")
        .arg("--")
        .arg(text)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output();

    match output {
        Ok(output) if output.status.success() => true,
        Ok(output) => {
            tracing::warn!(
                "wtype exited with {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            );
            false
        }
        Err(err) => {
            tracing::warn!("wtype unavailable ({err}); install the `wtype` package");
            false
        }
    }
}

// ---------------------------------------------------------------------------
// Strategy 2: clipboard + synthesised paste
// ---------------------------------------------------------------------------

fn paste_text(text: &str, settings: &InjectionSettings, is_terminal: bool) {
    let snapshot = if settings.restore_clipboard {
        capture_clipboard()
    } else {
        None
    };

    if !copy_to_clipboard(text) {
        tracing::error!("could not place the transcript on the clipboard; injection failed");
        return;
    }

    let paste_delay = if is_terminal {
        TERMINAL_PASTE_DELAY.max(Duration::from_millis(settings.paste_delay_ms))
    } else {
        Duration::from_millis(settings.paste_delay_ms)
    };
    std::thread::sleep(paste_delay);

    synthesise_paste(is_terminal);

    if !settings.restore_clipboard {
        return;
    }

    let restore_delay = if is_terminal {
        TERMINAL_RESTORE_DELAY.max(Duration::from_millis(settings.restore_delay_ms))
    } else {
        Duration::from_millis(settings.restore_delay_ms)
    };
    std::thread::sleep(restore_delay);

    // If the user copied something else in the meantime, their copy wins.
    // This is the equivalent of the macOS `changeCount` guard.
    match read_clipboard_text() {
        Some(current) if current.trim() == text.trim() => {}
        Some(_) => {
            tracing::info!("clipboard changed externally; skipping restore");
            return;
        }
        None => {}
    }

    match snapshot {
        Some(snapshot) => restore_clipboard(&snapshot),
        // Nothing was there before, so leaving the transcript would be an
        // unexpected change; clear it instead.
        None => {
            let _ = Command::new("wl-copy").arg("--clear").status();
        }
    }
}

/// Sends the paste shortcut. Terminals use Ctrl+Shift+V, everything else
/// Ctrl+V — the Linux counterpart to the macOS ⌘V synthesis.
fn synthesise_paste(is_terminal: bool) {
    let mut command = Command::new("wtype");
    if is_terminal {
        command.args([
            "-M", "ctrl", "-M", "shift", "-k", "v", "-m", "shift", "-m", "ctrl",
        ]);
    } else {
        command.args(["-M", "ctrl", "-k", "v", "-m", "ctrl"]);
    }

    match command.stdout(Stdio::null()).stderr(Stdio::null()).status() {
        Ok(status) if status.success() => {
            tracing::info!("paste synthesised (terminal={is_terminal})");
        }
        Ok(status) => tracing::error!("paste synthesis exited with {status}"),
        Err(err) => tracing::error!("could not synthesise paste: {err}"),
    }
}

fn copy_to_clipboard(text: &str) -> bool {
    // --foreground would block; the default forked wl-copy keeps serving the
    // selection after this call returns, which is exactly what is wanted.
    let child = Command::new("wl-copy")
        .args(["--type", "text/plain;charset=utf-8"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();

    let mut child = match child {
        Ok(child) => child,
        Err(err) => {
            tracing::error!("wl-copy unavailable ({err}); install `wl-clipboard`");
            return false;
        }
    };
    if let Some(stdin) = child.stdin.as_mut() {
        if stdin.write_all(text.as_bytes()).is_err() {
            let _ = child.kill();
            return false;
        }
    }
    drop(child.stdin.take());
    child.wait().map(|s| s.success()).unwrap_or(false)
}

fn read_clipboard_text() -> Option<String> {
    let output = Command::new("wl-paste")
        .args(["--no-newline"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Snapshots the clipboard's preferred type and its raw bytes.
///
/// This is narrower than the macOS version, which round-trips every type on
/// every pasteboard item. Wayland offers one selection with a type list, and
/// preserving the first offered type covers the realistic cases (text, and
/// images pasted from a browser) without holding several megabytes per
/// dictation.
fn capture_clipboard() -> Option<ClipboardSnapshot> {
    let types = Command::new("wl-paste").arg("--list-types").output().ok()?;
    if !types.status.success() {
        return None;
    }
    let listing = String::from_utf8_lossy(&types.stdout);
    let mime = listing
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())?
        .to_string();

    let content = Command::new("wl-paste")
        .args(["--type", &mime])
        .output()
        .ok()?;
    if !content.status.success() {
        return None;
    }
    Some(ClipboardSnapshot {
        mime,
        bytes: content.stdout,
    })
}

fn restore_clipboard(snapshot: &ClipboardSnapshot) {
    let child = Command::new("wl-copy")
        .args(["--type", &snapshot.mime])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();

    let Ok(mut child) = child else {
        tracing::error!("could not restore the clipboard");
        return;
    };
    if let Some(stdin) = child.stdin.as_mut() {
        let _ = stdin.write_all(&snapshot.bytes);
    }
    drop(child.stdin.take());
    let _ = child.wait();
    tracing::debug!("clipboard restored ({})", snapshot.mime);
}

/// Reports which injection tools are installed, for the settings diagnostics.
pub fn available_tools() -> InjectionTools {
    InjectionTools {
        wtype: which("wtype"),
        wl_copy: which("wl-copy"),
        wl_paste: which("wl-paste"),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InjectionTools {
    pub wtype: bool,
    pub wl_copy: bool,
    pub wl_paste: bool,
}

impl InjectionTools {
    /// True when at least one complete strategy is available.
    pub fn any_strategy_available(&self) -> bool {
        self.wtype || self.wl_copy
    }

    pub fn missing_summary(&self) -> Option<String> {
        let mut missing = Vec::new();
        if !self.wtype {
            missing.push("wtype");
        }
        if !self.wl_copy || !self.wl_paste {
            missing.push("wl-clipboard");
        }
        if missing.is_empty() {
            return None;
        }
        Some(format!(
            "Install for reliable text insertion: sudo pacman -S {}",
            missing.join(" ")
        ))
    }
}

fn which(binary: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| {
            std::env::split_paths(&paths).any(|dir| {
                let candidate = dir.join(binary);
                candidate.is_file()
            })
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_tools_are_reported_with_the_package_to_install() {
        let none = InjectionTools {
            wtype: false,
            wl_copy: false,
            wl_paste: false,
        };
        let summary = none.missing_summary().expect("should report missing tools");
        assert!(summary.contains("wtype"));
        assert!(summary.contains("wl-clipboard"));
        assert!(!none.any_strategy_available());
    }

    #[test]
    fn a_complete_install_reports_nothing_missing() {
        let all = InjectionTools {
            wtype: true,
            wl_copy: true,
            wl_paste: true,
        };
        assert_eq!(all.missing_summary(), None);
        assert!(all.any_strategy_available());
    }

    #[test]
    fn typing_alone_is_still_a_usable_strategy() {
        // wtype covers every field including terminals, so a system without
        // wl-clipboard can still dictate.
        let typing_only = InjectionTools {
            wtype: true,
            wl_copy: false,
            wl_paste: false,
        };
        assert!(typing_only.any_strategy_available());
        assert!(
            typing_only.missing_summary().is_some(),
            "but it should still nudge"
        );
    }

    #[test]
    fn paste_only_is_a_usable_strategy() {
        let paste_only = InjectionTools {
            wtype: false,
            wl_copy: true,
            wl_paste: true,
        };
        assert!(paste_only.any_strategy_available());
    }

    #[test]
    fn which_finds_a_binary_that_exists_and_misses_one_that_does_not() {
        assert!(which("sh"), "sh should be on PATH");
        assert!(!which("definitely-not-a-real-binary-xyzzy"));
    }

    #[test]
    fn a_newline_is_never_typed_because_wtype_sends_it_as_return() {
        // Typing a newline presses Return, which submits a chat box or a
        // search field instead of inserting a line break. Those transcripts
        // must go through the clipboard.
        assert!(!is_safe_to_type("first line\nsecond line"));
        assert!(!is_safe_to_type("paragraph\n\nbreak"));
        assert!(!is_safe_to_type("carriage\rreturn"));
        assert!(is_safe_to_type(
            "one single line, dashes - and 'quotes' included"
        ));
    }

    #[test]
    fn a_transcript_too_long_for_argv_is_pasted_instead() {
        let long = "a".repeat(MAX_TYPED_BYTES + 1);
        assert!(!is_safe_to_type(&long));
        assert!(is_safe_to_type(&"a".repeat(MAX_TYPED_BYTES)));
    }

    #[test]
    fn a_transcript_longer_than_one_wtype_stdin_batch_is_still_typeable() {
        // The bug this guards: `wtype -` typed stdin in 100-character batches,
        // re-uploading its keymap between them, so characters first seen after
        // the 100th were dropped and one of them arrived as Return. Length
        // alone must not push a plain transcript onto the paste path — the
        // argv call site is what makes it safe.
        let long_line = "I want to optimize the amount of memory it takes to run \
            the application. This optimization is that I want to do specifically \
            on Linux because I think it's using Rust as the main runtime.";
        assert!(long_line.len() > 100);
        assert!(is_safe_to_type(long_line));
    }

    #[test]
    fn empty_transcripts_are_never_injected() {
        // inject() short-circuits before spawning anything.
        let injector = Injector::new(InjectionSettings::default());
        injector.inject("");
        injector.inject("   \n  ");
        // Reaching here without spawning a wtype process is the assertion.
    }
}
