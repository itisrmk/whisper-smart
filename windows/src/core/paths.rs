//! Storage path resolution.
//!
//! The macOS build stores everything under `~/Library/Application Support/WhisperSmart`
//! and the Linux build spreads it across the XDG base directories. Windows has
//! its own convention: small, user-editable state goes to the roaming profile
//! (`%APPDATA%`), while anything large or machine-specific — model weights, the
//! Python runtime, caches, logs — goes to the local profile (`%LOCALAPPDATA%`)
//! so multi-gigabyte weights are never dragged around by roaming profiles.

use std::path::{Path, PathBuf};

/// Directory name used under each profile root.
pub const APP_DIR_NAME: &str = "whisper-smart";

/// `%APPDATA%\whisper-smart` — `config.toml` lives here.
pub fn config_dir() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| home().join("AppData/Roaming"))
        .join(APP_DIR_NAME)
}

/// `%LOCALAPPDATA%\whisper-smart` — models, Python runtime, transcript log.
pub fn data_dir() -> PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| home().join("AppData/Local"))
        .join(APP_DIR_NAME)
}

/// `%LOCALAPPDATA%\whisper-smart\cache` — scratch WAV files, download temporaries.
pub fn cache_dir() -> PathBuf {
    data_dir().join("cache")
}

/// `%LOCALAPPDATA%\whisper-smart\logs` — log files.
pub fn state_dir() -> PathBuf {
    data_dir().join("logs")
}

pub fn config_file() -> PathBuf {
    config_dir().join("config.toml")
}

/// Where the OpenAI API key is written. Protected by the user profile's ACLs,
/// the Windows analogue of the Linux build's `0600` file; see
/// [`crate::core::credentials`].
pub fn credentials_file() -> PathBuf {
    config_dir().join("credentials.toml")
}

pub fn transcript_log_file() -> PathBuf {
    data_dir().join("transcripts.jsonl")
}

/// Root for the managed Python virtualenv that runs the STT sidecar.
/// Mirrors `MLXRuntimeBootstrapManager`'s app-managed venv on macOS.
pub fn python_runtime_dir() -> PathBuf {
    data_dir().join("runtime").join("python")
}

/// Where the managed whisper.cpp binaries are unpacked. Windows has no distro
/// package manager to lean on, so the app installs the official prebuilt
/// `whisper-cli.exe` here on request instead.
pub fn whisper_cpp_dir() -> PathBuf {
    data_dir().join("runtime").join("whisper-cpp")
}

/// Root for downloaded model weights (whisper.cpp GGUF, CTranslate2, ONNX).
pub fn models_dir() -> PathBuf {
    data_dir().join("models")
}

/// Hugging Face cache used by the Python sidecar. Kept inside our data dir so
/// uninstalling the app reclaims the (multi-GB) weights.
pub fn hf_cache_dir() -> PathBuf {
    data_dir().join("models").join("hf")
}

pub fn log_file() -> PathBuf {
    state_dir().join("whisper-smart.log")
}

/// Creates `dir` and all parents, ignoring an already-existing directory.
pub fn ensure_dir(dir: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(std::env::temp_dir)
}
