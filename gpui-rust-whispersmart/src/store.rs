use std::{fs, path::PathBuf};

use anyhow::{Context, Result};

use crate::settings::AppSettings;

pub struct SettingsStore {
    path: PathBuf,
}

impl SettingsStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn load(&self) -> Result<AppSettings> {
        if !self.path.exists() {
            return Ok(AppSettings::default());
        }

        let raw = fs::read_to_string(&self.path)
            .with_context(|| format!("failed reading settings file {}", self.path.display()))?;
        let settings: AppSettings =
            serde_json::from_str(&raw).context("failed parsing settings json")?;
        Ok(settings)
    }

    pub fn save(&self, settings: &AppSettings) -> Result<()> {
        let Some(parent) = self.path.parent() else {
            anyhow::bail!("settings path has no parent")
        };
        fs::create_dir_all(parent)?;
        let content = serde_json::to_string_pretty(settings)?;
        fs::write(&self.path, content)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_when_missing() {
        let tmp = std::env::temp_dir().join("whisper-smart-settings-missing.json");
        let _ = std::fs::remove_file(&tmp);
        let store = SettingsStore::new(tmp);
        let settings = store.load().expect("load defaults");
        assert_eq!(settings.provider, "placeholder");
    }
}
