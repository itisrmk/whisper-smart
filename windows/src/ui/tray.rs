//! Notification-area (system tray) presence.
//!
//! Port of `MenuBarController.swift`. macOS uses `NSStatusItem`; the Linux
//! build speaks StatusNotifierItem over D-Bus; the Windows equivalent is a
//! `Shell_NotifyIcon` item, provided by the `tray-icon` crate on the UI
//! thread's message loop.
//!
//! Menu activations are delivered as [`TrayCommand`]s back to the main loop
//! rather than acted on inline, so all state changes still happen on one
//! thread.

use crossbeam_channel::Sender;

use crate::core::state_machine::State;
use crate::ui::tokens;

/// What the user asked for from the tray.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayCommand {
    /// Left click on the icon; the app decides between toggling dictation and
    /// opening Settings, depending on whether dictation is currently usable.
    Activate,
    /// Start or stop a dictation, depending on the current state.
    ToggleDictation,
    OpenSettings,
    OpenHistory,
    /// Re-run the readiness checks and restart the hotkey listener.
    Repair,
    Quit,
}

/// The tray's presentation state, kept apart from the OS handle so the label
/// and enablement rules are testable without a real notification area.
#[derive(Debug, Clone)]
pub struct TrayModel {
    pub state: State,
    pub provider_name: String,
    /// Set when the app cannot dictate at all, e.g. no way to transcribe.
    pub blocker: Option<String>,
}

impl TrayModel {
    pub fn new(provider_name: String) -> Self {
        Self {
            state: State::Idle,
            provider_name,
            blocker: None,
        }
    }

    /// Label for the start/stop item, so one entry serves both.
    pub fn toggle_label(&self) -> String {
        match self.state {
            State::Recording => "Stop dictation".to_string(),
            State::Transcribing => "Transcribing…".to_string(),
            _ => "Start dictation".to_string(),
        }
    }

    pub fn toggle_enabled(&self) -> bool {
        // Blocked means dictation is unusable; offering "Start dictation"
        // would just produce an error.
        self.blocker.is_none() && self.state != State::Transcribing
    }

    /// The first, disabled line of the menu when something is wrong.
    pub fn headline(&self) -> Option<String> {
        if let Some(blocker) = &self.blocker {
            return Some(truncate(blocker, 60));
        }
        if let State::Error(message) = &self.state {
            return Some(truncate(message, 60));
        }
        None
    }

    pub fn tooltip(&self) -> String {
        match &self.blocker {
            Some(blocker) => format!("Whisper Smart\n{blocker}"),
            None => format!(
                "Whisper Smart\n{}\n{}",
                tokens::state_label(&self.state),
                self.provider_name
            ),
        }
    }
}

/// Keeps a long error message from stretching the menu across the screen.
fn truncate(text: &str, max_chars: usize) -> String {
    let first_line = text.lines().next().unwrap_or(text).trim();
    if first_line.chars().count() <= max_chars {
        return first_line.to_string();
    }
    let kept: String = first_line
        .chars()
        .take(max_chars.saturating_sub(1))
        .collect();
    format!("{}…", kept.trim_end())
}

// ---------------------------------------------------------------------------
// The OS tray item
// ---------------------------------------------------------------------------

#[cfg(windows)]
pub use real::Tray;

#[cfg(windows)]
mod real {
    use super::*;
    use crate::bus::Waker;
    use crate::ui::icon;
    use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
    use tray_icon::{TrayIcon, TrayIconBuilder, TrayIconEvent};

    pub struct Tray {
        icon: TrayIcon,
        model: TrayModel,
    }

    impl Tray {
        /// Builds the tray item. Must run on the UI thread, whose event loop
        /// pumps the messages the hidden tray window needs.
        pub fn new(
            provider_name: String,
            commands: Sender<TrayCommand>,
            waker: Waker,
        ) -> Result<Self, String> {
            let model = TrayModel::new(provider_name);

            // Menu activations arrive on a global handler; forward them as
            // commands and wake the UI loop so they are handled promptly.
            {
                let commands = commands.clone();
                let waker = waker.clone();
                MenuEvent::set_event_handler(Some(move |event: MenuEvent| {
                    let command = match event.id().as_ref() {
                        "toggle" => Some(TrayCommand::ToggleDictation),
                        "settings" => Some(TrayCommand::OpenSettings),
                        "history" => Some(TrayCommand::OpenHistory),
                        "repair" => Some(TrayCommand::Repair),
                        "quit" => Some(TrayCommand::Quit),
                        _ => None,
                    };
                    if let Some(command) = command {
                        let _ = commands.send(command);
                        waker.wake();
                    }
                }));
            }
            {
                TrayIconEvent::set_event_handler(Some(move |event: TrayIconEvent| {
                    // Left click toggles dictation, matching the macOS
                    // status-item click; the menu stays on right click.
                    if let TrayIconEvent::Click {
                        button: tray_icon::MouseButton::Left,
                        button_state: tray_icon::MouseButtonState::Up,
                        ..
                    } = event
                    {
                        let _ = commands.send(TrayCommand::Activate);
                        waker.wake();
                    }
                }));
            }

            let icon = TrayIconBuilder::new()
                .with_menu(Box::new(build_menu(&model)))
                .with_tooltip(model.tooltip())
                .with_icon(render_icon(&model.state))
                .build()
                .map_err(|e| format!("could not create the tray icon: {e}"))?;

            Ok(Self { icon, model })
        }

