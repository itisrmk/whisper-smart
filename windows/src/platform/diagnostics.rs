//! Readiness checks and provider fallback resolution.
//!
//! Combines the roles of `PermissionDiagnostics.swift` (can the app actually
//! do its job?) and `STTProviderDiagnostics.swift` (is the selected provider
//! usable, and if not, what should run instead?).
//!
//! The macOS checks are about TCC permissions. Windows has almost none of
//! that: the keyboard hook and `SendInput` need no grant, and the microphone
//! prompt is system-wide and one-time. What can actually be missing here is
//! tooling — the whisper.cpp binary, the Python runtime, model weights — so
//! the checks focus there, each with a plain-language fix.

use std::path::PathBuf;
use std::process::Command;

use crate::core::model_catalog::{LocalModel, ModelEngine, ModelSource};
use crate::core::paths;
use crate::core::provider::ProviderKind;
use crate::core::settings::Settings;
use crate::platform::hotkey::check_input_access;

/// Severity of a single readiness check.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckStatus {
    Ok,
    /// The app works but something is degraded.
    Warning,
    /// The app cannot perform this function at all.
    Blocked,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Check {
    pub title: String,
    pub status: CheckStatus,
    pub detail: String,
    /// A command or instruction that fixes it, when there is one.
    pub remedy: Option<String>,
}

impl Check {
    fn ok(title: &str, detail: impl Into<String>) -> Self {
        Self {
            title: title.to_string(),
            status: CheckStatus::Ok,
            detail: detail.into(),
            remedy: None,
        }
    }

    fn warning(title: &str, detail: impl Into<String>, remedy: Option<String>) -> Self {
        Self {
            title: title.to_string(),
            status: CheckStatus::Warning,
            detail: detail.into(),
            remedy,
        }
    }

    fn blocked(title: &str, detail: impl Into<String>, remedy: Option<String>) -> Self {
        Self {
            title: title.to_string(),
            status: CheckStatus::Blocked,
            detail: detail.into(),
            remedy,
        }
    }
}

/// Runs every readiness check for the current settings.
pub fn run_checks(settings: &Settings) -> Vec<Check> {
    vec![
        check_hotkey(),
        check_injection(),
        check_local_runtime(settings),
        check_provider(settings),
    ]
}

fn check_hotkey() -> Check {
    let access = check_input_access();
    if access.is_available() {
        Check::ok(
            "Global hotkey",
            "The keyboard hook is installed. Note: windows of apps running as \
             Administrator only receive the hotkey if Whisper Smart also runs elevated.",
        )
    } else {
        Check::blocked("Global hotkey", access.message(), None)
    }
}

fn check_injection() -> Check {
    // SendInput and the clipboard are part of Win32; there is nothing to
    // install and no permission to grant.
    Check::ok(
        "Text insertion",
        "Typing via SendInput with a clipboard-paste fallback.",
    )
}

/// Reports the managed Python environment, which is the part of the install
/// most likely to need a decision from the user: Windows ships no Python, and
/// the Store's `python` alias is a stub.
fn check_local_runtime(settings: &Settings) -> Check {
    if python_runtime_ready() {
        return Check::ok(
            "Local runtime",
            format!("Installed at {}", paths::python_runtime_dir().display()),
        );
    }

    let base = crate::stt::runtime::select_base_python();
    let needed = settings.provider.kind.requires_python_runtime();

    match base {
        crate::stt::runtime::BasePython::Unsupported { .. } => {
            let detail = base.describe();
            let remedy = Some("winget install astral-sh.uv".to_string());
            if needed {
                Check::blocked("Local runtime", detail, remedy)
            } else {
                Check::warning("Local runtime", detail, remedy)
            }
        }
        base => {
            let detail = format!(
                "Not installed. Will use {} when you install it.",
                base.describe()
            );
            if needed {
                Check::blocked(
                    "Local runtime",
                    detail,
                    Some("Open Settings → Provider and run \"Install runtime\".".to_string()),
                )
            } else {
                Check::ok("Local runtime", detail)
            }
        }
    }
}

