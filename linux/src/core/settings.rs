//! User settings, persisted as TOML.
//!
//! macOS keeps these in `UserDefaults`, which is opaque and only reachable via
//! `defaults(1)`. On Linux the equivalent is a plain file the user can read,
//! edit, diff, and put in a dotfiles repo, so settings live in
//! `~/.config/whisper-smart/config.toml`.
//!
//! Every field carries `#[serde(default)]` so a hand-edited config missing
//! whole sections still loads, and adding a field in a later release never
//! invalidates an existing file.

use std::path::Path;
use std::sync::{Arc, RwLock};

use serde::{Deserialize, Serialize};

use crate::core::hotkey_binding::HotkeyBinding;
use crate::core::model_catalog::{self, LocalModel, ModelEngine};
use crate::core::paths;
use crate::core::provider::ProviderKind;

/// Where transcribed text is placed, mirroring the macOS insertion modes.
///
/// The macOS "Accessibility" strategy sets `AXValue` on the focused control.
/// Wayland has no equivalent — there is no protocol that lets an unprivileged
/// client read or write another client's text field. The closest analogue is
/// synthesising the keystrokes for the text itself, which is what `wtype` does
/// via the virtual-keyboard protocol, so that takes the first slot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InjectionMode {
    /// Type the text directly; fall back to clipboard paste if typing fails.
    #[default]
    Smart,
    /// Only ever synthesise the text as keystrokes.
    TypeOnly,
    /// Only ever copy to the clipboard and synthesise the paste shortcut.
    PasteOnly,
}

impl InjectionMode {
    pub fn display_name(self) -> &'static str {
        match self {
            InjectionMode::Smart => "Smart (type, then paste)",
            InjectionMode::TypeOnly => "Type only",
            InjectionMode::PasteOnly => "Paste only",
        }
    }
}

/// Which compute device local inference should ask for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ComputeDevice {
    /// Try the GPU, fall back to CPU if the runtime rejects it.
    #[default]
    Auto,
    Cuda,
    Cpu,
}

impl ComputeDevice {
    pub fn display_name(self) -> &'static str {
        match self {
            ComputeDevice::Auto => "Auto (GPU if available)",
            ComputeDevice::Cuda => "CUDA (NVIDIA GPU)",
            ComputeDevice::Cpu => "CPU only",
        }
    }
}

/// Tone applied by the transcript post-processing pipeline.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WritingStyle {
    #[default]
    Neutral,
    Formal,
    Casual,
    Concise,
    Developer,
}

impl WritingStyle {
    pub fn display_name(self) -> &'static str {
        match self {
            WritingStyle::Neutral => "Neutral",
            WritingStyle::Formal => "Formal",
            WritingStyle::Casual => "Casual",
            WritingStyle::Concise => "Concise",
            WritingStyle::Developer => "Developer",
        }
    }
}

/// Visual treatment of the recording overlay.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OverlayStyle {
    /// Floating pill near the bottom of the screen.
    #[default]
    Bubble,
    /// Thin waveform bar pinned to the top edge.
    TopBar,
    /// No overlay; the tray icon is the only indicator.
    None,
}

