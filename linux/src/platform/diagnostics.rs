//! Readiness checks and provider fallback resolution.
//!
//! Combines the roles of `PermissionDiagnostics.swift` (can the app actually
//! do its job?) and `STTProviderDiagnostics.swift` (is the selected provider
//! usable, and if not, what should run instead?).
//!
//! The macOS checks are about TCC permissions: Accessibility, Microphone,
//! Speech Recognition. Linux has no equivalent prompts, so the questions that
//! matter here are different — is this user allowed to read input devices, are
//! the injection tools installed, is the engine's runtime present — but the
//! shape is the same: a list of checks, each with a plain-language fix.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::core::model_catalog::{LocalModel, ModelEngine, ModelSource};
use crate::core::paths;
use crate::core::provider::ProviderKind;
use crate::core::settings::Settings;
use crate::platform::hotkey::{check_input_access, InputAccess};
use crate::platform::injector;

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
    /// A shell command that fixes it, when there is one.
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
        check_input_devices(),
        check_injection_tools(),
        check_session(),
        check_local_runtime(settings),
        check_provider(settings),
    ]
}

fn check_input_devices() -> Check {
    match check_input_access() {
        InputAccess::Available { keyboards } => Check::ok(
            "Global hotkey",
            format!("Reading {} keyboard(s).", keyboards.len()),
        ),
        access @ InputAccess::PermissionDenied => Check::blocked(
            "Global hotkey",
            access.message(),
            Some("sudo usermod -aG input $USER".to_string()),
        ),
        access @ InputAccess::NoKeyboards => {
            Check::blocked("Global hotkey", access.message(), None)
        }
    }
}

fn check_injection_tools() -> Check {
    let tools = injector::available_tools();
    if tools.wtype && tools.wl_copy && tools.wl_paste {
        Check::ok("Text insertion", "wtype and wl-clipboard are installed.")
    } else if tools.any_strategy_available() {
        Check::warning(
            "Text insertion",
            "Only one insertion strategy is available; the fallback will not work.",
            tools.missing_summary(),
        )
    } else {
        Check::blocked(
            "Text insertion",
            "Neither wtype nor wl-clipboard is installed, so transcripts cannot be inserted.",
            tools.missing_summary(),
        )
    }
}

/// Wayland's virtual-keyboard protocol is what `wtype` needs. Most wlroots
/// compositors (Hyprland, Sway) implement it; GNOME notably does not.
fn check_session() -> Check {
    let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
    let desktop = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default();

    if !wayland {
        return Check::warning(
            "Desktop session",
            "Not a Wayland session. Text insertion will need xdotool instead of wtype.",
            Some("sudo pacman -S xdotool".to_string()),
        );
    }

    if desktop.to_ascii_lowercase().contains("gnome") {
        return Check::warning(
            "Desktop session",
            "GNOME does not implement the virtual-keyboard protocol, so typing will fail and \
             Whisper Smart will fall back to clipboard paste.",
            None,
        );
    }

    Check::ok("Desktop session", format!("Wayland session on {desktop}."))
}

/// Reports the managed Python environment, which is the part of a Linux
/// install most likely to need a decision from the user: rolling distros ship
/// CPython releases months before the speech engines have wheels for them.
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
            let remedy = Some("sudo pacman -S uv".to_string());
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
                    Some(
                        "Open Settings \u{2192} Provider and run \"Install runtime\".".to_string(),
                    ),
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
                    "whisper.cpp is selected but the whisper-cli binary was not found.",
                    Some("sudo pacman -S whisper-cpp".to_string()),
                );
            }
            if !ggml_backend_available() {
                return Check::blocked(
                    "Provider",
                    "whisper-cli is installed but ggml has no compute backend, so loading a \
                     model will abort. Arch ships the backends as separate packages.",
                    Some(
                        "sudo pacman -S ggml-cpu        # add ggml-cuda for NVIDIA GPUs"
                            .to_string(),
                    ),
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

/// Locates the whisper.cpp CLI. Arch's `whisper.cpp` package installs it as
/// `whisper-cli`; upstream builds have historically called it `main`, and some
/// distros ship `whisper-cpp`.
pub fn whisper_cli_path() -> Option<PathBuf> {
    for name in ["whisper-cli", "whisper-cpp", "whisper.cpp"] {
        if let Some(path) = which_path(name) {
            return Some(path);
        }
    }
    None
}

/// Directories ggml searches for its dynamically-loaded compute backends.
///
/// ggml ships `libggml-base.so` with no compute backend of its own and loads
/// one at runtime. Distributions that split those into separate packages —
/// Arch has `ggml-cpu`, `ggml-cuda`, `ggml-vulkan`, and friends — leave a
/// perfectly installed `whisper-cli` that aborts with `GGML_ASSERT(device)`
/// the moment it loads a model. Detecting that here turns a stack trace into a
/// one-line fix.
fn ggml_backend_search_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();

    // ggml honours this override first.
    if let Some(explicit) = std::env::var_os("GGML_BACKEND_PATH") {
        paths.push(PathBuf::from(explicit));
    }

    for prefix in ["/usr/lib", "/usr/lib64", "/usr/local/lib", "/lib"] {
        paths.push(PathBuf::from(prefix).join("ggml"));
    }

    // A whisper-cli installed under a custom prefix keeps its backends beside
    // it rather than in /usr.
    if let Some(binary) = whisper_cli_path() {
        if let Some(prefix) = binary.parent().and_then(Path::parent) {
            paths.push(prefix.join("lib/ggml"));
        }
    }

    paths
}

/// True when at least one ggml compute backend is installed.
pub fn ggml_backend_available() -> bool {
    ggml_backend_search_paths()
        .iter()
        .any(|dir| directory_has_backend(dir))
}

/// A backend is any `libggml-*.so` other than the base library itself, which
/// provides no compute device.
fn directory_has_backend(dir: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        name.starts_with("libggml-") && name.contains(".so") && !name.starts_with("libggml-base")
    })
}

