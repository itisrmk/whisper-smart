//! Desktop notifications.
//!
//! The macOS build surfaces failures in the menu-bar UI and an alert. On Linux
//! the idiomatic equivalent is the freedesktop notification spec, which every
//! bar and notification daemon on a modern desktop already handles.

use notify_rust::Notification;

/// Application name shown by the notification daemon.
const APP_NAME: &str = "Whisper Smart";

/// Icon name; falls back gracefully when the theme has no such icon.
const ICON: &str = "audio-input-microphone";

pub fn error(summary: &str, body: &str) {
    show(summary, body, notify_rust::Urgency::Critical);
}

fn show(summary: &str, body: &str, urgency: notify_rust::Urgency) {
    let result = Notification::new()
        .appname(APP_NAME)
        .summary(summary)
        .body(body)
        .icon(ICON)
        .urgency(urgency)
        .show();

    if let Err(err) = result {
        // A headless session or a missing notification daemon is normal, not a
        // failure worth interrupting dictation over.
        tracing::debug!("notification not shown: {err}");
    }
}