impl OverlayStyle {
    pub fn display_name(self) -> &'static str {
        match self {
            OverlayStyle::Bubble => "Floating bubble",
            OverlayStyle::TopBar => "Top waveform bar",
            OverlayStyle::None => "None (tray only)",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct GeneralSettings {
    /// Seconds of silence before a hands-free / one-shot session auto-stops.
    pub silence_timeout_seconds: f64,
    /// cpal input device name. Empty means "system default".
    pub input_device: String,
    /// Play a short cue when recording starts and stops.
    pub play_sounds: bool,
    /// Show a desktop notification when a dictation fails.
    pub notify_on_error: bool,
}

impl Default for GeneralSettings {
    fn default() -> Self {
        Self {
            silence_timeout_seconds: 2.0,
            input_device: String::new(),
            play_sounds: false,
            notify_on_error: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct OpenAiSettings {
    /// Base URL, so OpenAI-compatible servers (LocalAI, Groq, …) also work.
    pub base_url: String,
    pub model: String,
}

impl Default for OpenAiSettings {
    fn default() -> Self {
        Self {
            base_url: "https://api.openai.com/v1".to_string(),
            model: "whisper-1".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ProviderSettings {
    pub kind: ProviderKind,
    /// Selected model per engine, so switching providers remembers each choice.
    pub whisper_cpp_model: String,
    pub faster_whisper_model: String,
    pub parakeet_model: String,
    pub compute_device: ComputeDevice,
    /// Fall back to the OpenAI API when the local provider fails to start.
    pub cloud_fallback_enabled: bool,
    /// Language hint passed to the engine. Empty means auto-detect.
    pub language: String,
    pub openai: OpenAiSettings,
}

impl Default for ProviderSettings {
    fn default() -> Self {
        Self {
            kind: ProviderKind::default(),
            whisper_cpp_model: model_catalog::CPP_LARGE_V3_TURBO.id.to_string(),
            faster_whisper_model: model_catalog::FW_LARGE_V3_TURBO.id.to_string(),
            parakeet_model: model_catalog::PARAKEET_V3.id.to_string(),
            compute_device: ComputeDevice::default(),
            cloud_fallback_enabled: false,
            language: String::new(),
            openai: OpenAiSettings::default(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct InjectionSettings {
    pub mode: InjectionMode,
    /// Restore the previous clipboard contents after a paste-based injection.
    pub restore_clipboard: bool,
    /// Extra delay (ms) before synthesising the paste shortcut. Terminals get
    /// a longer delay automatically; this is the floor for everything else.
    pub paste_delay_ms: u64,
    /// Delay (ms) before restoring the clipboard.
    pub restore_delay_ms: u64,
}

impl Default for InjectionSettings {
    fn default() -> Self {
        Self {
            mode: InjectionMode::default(),
            restore_clipboard: true,
            paste_delay_ms: 30,
            restore_delay_ms: 200,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct TextSettings {
    pub writing_style: WritingStyle,
    /// Strip leading "um", "uh", … from the final transcript.
    pub trim_filler_words: bool,
    /// Collapse double spaces and fix spacing around punctuation.
    pub normalize_spacing: bool,
    /// Spoken-punctuation commands ("new line", "comma") become characters.
    pub voice_command_formatting: bool,
    /// Literal find/replace pairs applied to the final transcript.
    pub corrections: Vec<Correction>,
}

impl Default for TextSettings {
    fn default() -> Self {
        Self {
            writing_style: WritingStyle::default(),
            trim_filler_words: true,
            normalize_spacing: true,
            voice_command_formatting: false,
            corrections: Vec::new(),
        }
    }
}

/// One user-defined literal replacement, e.g. "cloud code" → "Claude Code".
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Correction {
    pub from: String,
    pub to: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct OverlaySettings {
    pub style: OverlayStyle,
    /// Show the live transcript inside the overlay while transcribing.
    pub show_transcript: bool,
}

impl Default for OverlaySettings {
    fn default() -> Self {
        Self {
            style: OverlayStyle::default(),
            show_transcript: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct HistorySettings {
    pub enabled: bool,
    pub max_entries: usize,
}

impl Default for HistorySettings {
    fn default() -> Self {
        Self {
            enabled: true,
            max_entries: 200,
        }
    }
}

/// The whole persisted configuration.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub general: GeneralSettings,
    pub hotkey: HotkeyBinding,
    pub provider: ProviderSettings,
    pub injection: InjectionSettings,
    pub text: TextSettings,
    pub overlay: OverlaySettings,
    pub history: HistorySettings,
}

impl Settings {
    /// The model currently selected for `provider.kind`, if it is local.
    ///
    /// Falls back to the engine default when the stored ID is unknown (a model
    /// removed in a later release) or belongs to a different engine (a config
    /// hand-edited into an inconsistent state).
    pub fn selected_model(&self) -> Option<LocalModel> {
        let engine = self.provider.kind.engine()?;
        let id = self.selected_model_id(engine);
        let chosen = model_catalog::model(id).filter(|m| m.engine == engine);
        Some(chosen.unwrap_or_else(|| model_catalog::default_model(engine)))
    }

    pub fn selected_model_id(&self, engine: ModelEngine) -> &str {
        match engine {
            ModelEngine::WhisperCpp => &self.provider.whisper_cpp_model,
            ModelEngine::FasterWhisper => &self.provider.faster_whisper_model,
            ModelEngine::ParakeetOnnx => &self.provider.parakeet_model,
        }
    }

    pub fn set_selected_model_id(&mut self, engine: ModelEngine, id: String) {
        match engine {
            ModelEngine::WhisperCpp => self.provider.whisper_cpp_model = id,
            ModelEngine::FasterWhisper => self.provider.faster_whisper_model = id,
            ModelEngine::ParakeetOnnx => self.provider.parakeet_model = id,
        }
    }

    /// Silence timeout clamped to a sane range. A zero or negative value in a
    /// hand-edited config would otherwise end every session instantly.
    pub fn silence_timeout(&self) -> std::time::Duration {
        let secs = self.general.silence_timeout_seconds.clamp(0.5, 30.0);
        std::time::Duration::from_secs_f64(secs)
    }
}

/// Thread-safe settings handle shared between the GTK main loop, the hotkey
/// thread, and the STT workers.
#[derive(Clone)]
pub struct SettingsStore {
    inner: Arc<RwLock<Settings>>,
    path: Arc<std::path::PathBuf>,
}

impl SettingsStore {
    /// Loads settings from `path`, falling back to defaults when the file is
    /// absent. A file that exists but fails to parse is preserved as
    /// `config.toml.bak` rather than silently overwritten, because losing a
    /// hand-written config to a typo is far worse than starting from defaults.
    pub fn load_from(path: &Path) -> Self {
        let settings = match std::fs::read_to_string(path) {
            Ok(text) => match toml::from_str::<Settings>(&text) {
                Ok(parsed) => parsed,
                Err(err) => {
                    tracing::error!(
                        "config.toml is invalid ({err}); backing it up and using defaults"
                    );
                    let backup = path.with_extension("toml.bak");
                    let _ = std::fs::copy(path, &backup);
                    Settings::default()
                }
            },
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Settings::default(),
            Err(err) => {
                tracing::error!("could not read config.toml ({err}); using defaults");
                Settings::default()
            }
        };

        let mut settings = settings;
        migrate_macos_model_ids(&mut settings);

        Self {
            inner: Arc::new(RwLock::new(settings)),
            path: Arc::new(path.to_path_buf()),
        }
    }

    pub fn load() -> Self {
        Self::load_from(&paths::config_file())
    }

    /// In-memory store with no backing file. Used by tests.
    #[cfg(test)]
    pub fn in_memory(settings: Settings) -> Self {
        Self {
            inner: Arc::new(RwLock::new(settings)),
            path: Arc::new(std::path::PathBuf::new()),
        }
    }

    pub fn get(&self) -> Settings {
        self.inner.read().expect("settings lock poisoned").clone()
    }

    /// Mutates the settings and writes them back to disk.
    pub fn update<F: FnOnce(&mut Settings)>(&self, f: F) {
        {
            let mut guard = self.inner.write().expect("settings lock poisoned");
            f(&mut guard);
        }
        if let Err(err) = self.save() {
            tracing::error!("failed to persist settings: {err}");
        }
    }

    pub fn save(&self) -> anyhow::Result<()> {
        if self.path.as_os_str().is_empty() {
            return Ok(());
        }
        let settings = self.get();
        let text = toml::to_string_pretty(&settings)?;
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        // Write-then-rename so an interrupted save cannot truncate a good config.
        let tmp = self.path.with_extension("toml.tmp");
        std::fs::write(&tmp, text)?;
        std::fs::rename(&tmp, self.path.as_path())?;
        Ok(())
    }
}

/// Rewrites model IDs copied from a macOS `config` into their Linux
/// equivalents.
///
/// The Mac build's IDs name MLX models (`whisper-large-v3-turbo`), which do not
/// exist here — MLX is Apple Silicon only. Someone moving their config across
/// should keep the model they chose rather than being silently reset to the
/// default, so each ID is mapped to the closest engine that can actually load
/// those weights on Linux.
fn migrate_macos_model_ids(settings: &mut Settings) {
    for engine in [
        ModelEngine::WhisperCpp,
        ModelEngine::FasterWhisper,
        ModelEngine::ParakeetOnnx,
    ] {
        let id = settings.selected_model_id(engine).to_string();
        // Only rewrite IDs this catalog does not recognise; a valid Linux ID
        // must never be touched.
        if model_catalog::model(&id).is_some() {
            continue;
        }
        if let Some(migrated) = model_catalog::from_macos_model_id(&id) {
            if migrated.engine == engine {
                tracing::info!("migrated macOS model selection {id} to {}", migrated.id);
                settings.set_selected_model_id(engine, migrated.id.to_string());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_round_trip_through_toml() {
        let settings = Settings::default();
        let text = toml::to_string_pretty(&settings).unwrap();
        let decoded: Settings = toml::from_str(&text).unwrap();
        assert_eq!(settings, decoded);
    }

    #[test]
    fn a_config_missing_every_section_still_loads() {
        let decoded: Settings = toml::from_str("").unwrap();
        assert_eq!(decoded, Settings::default());
    }

    #[test]
    fn a_partial_config_keeps_defaults_for_absent_fields() {
        let decoded: Settings = toml::from_str(
            r#"
            [provider]
            kind = "parakeet"
            "#,
        )
        .unwrap();
        assert_eq!(decoded.provider.kind, ProviderKind::Parakeet);
        // Untouched fields fall back rather than becoming empty strings.
        assert_eq!(decoded.provider.openai.model, "whisper-1");
        assert_eq!(decoded.general.silence_timeout_seconds, 2.0);
    }

    #[test]
    fn selected_model_falls_back_when_the_id_belongs_to_another_engine() {
        let mut settings = Settings::default();
        settings.provider.kind = ProviderKind::Parakeet;
        // A whisper.cpp id in the parakeet slot: inconsistent, must not stick.
        settings.provider.parakeet_model = model_catalog::CPP_BASE.id.to_string();
        let model = settings.selected_model().unwrap();
        assert_eq!(model.engine, ModelEngine::ParakeetOnnx);
        assert_eq!(model.id, model_catalog::PARAKEET_V3.id);
    }

    #[test]
    fn selected_model_falls_back_when_the_id_is_unknown() {
        let mut settings = Settings::default();
        settings.provider.kind = ProviderKind::FasterWhisper;
        settings.provider.faster_whisper_model = "removed-in-a-later-release".to_string();
        assert_eq!(
            settings.selected_model().unwrap().id,
            model_catalog::FW_LARGE_V3_TURBO.id
        );
    }

    #[test]
    fn cloud_provider_has_no_selected_model() {
        let mut settings = Settings::default();
        settings.provider.kind = ProviderKind::OpenAiApi;
        assert!(settings.selected_model().is_none());
    }

    #[test]
    fn silence_timeout_is_clamped_against_a_hand_edited_zero() {
        let mut settings = Settings::default();
        settings.general.silence_timeout_seconds = 0.0;
        assert_eq!(
            settings.silence_timeout(),
            std::time::Duration::from_secs_f64(0.5)
        );
        settings.general.silence_timeout_seconds = 9_999.0;
        assert_eq!(
            settings.silence_timeout(),
            std::time::Duration::from_secs_f64(30.0)
        );
    }

    #[test]
    fn store_persists_updates_and_reloads_them() {
        let dir = std::env::temp_dir().join(format!("ws-settings-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.toml");
        let _ = std::fs::remove_file(&path);

        let store = SettingsStore::load_from(&path);
        store.update(|s| s.provider.kind = ProviderKind::Parakeet);

        let reloaded = SettingsStore::load_from(&path);
        assert_eq!(reloaded.get().provider.kind, ProviderKind::Parakeet);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn an_unparseable_config_is_backed_up_rather_than_destroyed() {
        let dir = std::env::temp_dir().join(format!("ws-settings-bad-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.toml");
        std::fs::write(&path, "this is not = = valid toml").unwrap();

        let store = SettingsStore::load_from(&path);
        assert_eq!(store.get(), Settings::default());
        assert!(
            dir.join("config.toml.bak").exists(),
            "original config was not preserved"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_macos_model_id_migrates_to_its_linux_equivalent() {
        let decoded: Settings = toml::from_str(
            r#"
            [provider]
            kind = "parakeet"
            parakeet_model = "parakeet-tdt-0.6b-v2"
            faster_whisper_model = "whisper-small"
            "#,
        )
        .unwrap();
        let mut settings = decoded;
        migrate_macos_model_ids(&mut settings);

        // Parakeet keeps the same ID because the model is the same family.
        assert_eq!(
            settings.provider.parakeet_model,
            model_catalog::PARAKEET_V2.id
        );
        // The MLX Whisper ID becomes the faster-whisper build of those weights.
        assert_eq!(
            settings.provider.faster_whisper_model,
            model_catalog::FW_SMALL.id
        );
    }

    #[test]
    fn migration_leaves_a_valid_linux_id_alone() {
        let mut settings = Settings::default();
        settings.provider.faster_whisper_model = model_catalog::FW_TINY.id.to_string();
        migrate_macos_model_ids(&mut settings);
        assert_eq!(
            settings.provider.faster_whisper_model,
            model_catalog::FW_TINY.id
        );
    }

    #[test]
    fn migration_leaves_an_unrecognisable_id_for_selected_model_to_handle() {
        let mut settings = Settings::default();
        settings.provider.parakeet_model = "something-invented".to_string();
        migrate_macos_model_ids(&mut settings);
        // Not rewritten here, but selected_model() still resolves a usable model.
        settings.provider.kind = ProviderKind::Parakeet;
        assert_eq!(
            settings.selected_model().unwrap().id,
            model_catalog::PARAKEET_V3.id
        );
    }

    #[test]
    fn an_in_memory_store_never_touches_the_disk() {
        let store = SettingsStore::in_memory(Settings::default());
        store.update(|s| s.provider.kind = ProviderKind::OpenAiApi);
        assert_eq!(store.get().provider.kind, ProviderKind::OpenAiApi);
        assert!(store.save().is_ok());
    }
}
