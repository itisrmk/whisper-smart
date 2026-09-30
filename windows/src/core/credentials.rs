//! API credential storage.
//!
//! macOS stores the OpenAI key in the Keychain and Linux in a `0600` file. The
//! Windows equivalent of that file is one under the user's own profile
//! (`%APPDATA%`), which NTFS ACLs already restrict to the user and
//! administrators — the same protection every browser profile and SSH key on
//! Windows relies on. The Credential Manager was considered and skipped for
//! the same reason Secret Service was on Linux: a plain file the user can see
//! and delete beats an opaque store for a key they pasted in themselves.
//!
//! The key never goes into `config.toml`, so a user can share or commit that
//! file without leaking a credential.

use std::io::Write;

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

/// Writes the key, creating the file if needed.
pub fn write_openai_key(key: &str) -> anyhow::Result<()> {
    let path = paths::credentials_file();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let contents = toml::to_string_pretty(&CredentialFile {
        openai_api_key: key.trim().to_string(),
    })?;

    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&path)?;
    file.write_all(contents.as_bytes())?;
    file.sync_all()?;
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