fn check_provider(settings: &Settings) -> Check {
    let kind = settings.provider.kind;
    match kind {
        ProviderKind::OpenAiApi => {
            if crate::core::credentials::has_openai_key() {
                Check::ok("Provider", "OpenAI API key is set.")
            } else {
                Check::blocked(
                    "Provider",
                    "The OpenAI API provider is selected but no API key is saved.",
                    None,
                )
            }
        }
        ProviderKind::WhisperCpp => {
            if whisper_cli_path().is_none() {
                return Check::blocked(
                    "Provider",
                    "whisper.cpp is selected but whisper-cli.exe is not installed.",
                    Some("Open Settings → Provider and press \"Install whisper.cpp\".".to_string()),
                );
            }
            model_check(settings)
        }
        ProviderKind::FasterWhisper | ProviderKind::Parakeet => {
            if kind.requires_python_runtime() && !python_runtime_ready() {
                return Check::blocked(
                    "Provider",
                    format!(
                        "{} needs its Python runtime installed before it can transcribe.",
                        kind.display_name()
                    ),
                    Some("Open Settings → Provider and run \"Install runtime\".".to_string()),
                );
            }
            model_check(settings)
        }
        ProviderKind::Stub => {
            Check::warning("Provider", "The stub provider never transcribes.", None)
        }
    }
}

fn model_check(settings: &Settings) -> Check {
    let Some(model) = settings.selected_model() else {
        return Check::ok("Provider", "Ready.");
    };
    if is_model_installed(&model) {
        Check::ok("Provider", format!("{} is installed.", model.display_name))
    } else {
        Check::blocked(
            "Provider",
            format!(
                "{} ({}) is not downloaded yet.",
                model.display_name, model.approx_size_label
            ),
            Some("Open Settings → Provider and download the model.".to_string()),
        )
    }
}

// ---------------------------------------------------------------------------
// Individual capability probes
// ---------------------------------------------------------------------------

/// Locates the whisper.cpp CLI: the copy the app manages first, then PATH for
/// anyone who installed their own (a CUDA build, say — the managed install is
/// the official CPU binary).
pub fn whisper_cli_path() -> Option<PathBuf> {
    let managed = paths::whisper_cpp_dir().join(exe("whisper-cli"));
    if managed.is_file() {
        return Some(managed);
    }
    for name in ["whisper-cli", "whisper-cpp"] {
        if let Some(path) = which_path(name) {
            return Some(path);
        }
    }
    None
}

/// The interpreter inside the app-managed virtualenv.
pub fn python_runtime_interpreter() -> PathBuf {
    crate::stt::runtime::interpreter_path()
}

pub fn python_runtime_ready() -> bool {
    crate::stt::runtime::is_installed()
}

/// Whether a model's weights are present on disk.
pub fn is_model_installed(model: &LocalModel) -> bool {
    match model.source {
        ModelSource::DirectFile { file_name, .. } => {
            let path = paths::models_dir().join(file_name);
            // A partial download leaves a small file behind; a real GGUF is
            // tens of megabytes at minimum, so treat a tiny file as absent.
            std::fs::metadata(path)
                .map(|m| m.len() > 1_000_000)
                .unwrap_or(false)
        }
        ModelSource::HuggingFaceRepo { repo } => hf_snapshot_dir(repo).is_some(),
    }
}

/// Locates a downloaded Hugging Face snapshot in the app's cache.
pub fn hf_snapshot_dir(repo: &str) -> Option<PathBuf> {
    // huggingface_hub lays out `models--org--name/snapshots/<revision>/`.
    let dir_name = format!("models--{}", repo.replace('/', "--"));
    let snapshots = paths::hf_cache_dir().join(dir_name).join("snapshots");
    let mut entries: Vec<PathBuf> = std::fs::read_dir(snapshots)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    // Newest revision last; any of them is loadable, so take one
    // deterministically rather than depending on directory order.
    entries.sort();
    entries.pop()
}

/// Best-effort CUDA availability probe, used to explain the compute-device
/// setting rather than to gate anything.
pub fn cuda_available() -> bool {
    let mut command = Command::new("nvidia-smi");
    command.arg("-L");
    crate::platform::hide_console(&mut command);
    command
        .output()
        .map(|out| out.status.success() && !out.stdout.is_empty())
        .unwrap_or(false)
}

/// Appends `.exe` on Windows so path probes and `is_file` checks work; left
/// alone elsewhere so the crate still builds on development hosts.
pub fn exe(name: &str) -> String {
    if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.to_string()
    }
}

fn which_path(binary: &str) -> Option<PathBuf> {
    let paths = std::env::var_os("PATH")?;
    let with_ext = exe(binary);
    std::env::split_paths(&paths)
        .flat_map(|dir| [dir.join(&with_ext), dir.join(binary)])
        .find(|p| p.is_file())
}

// ---------------------------------------------------------------------------
// Provider fallback resolution
// ---------------------------------------------------------------------------

/// The provider that will actually run, and why it differs from the request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderResolution {
    pub requested: ProviderKind,
    pub effective: ProviderKind,
    /// Set only when `effective != requested`.
    pub fallback_reason: Option<String>,
}

impl ProviderResolution {
    pub fn did_fall_back(&self) -> bool {
        self.effective != self.requested
    }
}

