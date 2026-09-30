//! Focused-window identification.
//!
//! macOS asks `NSWorkspace` for the frontmost application's bundle ID; the
//! Linux build asks the compositor. On Windows the foreground window is a
//! straight Win32 query: `GetForegroundWindow` → owning process → executable
//! name. The only thing the app needs this for is terminal detection, which
//! changes the timing around a paste-based injection.

use std::path::Path;

/// The focused window's application identifier, if it can be determined.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FocusedWindow {
    /// Executable base name, lowercased, without the `.exe` suffix.
    Known(String),
    Unknown,
}

impl FocusedWindow {
    pub fn app_id(&self) -> Option<&str> {
        match self {
            FocusedWindow::Known(id) => Some(id),
            FocusedWindow::Unknown => None,
        }
    }
}

/// Terminal emulators that need terminal-aware paste handling.
///
/// A console host processes paste input asynchronously, so the clipboard has
/// to stay intact noticeably longer than for a GUI text field — the same
/// reason the macOS build keeps its own list of terminal bundle IDs.
const TERMINAL_APPS: &[&str] = &[
    "alacritty",
    "cmd",
    "conemu64",
    "conhost",
    "contour",
    "hyper",
    "kitty",
    "mintty", // Git Bash, Cygwin, MSYS2
    "openconsole",
    "powershell",
    "putty",
    "pwsh",
    "rio",
    "tabby",
    "warp",
    "wezterm-gui",
    "windowsterminal",
    "wt",
];

/// Returns true when `app_id` looks like a terminal emulator.
pub fn is_terminal(app_id: &str) -> bool {
    let id = app_id.trim().to_ascii_lowercase();
    if id.is_empty() {
        return false;
    }
    if TERMINAL_APPS.contains(&id.as_str()) {
        return true;
    }
    // Catch-all for the long tail (`foo-terminal`, `someterminal`).
    // Deliberately not matching bare "term", which would hit "Termius" and
    // other non-terminals.
    id.ends_with("-terminal") || id.ends_with(".terminal") || id.ends_with("terminal")
}

/// Identifies the process that owns the foreground window.
#[cfg(windows)]
pub fn focused_window() -> FocusedWindow {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId};

    unsafe {
        let hwnd = GetForegroundWindow();
        if hwnd.is_invalid() {
            return FocusedWindow::Unknown;
        }

        let mut pid: u32 = 0;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid == 0 {
            return FocusedWindow::Unknown;
        }

        let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return FocusedWindow::Unknown;
        };

        let mut buffer = [0u16; 1024];
        let mut length = buffer.len() as u32;
        let result = QueryFullProcessImageNameW(
            process,
            PROCESS_NAME_WIN32,
            windows::core::PWSTR(buffer.as_mut_ptr()),
            &mut length,
        );
        let _ = CloseHandle(process);

        if result.is_err() || length == 0 {
            return FocusedWindow::Unknown;
        }

        let path = String::from_utf16_lossy(&buffer[..length as usize]);
        match app_id_from_path(&path) {
            Some(id) => FocusedWindow::Known(id),
            None => FocusedWindow::Unknown,
        }
    }
}

#[cfg(not(windows))]
pub fn focused_window() -> FocusedWindow {
    FocusedWindow::Unknown
}

/// `C:\Program Files\WindowsApps\...\WindowsTerminal.exe` → `windowsterminal`.
///
/// Splits on both separators by hand rather than through [`Path`], so the
/// parsing behaves identically on the Unix development hosts this crate also
/// builds on (where `\` is not a separator).
#[cfg_attr(not(windows), allow(dead_code))]
fn app_id_from_path(path: &str) -> Option<String> {
    let file = path.trim().rsplit(['/', '\\']).next()?.trim();
    let stem = Path::new(file).file_stem()?.to_str()?.trim();
    if stem.is_empty() {
        return None;
    }
    Some(stem.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_terminals_are_detected() {
        for id in [
            "windowsterminal",
            "WindowsTerminal",
            "cmd",
            "pwsh",
            "powershell",
            "alacritty",
            "wezterm-gui",
            "mintty",
        ] {
            assert!(is_terminal(id), "{id} should be treated as a terminal");
        }
    }

    #[test]
    fn the_suffix_rule_catches_the_long_tail() {
        assert!(is_terminal("some-terminal"));
        assert!(is_terminal("FluentTerminal"));
    }

    #[test]
    fn ordinary_apps_are_not_terminals() {
        for id in ["firefox", "code", "explorer", "slack", "termius", "msedge"] {
            assert!(!is_terminal(id), "{id} should not be treated as a terminal");
        }
    }

    #[test]
    fn an_empty_app_id_is_not_a_terminal() {
        assert!(!is_terminal(""));
        assert!(!is_terminal("   "));
    }

    #[test]
    fn detection_is_case_insensitive() {
        assert!(is_terminal("CMD"));
        assert!(is_terminal("Alacritty"));
    }

    #[test]
    fn unknown_focus_exposes_no_app_id() {
        assert_eq!(FocusedWindow::Unknown.app_id(), None);
        assert_eq!(FocusedWindow::Known("cmd".into()).app_id(), Some("cmd"));
    }

    #[test]
    fn executable_paths_reduce_to_a_lowercase_stem() {
        assert_eq!(
            app_id_from_path(r"C:\Program Files\WindowsApps\Micro.T\WindowsTerminal.exe"),
            Some("windowsterminal".to_string())
        );
        assert_eq!(
            app_id_from_path(r"C:\Windows\System32\cmd.exe"),
            Some("cmd".to_string())
        );
        assert_eq!(app_id_from_path(""), None);
    }
}
