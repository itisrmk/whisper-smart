//! Menu-bar (system tray) presence.
//!
//! Port of `MenuBarController.swift`. macOS uses `NSStatusItem`; the Linux
//! equivalent is the StatusNotifierItem D-Bus interface, which is what Waybar,
//! Ayatana, KDE's system tray, and GNOME's AppIndicator extension all consume.
//! `ksni` implements that protocol directly, so no GTK status-icon shim or
//! `libappindicator` C dependency is needed.
//!
//! The tray runs on its own thread. Menu activations are sent as
//! [`TrayCommand`]s back to the main loop rather than acted on inline, so all
//! state changes still happen on one thread.

use crossbeam_channel::Sender;
use ksni::menu::{MenuItem, StandardItem};
use ksni::{Icon, Status, ToolTip, Tray};

use crate::core::state_machine::State;
use crate::ui::{icon, tokens};

/// What the user asked for from the tray menu.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrayCommand {
    /// Start or stop a dictation, depending on the current state.
    ToggleDictation,
    OpenSettings,
    OpenHistory,
    /// Re-run the readiness checks and restart the hotkey listener.
    Repair,
    Quit,
}

pub struct WhisperTray {
    state: State,
    provider_name: String,
    /// Set when the app cannot dictate at all, e.g. no input-device access.
    blocker: Option<String>,
    commands: Sender<TrayCommand>,
}

impl WhisperTray {
    pub fn new(provider_name: String, commands: Sender<TrayCommand>) -> Self {
        Self {
            state: State::Idle,
            provider_name,
            blocker: None,
            commands,
        }
    }

    pub fn set_state(&mut self, state: State) {
        self.state = state;
    }

    pub fn set_provider_name(&mut self, name: String) {
        self.provider_name = name;
    }

    pub fn set_blocker(&mut self, blocker: Option<String>) {
        self.blocker = blocker;
    }

    fn send(&self, command: TrayCommand) {
        if self.commands.send(command).is_err() {
            tracing::warn!("tray command dropped; the app is shutting down");
        }
    }

    /// Label for the start/stop item, so one entry serves both.
    fn toggle_label(&self) -> String {
        match self.state {
            State::Recording => "Stop dictation".to_string(),
            State::Transcribing => "Transcribing…".to_string(),
            _ => "Start dictation".to_string(),
        }
    }

    fn toggle_enabled(&self) -> bool {
        // Blocked means the microphone or hotkey path is unusable; offering
        // "Start dictation" would just produce an error.
        self.blocker.is_none() && self.state != State::Transcribing
    }
}

impl Tray for WhisperTray {
    fn id(&self) -> String {
        "whisper-smart".into()
    }

    fn title(&self) -> String {
        "Whisper Smart".into()
    }

    /// Deliberately empty so hosts use [`Self::icon_pixmap`].
    ///
    /// Naming a themed icon looks tidier but is not dependable: a name the
    /// user's theme does not carry resolves to nothing and the tray item draws
    /// blank while still occupying a slot. Shipping the pixels is the only way
    /// to guarantee the icon appears on every desktop.
    fn icon_name(&self) -> String {
        String::new()
    }

    fn icon_pixmap(&self) -> Vec<Icon> {
        icon::render_all(&self.state)
            .into_iter()
            .map(|pixmap| Icon {
                width: pixmap.width,
                height: pixmap.height,
                data: pixmap.data,
            })
            .collect()
    }

    fn status(&self) -> Status {
        if self.blocker.is_some() {
            // NeedsAttention makes bars that support it highlight the item.
            Status::NeedsAttention
        } else {
            Status::Active
        }
    }

    fn tool_tip(&self) -> ToolTip {
        let description = match &self.blocker {
            Some(blocker) => blocker.clone(),
            None => format!(
                "{}\n{}",
                tokens::state_label(&self.state),
                self.provider_name
            ),
        };
        ToolTip {
            icon_name: String::new(),
            icon_pixmap: Vec::new(),
            title: "Whisper Smart".into(),
            description,
        }
    }

