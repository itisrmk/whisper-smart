//! Platform-independent core: state machine, settings, catalog, text pipeline.
//!
//! Nothing in this module talks to GTK, evdev, PipeWire, or the network, which
//! is what makes the whole dictation lifecycle testable without a desktop
//! session — the same property the macOS smoke tests rely on.

pub mod credentials;
pub mod hotkey_binding;
pub mod model_catalog;
pub mod paths;
pub mod post_processing;
pub mod provider;
pub mod settings;
pub mod state_machine;
pub mod transcript_log;