        pub fn set_state(&mut self, state: State) {
            if self.model.state == state {
                return;
            }
            self.model.state = state;
            self.refresh();
        }

        pub fn set_status(&mut self, provider_name: String, blocker: Option<String>) {
            if self.model.provider_name == provider_name && self.model.blocker == blocker {
                return;
            }
            self.model.provider_name = provider_name;
            self.model.blocker = blocker;
            self.refresh();
        }

        fn refresh(&mut self) {
            let _ = self.icon.set_icon(Some(render_icon(&self.model.state)));
            let _ = self.icon.set_tooltip(Some(self.model.tooltip()));
            self.icon.set_menu(Some(Box::new(build_menu(&self.model))));
        }
    }

    fn render_icon(state: &State) -> tray_icon::Icon {
        let pixmap = icon::render_tray(state);
        tray_icon::Icon::from_rgba(pixmap.data, pixmap.width as u32, pixmap.height as u32)
            .expect("the rendered pixmap is well-formed RGBA")
    }

    /// The menu is rebuilt on every model change rather than mutated in
    /// place: the blocker line comes and goes, and rebuilding is the only way
    /// muda expresses that.
    fn build_menu(model: &TrayModel) -> Menu {
        let menu = Menu::new();

        if let Some(headline) = model.headline() {
            let item = MenuItem::with_id("status", headline, false, None);
            let _ = menu.append(&item);
            let _ = menu.append(&PredefinedMenuItem::separator());
        }

        let toggle =
            MenuItem::with_id("toggle", model.toggle_label(), model.toggle_enabled(), None);
        let _ = menu.append(&toggle);
        let _ = menu.append(&PredefinedMenuItem::separator());
        let _ = menu.append(&MenuItem::with_id("settings", "Settings…", true, None));
        let _ = menu.append(&MenuItem::with_id("history", "History…", true, None));
        let _ = menu.append(&MenuItem::with_id("repair", "Recheck setup", true, None));
        let _ = menu.append(&PredefinedMenuItem::separator());
        let _ = menu.append(&MenuItem::with_id("quit", "Quit", true, None));

        menu
    }
}

/// Non-Windows fallback so the crate builds (not runs) on development hosts.
#[cfg(not(windows))]
pub struct Tray;

#[cfg(not(windows))]
impl Tray {
    pub fn new(
        _provider_name: String,
        _commands: Sender<TrayCommand>,
        _waker: crate::bus::Waker,
    ) -> Result<Self, String> {
        Err("the notification-area icon only exists on Windows".to_string())
    }

    pub fn set_state(&mut self, _state: State) {}

    pub fn set_status(&mut self, _provider_name: String, _blocker: Option<String>) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_toggle_label_follows_the_state() {
        let mut model = TrayModel::new("Test provider".into());
        assert_eq!(model.toggle_label(), "Start dictation");

        model.state = State::Recording;
        assert_eq!(model.toggle_label(), "Stop dictation");

        model.state = State::Transcribing;
        assert_eq!(model.toggle_label(), "Transcribing…");
        assert!(
            !model.toggle_enabled(),
            "no new dictation while one is finishing"
        );
    }

    #[test]
    fn a_blocked_setup_disables_dictation_and_leads_the_menu() {
        let mut model = TrayModel::new("Test provider".into());
        model.blocker = Some("No way to transcribe".into());

        assert!(!model.toggle_enabled());
        assert_eq!(model.headline().unwrap(), "No way to transcribe");
        assert!(model.tooltip().contains("No way to transcribe"));
    }

    #[test]
    fn an_error_state_surfaces_when_there_is_no_blocker() {
        let mut model = TrayModel::new("Test provider".into());
        model.state = State::Error("microphone unavailable".into());
        assert_eq!(model.headline().unwrap(), "microphone unavailable");
    }

    #[test]
    fn a_healthy_idle_tray_has_no_headline() {
        let model = TrayModel::new("Test provider".into());
        assert_eq!(model.headline(), None);
        assert!(model.toggle_enabled());
    }

    #[test]
    fn long_messages_are_truncated_to_one_line() {
        let long = "a".repeat(200);
        let truncated = truncate(&long, 60);
        assert_eq!(truncated.chars().count(), 60);
        assert!(truncated.ends_with('…'));
    }

    #[test]
    fn multiline_messages_show_only_their_first_line() {
        assert_eq!(truncate("first line\nsecond line", 60), "first line");
    }

    #[test]
    fn short_messages_are_left_alone() {
        assert_eq!(truncate("all good", 60), "all good");
    }

    #[test]
    fn the_tooltip_names_the_active_provider() {
        let model = TrayModel::new("Test provider".into());
        assert!(model.tooltip().contains("Test provider"));
    }
}