    /// Left click toggles dictation, matching the macOS status-item click.
    fn activate(&mut self, _x: i32, _y: i32) {
        if self.toggle_enabled() {
            self.send(TrayCommand::ToggleDictation);
        } else {
            self.send(TrayCommand::OpenSettings);
        }
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        let mut items: Vec<MenuItem<Self>> = Vec::new();

        if let Some(blocker) = &self.blocker {
            items.push(
                StandardItem {
                    label: truncate(blocker, 60),
                    enabled: false,
                    icon_name: "dialog-warning-symbolic".into(),
                    ..Default::default()
                }
                .into(),
            );
            items.push(MenuItem::Separator);
        } else if let State::Error(message) = &self.state {
            items.push(
                StandardItem {
                    label: truncate(message, 60),
                    enabled: false,
                    icon_name: "dialog-error-symbolic".into(),
                    ..Default::default()
                }
                .into(),
            );
            items.push(MenuItem::Separator);
        }

        items.push(
            StandardItem {
                label: self.toggle_label(),
                enabled: self.toggle_enabled(),
                icon_name: "audio-input-microphone-symbolic".into(),
                activate: Box::new(|tray: &mut Self| tray.send(TrayCommand::ToggleDictation)),
                ..Default::default()
            }
            .into(),
        );

        items.push(MenuItem::Separator);

        items.push(
            StandardItem {
                label: "Settings…".into(),
                icon_name: "preferences-system-symbolic".into(),
                activate: Box::new(|tray: &mut Self| tray.send(TrayCommand::OpenSettings)),
                ..Default::default()
            }
            .into(),
        );

        items.push(
            StandardItem {
                label: "History…".into(),
                icon_name: "document-open-recent-symbolic".into(),
                activate: Box::new(|tray: &mut Self| tray.send(TrayCommand::OpenHistory)),
                ..Default::default()
            }
            .into(),
        );

        items.push(
            StandardItem {
                label: "Recheck setup".into(),
                icon_name: "view-refresh-symbolic".into(),
                activate: Box::new(|tray: &mut Self| tray.send(TrayCommand::Repair)),
                ..Default::default()
            }
            .into(),
        );

        items.push(MenuItem::Separator);

        items.push(
            StandardItem {
                label: "Quit".into(),
                icon_name: "application-exit-symbolic".into(),
                activate: Box::new(|tray: &mut Self| tray.send(TrayCommand::Quit)),
                ..Default::default()
            }
            .into(),
        );

        items
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

#[cfg(test)]
mod tests {
    use super::*;

    fn tray() -> (WhisperTray, crossbeam_channel::Receiver<TrayCommand>) {
        let (tx, rx) = crossbeam_channel::unbounded();
        (WhisperTray::new("Test provider".into(), tx), rx)
    }

    #[test]
    fn the_toggle_label_follows_the_state() {
        let (mut tray, _rx) = tray();
        assert_eq!(tray.toggle_label(), "Start dictation");

        tray.set_state(State::Recording);
        assert_eq!(tray.toggle_label(), "Stop dictation");

        tray.set_state(State::Transcribing);
        assert_eq!(tray.toggle_label(), "Transcribing…");
        assert!(
            !tray.toggle_enabled(),
            "no new dictation while one is finishing"
        );
    }

    #[test]
    fn a_blocked_setup_disables_dictation_and_flags_the_tray() {
        let (mut tray, _rx) = tray();
        tray.set_blocker(Some("Cannot read the keyboard".into()));

        assert!(!tray.toggle_enabled());
        assert_eq!(tray.status(), Status::NeedsAttention);
        assert!(tray
            .tool_tip()
            .description
            .contains("Cannot read the keyboard"));
    }

    #[test]
    fn clicking_a_blocked_tray_opens_settings_rather_than_failing_silently() {
        let (mut tray, rx) = tray();
        tray.set_blocker(Some("Cannot read the keyboard".into()));
        tray.activate(0, 0);
        assert_eq!(rx.try_recv().unwrap(), TrayCommand::OpenSettings);
    }

    #[test]
    fn clicking_a_working_tray_toggles_dictation() {
        let (mut tray, rx) = tray();
        tray.activate(0, 0);
        assert_eq!(rx.try_recv().unwrap(), TrayCommand::ToggleDictation);
    }

    #[test]
    fn the_menu_leads_with_the_blocker_when_there_is_one() {
        let (mut tray, _rx) = tray();
        tray.set_blocker(Some("Cannot read the keyboard".into()));
        let menu = tray.menu();
        assert!(matches!(&menu[0], MenuItem::Standard(item) if !item.enabled));
    }

    #[test]
    fn the_menu_surfaces_an_error_state_when_there_is_no_blocker() {
        let (mut tray, _rx) = tray();
        tray.set_state(State::Error("microphone unavailable".into()));
        let menu = tray.menu();
        match &menu[0] {
            MenuItem::Standard(item) => assert!(item.label.contains("microphone unavailable")),
            _ => panic!("expected a standard menu item first"),
        }
    }

    #[test]
    fn a_healthy_idle_tray_leads_with_the_start_item() {
        let (tray, _rx) = tray();
        match &tray.menu()[0] {
            MenuItem::Standard(item) => {
                assert_eq!(item.label, "Start dictation");
                assert!(item.enabled);
            }
            _ => panic!("expected a standard menu item first"),
        }
        assert_eq!(tray.status(), Status::Active);
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
        let (tray, _rx) = tray();
        assert!(tray.tool_tip().description.contains("Test provider"));
    }

    #[test]
    fn the_tray_always_supplies_its_own_pixels() {
        // Relying on a themed icon name is what made the item invisible on a
        // Yaru-sage-dark desktop, where `audio-input-microphone-symbolic`
        // resolves to nothing anywhere in the inheritance chain.
        let (tray, _rx) = tray();
        assert!(tray.icon_name().is_empty(), "a themed name may not resolve");

        let pixmaps = tray.icon_pixmap();
        assert!(!pixmaps.is_empty(), "the tray must ship its own icon");
        for pixmap in &pixmaps {
            assert_eq!(
                pixmap.data.len(),
                (pixmap.width * pixmap.height * 4) as usize
            );
            assert!(pixmap.data.iter().any(|b| *b != 0), "the icon is blank");
        }
    }

    #[test]
    fn the_icon_changes_with_the_state() {
        let (mut tray, _rx) = tray();
        let idle = tray.icon_pixmap();
        tray.set_state(State::Recording);
        let recording = tray.icon_pixmap();
        assert_ne!(
            idle[0].data, recording[0].data,
            "recording should look different"
        );
    }
}