/// The interpreter inside the app-managed virtualenv.
pub fn python_runtime_interpreter() -> PathBuf {
    paths::python_runtime_dir().join("bin/python")
}

pub fn python_runtime_ready() -> bool {
    python_runtime_interpreter().is_file()
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
    Command::new("nvidia-smi")
        .arg("-L")
        .output()
        .map(|out| out.status.success() && !out.stdout.is_empty())
        .unwrap_or(false)
}

fn which_path(binary: &str) -> Option<PathBuf> {
    let paths = std::env::var_os("PATH")?;
    std::env::split_paths(&paths)
        .map(|dir| dir.join(binary))
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
    /// whisper-cli is present *and* ggml has a compute backend to run on.
    pub ggml_backend_installed: bool,
    pub python_runtime_ready: bool,
    pub selected_model_installed: bool,
    pub openai_key_present: bool,
}

impl Capabilities {
    /// Probes the real machine.
    pub fn probe(settings: &Settings) -> Self {
        Self {
            whisper_cli_installed: whisper_cli_path().is_some(),
            ggml_backend_installed: ggml_backend_available(),
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
/// Mirrors the macOS fallback rules, with one deliberate change: macOS falls
/// back to Apple Speech, which is always present. Linux has no such universal
/// engine, so an unusable local provider falls back to the cloud *only* when
/// the user opted in and supplied a key. Otherwise the request stands and the
/// provider surfaces a real error, because silently routing a user's audio to
/// a third party would be a far worse outcome than a clear failure.
pub fn resolve_provider(
    requested: ProviderKind,
    caps: Capabilities,
    cloud_fallback_enabled: bool,
) -> ProviderResolution {
    let blocker: Option<String> = match requested {
        ProviderKind::WhisperCpp => {
            if !caps.whisper_cli_installed {
                Some("the whisper-cli binary is not installed".to_string())
            } else if !caps.ggml_backend_installed {
                Some("ggml has no compute backend installed".to_string())
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
            "whisper-cli is not installed. Install it with: sudo pacman -S whisper-cpp".to_string(),
        ),
        ProviderKind::WhisperCpp if !caps.ggml_backend_installed => Some(
            "ggml has no compute backend, so whisper-cli cannot load a model. \
             Install one with: sudo pacman -S ggml-cpu (add ggml-cuda for NVIDIA GPUs)"
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
            ggml_backend_installed: true,
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
        assert!(reason.contains("pacman -S whisper-cpp"));

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
    fn an_installed_whisper_cli_without_a_ggml_backend_is_still_blocked() {
        // The failure this guards against is a `GGML_ASSERT(device)` abort at
        // model load, which tells the user nothing useful on its own.
        let caps = Capabilities {
            ggml_backend_installed: false,
            ..all_ready()
        };
        let reason = unavailable_reason(ProviderKind::WhisperCpp, caps).unwrap();
        assert!(
            reason.contains("ggml-cpu"),
            "the fix should name the package: {reason}"
        );

        let resolution = resolve_provider(ProviderKind::WhisperCpp, caps, true);
        assert_eq!(resolution.effective, ProviderKind::OpenAiApi);
    }

    #[test]
    fn a_missing_ggml_backend_does_not_affect_the_other_engines() {
        let caps = Capabilities {
            ggml_backend_installed: false,
            ..all_ready()
        };
        for kind in [
            ProviderKind::FasterWhisper,
            ProviderKind::Parakeet,
            ProviderKind::OpenAiApi,
        ] {
            assert_eq!(unavailable_reason(kind, caps), None, "{kind:?}");
        }
    }

    #[test]
    fn the_base_library_alone_does_not_count_as_a_backend() {
        let dir = std::env::temp_dir().join(format!("ws-ggml-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("libggml-base.so"), b"").unwrap();
        assert!(
            !directory_has_backend(&dir),
            "libggml-base provides no compute device"
        );

        std::fs::write(dir.join("libggml-cpu-haswell.so"), b"").unwrap();
        assert!(directory_has_backend(&dir));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_directory_that_does_not_exist_has_no_backend() {
        assert!(!directory_has_backend(Path::new("/nonexistent/ggml")));
    }

    #[test]
    fn the_backend_search_covers_the_standard_prefixes() {
        let paths = ggml_backend_search_paths();
        assert!(paths.iter().any(|p| p == Path::new("/usr/lib/ggml")));
    }
}
