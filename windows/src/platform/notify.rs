//! Desktop notifications.
//!
//! The macOS build surfaces failures in the menu-bar UI and an alert; Linux
//! uses the freedesktop spec. On Windows `notify-rust` delivers the same call
//! as a toast notification through the Action Center.

use notify_rust::Notification;

/// Application name shown by the notification host.
const APP_NAME: &str = "Whisper Smart";

pub fn error(summary: &str, body: &str) {
    let result = Notification::new()
        .appname(APP_NAME)
        .summary(summary)
        .body(body)
        .show();

    if let Err(err) = result {
        // Focus assist or a stripped-down session can refuse toasts; that is
        // not a failure worth interrupting dictation over.
        tracing::debug!("notification not shown: {err}");
    }
}
