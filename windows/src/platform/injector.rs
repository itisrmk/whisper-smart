//! Text injection into the focused application.
//!
//! Port of `ClipboardInjector.swift`. The macOS build's first strategy is the
//! Accessibility API: read `AXValue` off the focused control and write the
//! transcript straight into it. Windows' UI Automation could do something
//! similar in theory, but in practice it is patchy across the apps that matter
//! (Electron, browsers, terminals). The dependable equivalent — the same
//! choice the Linux build made with `wtype` — is to synthesise the text itself
//! as Unicode keystrokes with `SendInput`, so that takes the first slot.
//!
//! Strategies, in order:
//!   1. **Type** the text via `SendInput` with `KEYEVENTF_UNICODE`. Works in
//!      every focused text field, including terminals, is layout-independent,
//!      and never touches the clipboard.
//!   2. **Paste**: copy to the clipboard, synthesise Ctrl+V, then restore the
//!      previous clipboard — the direct analogue of the macOS pasteboard
//!      fallback, including its snapshot/restore and its terminal-aware
//!      delays.

use std::time::Duration;

use crate::core::settings::{InjectionMode, InjectionSettings};
use crate::core::state_machine::TextInjecting;
use crate::platform::focus;

/// Longer paste delay for terminals, whose console host processes paste
/// input asynchronously.
const TERMINAL_PASTE_DELAY: Duration = Duration::from_millis(80);
/// Upper bound on a transcript typed keystroke by keystroke. Past this a
/// paste is both faster and kinder to the receiving app's input queue.
const MAX_TYPED_BYTES: usize = 16 * 1024;
/// Terminals may read the clipboard well after the paste key is delivered.
const TERMINAL_RESTORE_DELAY: Duration = Duration::from_millis(1_500);

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
        // that on the UI thread would freeze the overlay mid-animation, so
        // the whole sequence runs on its own thread.
        std::thread::Builder::new()
            .name("text-injection".to_string())
            .spawn(move || perform_injection(&text, &settings))
            .map(|_| ())
            .unwrap_or_else(|err| tracing::error!("could not spawn injection thread: {err}"));
    }
}

