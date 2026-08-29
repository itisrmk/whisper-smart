//! Whisper Smart for Linux.
//!
//! Exposed as a library as well as a binary so the integration tests can drive
//! real components — most importantly the STT sidecar protocol client — rather
//! than only testing through the UI.
//!
//! ## Layering
//!
//! * [`core`] — the dictation state machine, settings, model catalog, and text
//!   pipeline. No GTK, no evdev, no network, so all of it is unit-testable.
//! * [`platform`] — audio capture, global input, text insertion, diagnostics.
//! * [`stt`] — the provider abstraction and the three speech engines.
//! * [`ui`] — GTK4 windows, the layer-shell overlay, and the tray icon.
//! * [`app`] — lifecycle and wiring; the `AppDelegate` equivalent.

pub mod app;
pub mod core;
pub mod platform;
pub mod stt;
pub mod ui;
