//! XDG storage path resolution.
//!
//! The macOS build stores everything under `~/Library/Application Support/WhisperSmart`.
//! On Linux we split that across the XDG base directories so the app behaves
//! like a well-mannered desktop citizen: config is user-editable and
//! backup-worthy, data holds large model weights, cache holds throwaway audio.

use std::path::{Path, PathBuf};

/// Directory name used under each XDG root.
pub const APP_DIR_NAME: &str = "whisper-smart";

/// `$XDG_CONFIG_HOME/whisper-smart` — `config.toml` lives here.
pub fn config_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| home().join(".config"))
        .join(APP_DIR_NAME)
}

/// `$XDG_DATA_HOME/whisper-smart` — models, Python runtime, transcript log.
pub fn data_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| home().join(".local/share"))
        .join(APP_DIR_NAME)
}

/// `$XDG_CACHE_HOME/whisper-smart` — scratch WAV files, download temporaries.
pub fn cache_dir() -> PathBuf {
    dirs::cache_dir()
        .unwrap_or_else(|| home().join(".cache"))
        .join(APP_DIR_NAME)
}

/// `$XDG_STATE_HOME/whisper-smart` — log files.
pub fn state_dir() -> PathBuf {
    dirs::state_dir()
        .unwrap_or_else(|| home().join(".local/state"))
        .join(APP_DIR_NAME)
}

pub fn config_file() -> PathBuf {
    config_dir().join("config.toml")
}

/// Where the OpenAI API key is written when no Secret Service is available.
/// Created with mode 0600; see [`crate::core::credentials`].
pub fn credentials_file() -> PathBuf {
    config_dir().join("credentials.toml")
}

pub fn transcript_log_file() -> PathBuf {
    data_dir().join("transcripts.jsonl")
}

/// Root for the managed Python virtualenv that runs the STT sidecar.
/// Mirrors `MLXRuntimeBootstrapManager`'s app-managed venv on macOS.
pub fn python_runtime_dir() -> PathBuf {
    data_dir().join("runtime/python")
}

/// Root for downloaded model weights (whisper.cpp GGUF, CTranslate2, ONNX).
pub fn models_dir() -> PathBuf {
    data_dir().join("models")
}

/// Hugging Face cache used by the Python sidecar. Kept inside our data dir so
/// uninstalling the app reclaims the (multi-GB) weights.
pub fn hf_cache_dir() -> PathBuf {
    data_dir().join("models/hf")
}

pub fn log_file() -> PathBuf {
    state_dir().join("whisper-smart.log")
}

/// Creates `dir` and all parents, ignoring an already-existing directory.
pub fn ensure_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"))
}