/// Inputs to [`resolve_provider`], separated from the probes so the resolution
/// rules can be tested without a real machine underneath.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Capabilities {
    pub whisper_cli_installed: bool,
    pub python_runtime_ready: bool,
    pub selected_model_installed: bool,
    pub openai_key_present: bool,
}

impl Capabilities {
    /// Probes the real machine.
    pub fn probe(settings: &Settings) -> Self {
        Self {
            whisper_cli_installed: whisper_cli_path().is_some(),
            python_runtime_ready: python_runtime_ready(),
            selected_model_installed: settings
                .selected_model()
                .map(|m| is_model_installed(&m))
                .unwrap_or(true),
            openai_key_present: crate::core::credentials::has_openai_key(),
        }
    }
}

/// Decides which provider to actually start.
///
/// Mirrors the macOS fallback rules, with the same deliberate change the
/// Linux build made: macOS falls back to Apple Speech, which is always
/// present. Windows has no such universal engine, so an unusable local
/// provider falls back to the cloud *only* when the user opted in and
/// supplied a key. Otherwise the request stands and the provider surfaces a
/// real error, because silently routing a user's audio to a third party would
/// be a far worse outcome than a clear failure.
pub fn resolve_provider(
    requested: ProviderKind,
    caps: Capabilities,
    cloud_fallback_enabled: bool,
) -> ProviderResolution {
    let blocker: Option<String> = match requested {
        ProviderKind::WhisperCpp => {
            if !caps.whisper_cli_installed {
                Some("whisper-cli.exe is not installed".to_string())
            } else if !caps.selected_model_installed {
                Some("the selected model has not been downloaded".to_string())
            } else {
                None
            }
        }
        ProviderKind::FasterWhisper | ProviderKind::Parakeet => {
            if !caps.python_runtime_ready {
                Some("the local inference runtime is not installed".to_string())
            } else if !caps.selected_model_installed {
                Some("the selected model has not been downloaded".to_string())
            } else {
                None
            }
        }
        ProviderKind::OpenAiApi => {
            if caps.openai_key_present {
                None
            } else {
                Some("no OpenAI API key is saved".to_string())
            }
        }
        ProviderKind::Stub => None,
    };

    let Some(blocker) = blocker else {
        return ProviderResolution {
            requested,
            effective: requested,
            fallback_reason: None,
        };
    };

    // A cloud provider has nowhere local to fall back to.
    if requested.is_cloud() {
        return ProviderResolution {
            requested,
            effective: requested,
            fallback_reason: None,
        };
    }

    if cloud_fallback_enabled && caps.openai_key_present {
        return ProviderResolution {
            requested,
            effective: ProviderKind::OpenAiApi,
            fallback_reason: Some(format!(
                "{} is unavailable because {blocker}. Using the OpenAI API instead.",
                requested.display_name()
            )),
        };
    }

    ProviderResolution {
        requested,
        effective: requested,
        fallback_reason: None,
    }
}

/// Human-readable reason a provider cannot start, for the error state.
pub fn unavailable_reason(requested: ProviderKind, caps: Capabilities) -> Option<String> {
    match requested {
        ProviderKind::WhisperCpp if !caps.whisper_cli_installed => Some(
            "whisper-cli.exe is not installed. Open Settings → Provider and press \
             \"Install whisper.cpp\"."
                .to_string(),
        ),
        ProviderKind::FasterWhisper | ProviderKind::Parakeet if !caps.python_runtime_ready => Some(
            "The local inference runtime is not installed. Open Settings → Provider to install it."
                .to_string(),
        ),
        ProviderKind::OpenAiApi if !caps.openai_key_present => {
            Some("No OpenAI API key is saved. Add one in Settings → Provider.".to_string())
        }
        _ if requested.requires_model_download() && !caps.selected_model_installed => Some(
            "The selected model has not been downloaded. Open Settings → Provider to download it."
                .to_string(),
        ),
        _ => None,
    }
}

