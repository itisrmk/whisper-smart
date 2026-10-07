//! Whisper Smart for Windows.
//!
//! Exposed as a library as well as a binary so the integration tests can drive
//! real components — most importantly the STT sidecar protocol client — rather
//! than only testing through the UI.
//!
//! ## Layering
//!
//! * [`core`] — the dictation state machine, settings, model catalog, and text
//!   pipeline. No Win32, no egui, no network, so all of it is unit-testable.
//! * [`platform`] — audio capture, the global keyboard hook, text insertion,
//!   diagnostics.
//! * [`stt`] — the provider abstraction and the speech engines.
//! * [`ui`] — the egui settings window, the recording overlay, and the tray.
//! * [`app`] — lifecycle and wiring; the `AppDelegate` equivalent.

pub mod app;
pub mod bus;
pub mod core;
pub mod platform;
pub mod stt;
pub mod ui;

/// Short build identifier: the commit this binary was built from (CI exports
/// `GITHUB_SHA` at compile time), or "dev" for local builds. Shown in the
/// settings footer and `--version` so "which build is this?" never has to be
/// guessed again.
pub fn build_tag() -> &'static str {
    match option_env!("GITHUB_SHA") {
        Some(sha) if sha.len() >= 7 => &sha[..7],
        Some(sha) => sha,
        None => "dev",
    }
}
