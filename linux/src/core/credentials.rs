//! API credential storage.
//!
//! macOS stores the OpenAI key in the Keychain. The Linux equivalent is the
//! Secret Service (gnome-keyring / KWallet) over D-Bus, but that is only
//! present on some desktops and unlocking it is an interactive affair. Rather
//! than making the app unusable on a minimal Wayland session, this falls back
//! to a `0600` file in the config directory and says so plainly in the UI.
//!
//! The key never goes into `config.toml`, so a user can share or commit that
//! file without leaking a credential.

use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

use serde::{Deserialize, Serialize};

use crate::core::paths;

#[derive(Debug, Default, Serialize, Deserialize)]
struct CredentialFile {
    #[serde(default)]
    openai_api_key: String,
}

pub fn read_openai_key() -> Option<String> {
    let path = paths::credentials_file();
    let text = std::fs::read_to_string(path).ok()?;
    let parsed: CredentialFile = toml::from_str(&text).ok()?;
    let key = parsed.openai_api_key.trim().to_string();
    if key.is_empty() {
        None
    } else {
        Some(key)
    }
}

/// Writes the key with `0600` permissions, creating the file if needed.
pub fn write_openai_key(key: &str) -> anyhow::Result<()> {
    let path = paths::credentials_file();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let contents = toml::to_string_pretty(&CredentialFile {
        openai_api_key: key.trim().to_string(),
    })?;

    // Create with restrictive permissions from the start: creating it 0644 and
    // chmod-ing afterwards leaves a window where the key is world-readable.
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)?;
    file.write_all(contents.as_bytes())?;
    file.sync_all()?;

    // An existing file keeps its old mode, so enforce it explicitly too.
    let mut perms = std::fs::metadata(&path)?.permissions();
    perms.set_mode(0o600);
    std::fs::set_permissions(&path, perms)?;
    Ok(())
}

pub fn delete_openai_key() -> anyhow::Result<()> {
    let path = paths::credentials_file();
    match std::fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(err.into()),
    }
}

/// True when a key is present. Used by the UI without exposing the value.
pub fn has_openai_key() -> bool {
    read_openai_key().is_some()
}