fn perform_injection(text: &str, settings: &InjectionSettings) {
    let focused = focus::focused_window();
    let is_terminal = focused.app_id().is_some_and(focus::is_terminal);
    if is_terminal {
        tracing::info!("focused window is a terminal; using terminal-aware injection");
    }

    match settings.mode {
        InjectionMode::TypeOnly => {
            // The user ruled the clipboard out, so a newline here is typed as
            // the Enter it maps to, submit risk and all.
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
/// There is no keystroke that means "newline" — a typed `\r` is Enter, which
/// in a chat box or a search field submits the form instead of inserting a
/// line break. The macOS build never has this problem: both of its strategies
/// (AX `AXValue` and Command-V) insert a newline as text. Pasting is the
/// closest equivalent here, so multi-line transcripts take that route — the
/// same rule the Linux build applies to `wtype`.
fn is_safe_to_type(text: &str) -> bool {
    !text.contains(['\n', '\r']) && text.len() <= MAX_TYPED_BYTES
}

// ---------------------------------------------------------------------------
// Strategy 1: type the text
// ---------------------------------------------------------------------------

/// Types `text` as `KEYEVENTF_UNICODE` key events. Returns false on failure so
/// the caller can fall back to pasting.
///
/// `KEYEVENTF_UNICODE` carries the character itself rather than a scan code,
/// so this is independent of the keyboard layout — "é" types as "é" on a US
/// layout — and surrogate pairs travel as their two UTF-16 units, which the
/// input system reassembles.
#[cfg(windows)]
fn type_text(text: &str) -> bool {
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE,
        VIRTUAL_KEY,
    };

    if text.len() > MAX_TYPED_BYTES {
        tracing::warn!("transcript is {} bytes, too long to type", text.len());
        return false;
    }

    let key = |unit: u16, up: bool| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(0),
                wScan: unit,
                dwFlags: if up {
                    KEYEVENTF_UNICODE | KEYEVENTF_KEYUP
                } else {
                    KEYEVENTF_UNICODE
                },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };

    let mut inputs: Vec<INPUT> = Vec::new();
    for unit in text.encode_utf16() {
        inputs.push(key(unit, false));
        inputs.push(key(unit, true));
    }

    // Batched rather than one giant call: some apps drop input when their
    // message queue is flooded, and a short breather between batches keeps
    // long transcripts intact.
    for batch in inputs.chunks(128) {
        let sent = unsafe { SendInput(batch, std::mem::size_of::<INPUT>() as i32) };
        if sent != batch.len() as u32 {
            tracing::warn!("SendInput delivered {sent}/{} events", batch.len());
            return false;
        }
        std::thread::sleep(Duration::from_millis(1));
    }
    true
}

#[cfg(not(windows))]
fn type_text(_text: &str) -> bool {
    false
}

// ---------------------------------------------------------------------------
// Strategy 2: clipboard + synthesised paste
// ---------------------------------------------------------------------------

fn paste_text(text: &str, settings: &InjectionSettings, is_terminal: bool) {
    let snapshot = if settings.restore_clipboard {
        read_clipboard_text()
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
        Some(previous) => {
            if copy_to_clipboard(&previous) {
                tracing::debug!("clipboard restored");
            }
        }
        // Nothing textual was there before. What was there may have been an
        // image or files, which this snapshot deliberately does not carry
        // (holding arbitrary formats per dictation is not worth megabytes);
        // clearing beats leaving the transcript behind as a surprise paste.
        None => clear_clipboard(),
    }
}

/// Sends Ctrl+V. Windows Terminal, the legacy console host, and every GUI
/// field accept it, so unlike Linux (Ctrl+Shift+V for terminals) one shortcut
/// serves everything; terminals differ only in the delays around it.
#[cfg(windows)]
fn synthesise_paste(is_terminal: bool) {
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
        VIRTUAL_KEY, VK_CONTROL,
    };

    const VK_V: VIRTUAL_KEY = VIRTUAL_KEY(0x56);
    let key = |vk: VIRTUAL_KEY, up: bool| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: vk,
                wScan: 0,
                dwFlags: if up {
                    KEYEVENTF_KEYUP
                } else {
                    KEYBD_EVENT_FLAGS(0)
                },
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };

    let sequence = [
        key(VK_CONTROL, false),
        key(VK_V, false),
        key(VK_V, true),
        key(VK_CONTROL, true),
    ];
    let sent = unsafe { SendInput(&sequence, std::mem::size_of::<INPUT>() as i32) };
    if sent == sequence.len() as u32 {
        tracing::info!("paste synthesised (terminal={is_terminal})");
    } else {
        tracing::error!("paste synthesis delivered {sent}/{} events", sequence.len());
    }
}

#[cfg(not(windows))]
fn synthesise_paste(_is_terminal: bool) {}

fn copy_to_clipboard(text: &str) -> bool {
    match arboard::Clipboard::new().and_then(|mut c| c.set_text(text.to_string())) {
        Ok(()) => true,
        Err(err) => {
            tracing::error!("clipboard write failed: {err}");
            false
        }
    }
}

fn read_clipboard_text() -> Option<String> {
    arboard::Clipboard::new().ok()?.get_text().ok()
}

fn clear_clipboard() {
    if let Ok(mut clipboard) = arboard::Clipboard::new() {
        let _ = clipboard.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_newline_is_never_typed_because_it_lands_as_enter() {
        // Typing a newline presses Enter, which submits a chat box or a
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
    fn a_transcript_too_long_to_type_is_pasted_instead() {
        let long = "a".repeat(MAX_TYPED_BYTES + 1);
        assert!(!is_safe_to_type(&long));
        assert!(is_safe_to_type(&"a".repeat(MAX_TYPED_BYTES)));
    }

    #[test]
    fn non_ascii_transcripts_are_still_typeable() {
        // KEYEVENTF_UNICODE is layout-independent, so accents and CJK must
        // not be shunted onto the clipboard path by length or content checks.
        assert!(is_safe_to_type("héllo wörld"));
        assert!(is_safe_to_type("日本語のテキスト"));
        assert!(is_safe_to_type("emoji 🙂 too"));
    }

    #[test]
    fn empty_transcripts_are_never_injected() {
        // inject() short-circuits before spawning anything.
        let injector = Injector::new(InjectionSettings::default());
        injector.inject("");
        injector.inject("   \n  ");
        // Reaching here without touching the clipboard is the assertion.
    }
}
