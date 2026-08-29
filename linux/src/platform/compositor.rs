//! Focused-window identification.
//!
//! macOS asks `NSWorkspace` for the frontmost application's bundle ID. Wayland
//! has no equivalent protocol — a client cannot ask who has focus — so this
//! goes through whichever compositor is running:
//!
//!   * Hyprland and Sway expose the focused window over their own IPC;
//!   * X11 sessions can be asked via `xdotool`;
//!   * anything else returns [`FocusedWindow::Unknown`], and the caller falls
//!     back to conservative defaults rather than guessing.
//!
//! The only thing the app needs this for is terminal detection, which changes
//! the paste shortcut and the timing around it.

use std::process::Command;

/// The focused window's application identifier, if it can be determined.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FocusedWindow {
    /// Wayland `app_id` / X11 `WM_CLASS`, lowercased.
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
/// A PTY processes a paste asynchronously, so the clipboard has to stay intact
/// noticeably longer than for a GUI text field — the same reason the macOS
/// build keeps its own list of terminal bundle IDs.
const TERMINAL_APP_IDS: &[&str] = &[
    "alacritty",
    "com.mitchellh.ghostty",
    "contour",
    "dev.warp.warp",
    "foot",
    "footclient",
    "ghostty",
    "guake",
    "gnome-terminal",
    "hyper",
    "io.elementary.terminal",
    "kitty",
    "konsole",
    "org.gnome.terminal",
    "org.gnome.console",
    "org.kde.konsole",
    "org.wezfurlong.wezterm",
    "rio",
    "st",
    "terminator",
    "tilix",
    "urxvt",
    "wezterm",
    "xfce4-terminal",
    "xterm",
];

/// Returns true when `app_id` looks like a terminal emulator.
pub fn is_terminal(app_id: &str) -> bool {
    let id = app_id.trim().to_ascii_lowercase();
    if id.is_empty() {
        return false;
    }
    if TERMINAL_APP_IDS.contains(&id.as_str()) {
        return true;
    }
    // Catch-all for the long tail (`foo-terminal`, `some.terminal.emulator`).
    // Deliberately not matching bare "term", which would hit "Termius" and
    // other non-terminals.
    id.ends_with("-terminal") || id.ends_with(".terminal") || id.ends_with("terminal")
}

/// Identifies the focused window via the running compositor.
pub fn focused_window() -> FocusedWindow {
    if std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some() {
        if let Some(id) = hyprland_focused() {
            return FocusedWindow::Known(id);
        }
    }
    if std::env::var_os("SWAYSOCK").is_some() {
        if let Some(id) = sway_focused() {
            return FocusedWindow::Known(id);
        }
    }
    if std::env::var_os("WAYLAND_DISPLAY").is_none() && std::env::var_os("DISPLAY").is_some() {
        if let Some(id) = x11_focused() {
            return FocusedWindow::Known(id);
        }
    }
    FocusedWindow::Unknown
}

fn hyprland_focused() -> Option<String> {
    let output = Command::new("hyprctl")
        .args(["activewindow", "-j"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    let class = json.get("class")?.as_str()?.trim();
    if class.is_empty() {
        return None;
    }
    Some(class.to_ascii_lowercase())
}

fn sway_focused() -> Option<String> {
    let output = Command::new("swaymsg")
        .args(["-t", "get_tree", "-r"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    let node = find_focused_node(&json)?;
    // Native Wayland windows carry app_id; XWayland ones only have window_properties.class.
    let id = node
        .get("app_id")
        .and_then(|v| v.as_str())
        .or_else(|| node.get("window_properties")?.get("class")?.as_str())?;
    let id = id.trim();
    if id.is_empty() {
        return None;
    }
    Some(id.to_ascii_lowercase())
}

fn find_focused_node(node: &serde_json::Value) -> Option<&serde_json::Value> {
    if node.get("focused").and_then(|v| v.as_bool()) == Some(true) {
        return Some(node);
    }
    for key in ["nodes", "floating_nodes"] {
        if let Some(children) = node.get(key).and_then(|v| v.as_array()) {
            for child in children {
                if let Some(found) = find_focused_node(child) {
                    return Some(found);
                }
            }
        }
    }
    None
}

fn x11_focused() -> Option<String> {
    let output = Command::new("xdotool")
        .args(["getactivewindow", "getwindowclassname"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let class = String::from_utf8_lossy(&output.stdout)
        .trim()
        .to_ascii_lowercase();
    if class.is_empty() {
        None
    } else {
        Some(class)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_terminals_are_detected() {
        for id in [
            "kitty",
            "Alacritty",
            "foot",
            "com.mitchellh.ghostty",
            "org.wezfurlong.wezterm",
        ] {
            assert!(is_terminal(id), "{id} should be treated as a terminal");
        }
    }

    #[test]
    fn the_suffix_rule_catches_the_long_tail() {
        assert!(is_terminal("xfce4-terminal"));
        assert!(is_terminal("org.gnome.Terminal"));
        assert!(is_terminal("some-terminal"));
    }

    #[test]
    fn ordinary_apps_are_not_terminals() {
        for id in ["firefox", "code", "org.gnome.Nautilus", "slack", "termius"] {
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
        assert!(is_terminal("KITTY"));
        assert!(is_terminal("Foot"));
    }

    #[test]
    fn unknown_focus_exposes_no_app_id() {
        assert_eq!(FocusedWindow::Unknown.app_id(), None);
        assert_eq!(FocusedWindow::Known("kitty".into()).app_id(), Some("kitty"));
    }

    #[test]
    fn the_focused_node_is_found_anywhere_in_a_sway_tree() {
        let tree = serde_json::json!({
            "focused": false,
            "nodes": [
                { "focused": false, "nodes": [] },
                {
                    "focused": false,
                    "nodes": [{ "focused": true, "app_id": "kitty" }]
                }
            ],
            "floating_nodes": []
        });
        let node = find_focused_node(&tree).expect("focused node");
        assert_eq!(node.get("app_id").unwrap(), "kitty");
    }

    #[test]
    fn a_tree_with_nothing_focused_yields_nothing() {
        let tree = serde_json::json!({ "focused": false, "nodes": [], "floating_nodes": [] });
        assert!(find_focused_node(&tree).is_none());
    }
}