/// The engine label shown in the UI for the active provider.
pub fn engine_label(kind: ProviderKind) -> String {
    match kind.engine() {
        Some(ModelEngine::WhisperCpp) => "whisper.cpp".to_string(),
        Some(ModelEngine::FasterWhisper) => "CTranslate2".to_string(),
        Some(ModelEngine::ParakeetOnnx) => "ONNX Runtime".to_string(),
        None => kind.display_name().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_ready() -> Capabilities {
        Capabilities {
            whisper_cli_installed: true,
            python_runtime_ready: true,
            selected_model_installed: true,
            openai_key_present: true,
        }
    }

    #[test]
    fn a_ready_provider_is_used_as_requested() {
        let resolution = resolve_provider(ProviderKind::WhisperCpp, all_ready(), true);
        assert_eq!(resolution.effective, ProviderKind::WhisperCpp);
        assert!(!resolution.did_fall_back());
        assert_eq!(resolution.fallback_reason, None);
    }

    #[test]
    fn a_missing_binary_falls_back_to_the_cloud_when_opted_in() {
        let caps = Capabilities {
            whisper_cli_installed: false,
            ..all_ready()
        };
        let resolution = resolve_provider(ProviderKind::WhisperCpp, caps, true);
        assert_eq!(resolution.effective, ProviderKind::OpenAiApi);
        assert!(resolution
            .fallback_reason
            .is_some_and(|r| r.contains("whisper-cli")));
    }

    #[test]
    fn audio_is_never_sent_to_the_cloud_without_opt_in() {
        // The single most important rule in this file: a broken local setup
        // must never silently start uploading the user's microphone.
        let caps = Capabilities {
            whisper_cli_installed: false,
            ..all_ready()
        };
        let resolution = resolve_provider(ProviderKind::WhisperCpp, caps, false);
        assert_eq!(resolution.effective, ProviderKind::WhisperCpp);
        assert!(!resolution.did_fall_back());
    }

    #[test]
    fn cloud_fallback_without_a_key_does_not_fall_back() {
        let caps = Capabilities {
            whisper_cli_installed: false,
            openai_key_present: false,
            ..all_ready()
        };
        let resolution = resolve_provider(ProviderKind::WhisperCpp, caps, true);
        assert_eq!(resolution.effective, ProviderKind::WhisperCpp);
    }

    #[test]
    fn a_missing_model_blocks_a_local_provider() {
        let caps = Capabilities {
            selected_model_installed: false,
            ..all_ready()
        };
        let resolution = resolve_provider(ProviderKind::Parakeet, caps, true);
        assert_eq!(resolution.effective, ProviderKind::OpenAiApi);
        assert!(resolution
            .fallback_reason
            .is_some_and(|r| r.contains("downloaded")));
    }

    #[test]
    fn a_missing_python_runtime_blocks_the_python_backed_providers() {
        let caps = Capabilities {
            python_runtime_ready: false,
            ..all_ready()
        };
        for kind in [ProviderKind::FasterWhisper, ProviderKind::Parakeet] {
            let resolution = resolve_provider(kind, caps, true);
            assert_eq!(resolution.effective, ProviderKind::OpenAiApi, "{kind:?}");
        }
        // whisper.cpp needs no Python, so it is unaffected.
        let resolution = resolve_provider(ProviderKind::WhisperCpp, caps, true);
        assert_eq!(resolution.effective, ProviderKind::WhisperCpp);
    }

    #[test]
    fn the_cloud_provider_has_nowhere_to_fall_back_to() {
        let caps = Capabilities {
            openai_key_present: false,
            ..all_ready()
        };
        let resolution = resolve_provider(ProviderKind::OpenAiApi, caps, true);
        assert_eq!(resolution.effective, ProviderKind::OpenAiApi);
        assert_eq!(
            resolution.fallback_reason, None,
            "a fallback loop would be nonsense"
        );
    }

    #[test]
    fn unavailable_reasons_name_the_fix() {
        let caps = Capabilities {
            whisper_cli_installed: false,
            ..all_ready()
        };
        let reason = unavailable_reason(ProviderKind::WhisperCpp, caps).unwrap();
        assert!(reason.contains("Install whisper.cpp"));

        let caps = Capabilities {
            openai_key_present: false,
            ..all_ready()
        };
        let reason = unavailable_reason(ProviderKind::OpenAiApi, caps).unwrap();
        assert!(reason.contains("API key"));
    }

    #[test]
    fn a_ready_provider_has_no_unavailable_reason() {
        for kind in ProviderKind::all() {
            assert_eq!(unavailable_reason(kind, all_ready()), None, "{kind:?}");
        }
    }

    #[test]
    fn engine_labels_are_distinct_per_local_engine() {
        assert_eq!(engine_label(ProviderKind::WhisperCpp), "whisper.cpp");
        assert_eq!(engine_label(ProviderKind::FasterWhisper), "CTranslate2");
        assert_eq!(engine_label(ProviderKind::Parakeet), "ONNX Runtime");
    }

    #[test]
    fn exe_names_gain_the_suffix_only_on_windows() {
        let name = exe("whisper-cli");
        if cfg!(windows) {
            assert_eq!(name, "whisper-cli.exe");
        } else {
            assert_eq!(name, "whisper-cli");
        }
    }
}
