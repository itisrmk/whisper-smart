//! Managed Python runtime and model installation.
//!
//! Port of `MLXRuntimeBootstrapManager.swift` and `MLXModelInstaller.swift`.
//! The macOS build creates a virtualenv under Application Support and pip
//! installs `parakeet-mlx` / `mlx-whisper` into it. The same approach is used
//! here, for the same reason: the app must not depend on whatever the user's
//! system Python happens to contain, and it must not pollute it either.
//!
//! One Linux-specific wrinkle drives most of this file. Machine-learning wheels
//! lag new CPython releases by months, and rolling distros ship those releases
//! immediately — an Arch system today has Python 3.14, which has no
//! `ctranslate2` or `onnxruntime` wheel. So the base interpreter is *chosen*
//! rather than assumed: a `uv`-managed 3.12 first, then any supported system
//! interpreter, and only then whatever `python3` is. Picking wrong here is the
//! difference between a working install and an inscrutable pip error.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::core::model_catalog::{LocalModel, ModelEngine, ModelSource};
use crate::core::paths;
use crate::core::settings::ComputeDevice;

/// CPython versions with reliable wheel coverage for the STT stack, best first.
const PREFERRED_PYTHONS: &[&str] = &["python3.12", "python3.11", "python3.13", "python3.10"];

/// The version `uv` is asked to provision when no suitable system Python exists.
const UV_PYTHON_VERSION: &str = "3.12";

/// Progress reported during a long-running install.
#[derive(Debug, Clone, PartialEq)]
pub enum Progress {
    /// A named step began, e.g. "Creating the Python environment".
    Step(String),
    /// Fractional progress in 0..=1 for the current step, when known.
    Fraction(f32),
    Done,
    Failed(String),
}

/// Callback invoked as an install proceeds.
pub type ProgressSink = Box<dyn Fn(Progress) + Send>;

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// The virtualenv's interpreter.
///
/// `WHISPER_SMART_PYTHON` overrides it, for developers who would rather bring
/// their own environment than have the app build one.
pub fn interpreter_path() -> PathBuf {
    if let Some(override_path) = std::env::var_os("WHISPER_SMART_PYTHON") {
        let path = PathBuf::from(override_path);
        if path.is_file() {
            return path;
        }
    }
    paths::python_runtime_dir().join("bin/python")
}

pub fn is_installed() -> bool {
    interpreter_path().is_file()
}

/// Locates `stt_daemon.py`.
///
/// Checked in order: an explicit override (used by the dev runner and tests),
/// the packaged location next to the binary, the system data directory, and
/// finally the source tree so `cargo run` works from a checkout.
pub fn daemon_script_path() -> Option<PathBuf> {
    if let Some(override_path) = std::env::var_os("WHISPER_SMART_STT_SCRIPT") {
        let path = PathBuf::from(override_path);
        if path.is_file() {
            return Some(path);
        }
    }

    let mut candidates: Vec<PathBuf> = Vec::new();

    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join("stt_daemon.py"));
            // /usr/bin/whisper-smart -> /usr/lib/whisper-smart/stt_daemon.py
            if let Some(prefix) = dir.parent() {
                candidates.push(prefix.join("lib/whisper-smart/stt_daemon.py"));
                candidates.push(prefix.join("share/whisper-smart/stt_daemon.py"));
            }
        }
    }

    candidates.push(paths::data_dir().join("stt_daemon.py"));
    candidates.push(PathBuf::from("/usr/lib/whisper-smart/stt_daemon.py"));
    candidates.push(PathBuf::from("python/stt_daemon.py"));
    candidates.push(PathBuf::from("linux/python/stt_daemon.py"));

    candidates.into_iter().find(|p| p.is_file())
}

/// Points Hugging Face at the app's own cache, so uninstalling reclaims the
/// weights rather than orphaning gigabytes under `~/.cache/huggingface`.
pub fn apply_environment(command: &mut Command) {
    let cache = paths::hf_cache_dir();
    let _ = std::fs::create_dir_all(&cache);
    command
        .env("HF_HOME", &cache)
        .env("HF_HUB_CACHE", &cache)
        // Progress bars are parsed from stdout; the fancy renderer would
        // interleave escape codes into them.
        .env("HF_HUB_DISABLE_TELEMETRY", "1")
        .env("PYTHONUNBUFFERED", "1");
}

// ---------------------------------------------------------------------------
// Interpreter selection
// ---------------------------------------------------------------------------

/// How the base interpreter for the virtualenv was found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BasePython {
    /// A `uv`-managed interpreter, provisioned on demand.
    Uv { version: String },
    /// A suitable interpreter already on `PATH`.
    System { path: PathBuf, version: String },
    /// Nothing suitable was found.
    Unsupported { found: Option<String> },
}

impl BasePython {
    pub fn describe(&self) -> String {
        match self {
            BasePython::Uv { version } => format!("uv-managed Python {version}"),
            BasePython::System { path, version } => {
                format!("Python {version} ({})", path.display())
            }
            BasePython::Unsupported { found } => match found {
                Some(v) => format!(
                    "Python {v} has no wheels for the speech engines. \
                     Install uv (sudo pacman -S uv) or python3.12, then try again."
                ),
                None => "No Python interpreter was found.".to_string(),
            },
        }
    }
}

/// Chooses the interpreter to build the virtualenv from.
pub fn select_base_python() -> BasePython {
    for name in PREFERRED_PYTHONS {
        if let Some(path) = which(name) {
            if let Some(version) = python_version(&path) {
                if version_is_supported(&version) {
                    return BasePython::System { path, version };
                }
            }
        }
    }

    // `uv` can provision a suitable interpreter even when the system has none.
    if which("uv").is_some() {
        return BasePython::Uv {
            version: UV_PYTHON_VERSION.to_string(),
        };
    }

    // Last resort: whatever python3 is, if its version is actually supported.
    if let Some(path) = which("python3") {
        if let Some(version) = python_version(&path) {
            if version_is_supported(&version) {
                return BasePython::System { path, version };
            }
            return BasePython::Unsupported {
                found: Some(version),
            };
        }
    }

    BasePython::Unsupported { found: None }
}

/// Wheel coverage for the STT stack, as of this release.
pub fn version_is_supported(version: &str) -> bool {
    let mut parts = version.split('.');
    let (Some(major), Some(minor)) = (parts.next(), parts.next()) else {
        return false;
    };
    let (Ok(major), Ok(minor)) = (major.parse::<u32>(), minor.parse::<u32>()) else {
        return false;
    };
    // 3.14 is excluded deliberately: it is what a current Arch system ships,
    // and neither ctranslate2 nor onnxruntime publishes wheels for it yet.
    major == 3 && (10..=13).contains(&minor)
}

fn python_version(path: &Path) -> Option<String> {
    let output = Command::new(path)
        .args(["-c", "import sys; print('%d.%d.%d' % sys.version_info[:3])"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn which(binary: &str) -> Option<PathBuf> {
    let paths = std::env::var_os("PATH")?;
    std::env::split_paths(&paths)
        .map(|dir| dir.join(binary))
        .find(|p| p.is_file())
}

// ---------------------------------------------------------------------------
// Package sets
// ---------------------------------------------------------------------------

/// The pip requirements for an engine.
///
/// GPU support differs per engine and is the fiddliest part of a Linux install:
/// CTranslate2 bundles its CUDA kernels and pulls the NVIDIA runtime in as pip
/// dependencies, while ONNX Runtime ships CPU and GPU as two different
/// distributions that must not both be installed.
pub fn packages_for(engine: ModelEngine, device: ComputeDevice) -> Vec<String> {
    let mut packages: Vec<String> = vec!["huggingface_hub".into(), "numpy".into()];

    match engine {
        ModelEngine::FasterWhisper => {
            packages.push("faster-whisper".into());
            if device != ComputeDevice::Cpu {
                // CTranslate2's CUDA build needs these at load time; pip is the
                // only sane way to get versions that match the wheel.
                packages.push("nvidia-cublas-cu12".into());
                packages.push("nvidia-cudnn-cu12".into());
            }
        }
        ModelEngine::ParakeetOnnx => {
            packages.push("onnx-asr".into());
            if device == ComputeDevice::Cpu {
                packages.push("onnxruntime".into());
            } else {
                packages.push("onnxruntime-gpu".into());
            }
        }
        ModelEngine::WhisperCpp => {
            // Nothing: whisper.cpp is a native binary with no Python at all.
            return Vec::new();
        }
    }

    packages
}

// ---------------------------------------------------------------------------
// Installation
// ---------------------------------------------------------------------------

/// Creates the virtualenv and installs the packages for `engine`.
///
/// Blocking; intended to be called from a worker thread with `progress`
/// marshalling updates back to the UI.
pub fn install(
    engine: ModelEngine,
    device: ComputeDevice,
    progress: &ProgressSink,
) -> Result<(), String> {
    if engine == ModelEngine::WhisperCpp {
        return Err("whisper.cpp needs no Python runtime.".to_string());
    }

    let venv = paths::python_runtime_dir();
    std::fs::create_dir_all(venv.parent().unwrap_or(&venv))
        .map_err(|e| format!("Could not create the runtime directory: {e}"))?;

    if !is_installed() {
        let base = select_base_python();
        progress(Progress::Step(format!("Preparing {}", base.describe())));

        match &base {
            BasePython::Unsupported { .. } => return Err(base.describe()),
            BasePython::Uv { version } => {
                run_logged(
                    Command::new("uv")
                        .args(["venv", "--python", version])
                        .arg(&venv),
                    "creating the Python environment",
                )?;
            }
            BasePython::System { path, .. } => {
                run_logged(
                    Command::new(path).args(["-m", "venv"]).arg(&venv),
                    "creating the Python environment",
                )?;
            }
        }
    }

    let packages = packages_for(engine, device);
    if packages.is_empty() {
        progress(Progress::Done);
        return Ok(());
    }

    progress(Progress::Step("Installing the speech engine".to_string()));

    let mut command = Command::new(interpreter_path());
    command
        .args([
            "-m",
            "pip",
            "install",
            "--upgrade",
            "--disable-pip-version-check",
        ])
        .args(&packages);
    apply_environment(&mut command);

    run_logged(&mut command, "installing the speech engine")?;

    // Verify rather than trust the exit code: a wheel can install and still
    // fail to import (a mismatched CUDA runtime is the usual culprit).
    progress(Progress::Step("Verifying the installation".to_string()));
    verify(engine)?;

    progress(Progress::Done);
    Ok(())
}

/// Runs the sidecar's `--check` mode to confirm the engine actually imports.
pub fn verify(engine: ModelEngine) -> Result<(), String> {
    let script = daemon_script_path()
        .ok_or_else(|| "The STT sidecar script is missing from the installation.".to_string())?;
    let engine_arg = match engine {
        ModelEngine::FasterWhisper => "faster-whisper",
        ModelEngine::ParakeetOnnx => "parakeet",
        ModelEngine::WhisperCpp => return Ok(()),
    };

    let mut command = Command::new(interpreter_path());
    command
        .arg(&script)
        .arg("--check")
        .args(["--engine", engine_arg]);
    apply_environment(&mut command);

    let output = command
        .output()
        .map_err(|e| format!("Could not verify the installation: {e}"))?;

    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let detail = stderr
        .lines()
        .rev()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("unknown error");
    Err(format!(
        "The speech engine installed but could not be loaded: {}",
        detail.trim()
    ))
}

/// Deletes the managed virtualenv.
pub fn uninstall() -> Result<(), String> {
    let venv = paths::python_runtime_dir();
    match std::fs::remove_dir_all(&venv) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(format!("Could not remove the runtime: {err}")),
    }
}

fn run_logged(command: &mut Command, what: &str) -> Result<(), String> {
    tracing::info!("{what}...");
    let output = command
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("Failed while {what}: {e}"))?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    for line in stderr.lines() {
        tracing::error!("  {line}");
    }
    let detail = stderr
        .lines()
        .rev()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("unknown error");
    Err(format!("Failed while {what}: {}", detail.trim()))
}

// ---------------------------------------------------------------------------
// Model installation
// ---------------------------------------------------------------------------

/// Downloads a model's weights.
///
/// Direct-file models (whisper.cpp GGUF) are fetched over plain HTTPS so they
/// work with no Python at all; Hugging Face repos go through the sidecar,
/// which reports aggregate `PROGRESS` lines that drive the UI's progress bar.
pub fn download_model(model: &LocalModel, progress: &ProgressSink) -> Result<(), String> {
    progress(Progress::Step(format!(
        "Downloading {}",
        model.display_name
    )));

    let result = match model.source {
        ModelSource::DirectFile { url, file_name } => download_direct(url, file_name, progress),
        ModelSource::HuggingFaceRepo { repo } => download_via_sidecar(model.engine, repo, progress),
    };

    match result {
        Ok(()) => {
            progress(Progress::Done);
            Ok(())
        }
        Err(err) => {
            progress(Progress::Failed(err.clone()));
            Err(err)
        }
    }
}

fn download_direct(url: &str, file_name: &str, progress: &ProgressSink) -> Result<(), String> {
    let dir = paths::models_dir();
    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("Could not create the model directory: {e}"))?;

    let final_path = dir.join(file_name);
    // Download to a partial file and rename on success, so an interrupted
    // download can never masquerade as an installed model.
    let partial_path = dir.join(format!("{file_name}.partial"));

    let mut response = ureq::get(url)
        .call()
        .map_err(|e| format!("Could not download the model: {e}"))?;

    let total: u64 = response
        .headers()
        .get("content-length")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);

    let mut reader = response.body_mut().as_reader();
    let mut file = std::fs::File::create(&partial_path)
        .map_err(|e| format!("Could not write the model file: {e}"))?;

    let mut buffer = vec![0u8; 1 << 20];
    let mut written: u64 = 0;
    let mut last_reported = 0.0f32;

    loop {
        let read = std::io::Read::read(&mut reader, &mut buffer)
            .map_err(|e| format!("The model download was interrupted: {e}"))?;
        if read == 0 {
            break;
        }
        file.write_all(&buffer[..read])
            .map_err(|e| format!("Could not write the model file: {e}"))?;
        written += read as u64;

        if total > 0 {
            let fraction = (written as f32 / total as f32).min(1.0);
            // Throttle: a 1.6 GB download would otherwise emit thousands of
            // updates and swamp the UI thread.
            if fraction - last_reported >= 0.01 {
                last_reported = fraction;
                progress(Progress::Fraction(fraction));
            }
        }
    }

    file.sync_all()
        .map_err(|e| format!("Could not finish writing the model: {e}"))?;
    drop(file);

    std::fs::rename(&partial_path, &final_path)
        .map_err(|e| format!("Could not finalise the model file: {e}"))?;
    progress(Progress::Fraction(1.0));
    Ok(())
}

fn download_via_sidecar(
    engine: ModelEngine,
    repo: &str,
    progress: &ProgressSink,
) -> Result<(), String> {
    if !is_installed() {
        return Err("Install the local inference runtime before downloading a model.".to_string());
    }
    let script = daemon_script_path()
        .ok_or_else(|| "The STT sidecar script is missing from the installation.".to_string())?;
    let engine_arg = match engine {
        ModelEngine::FasterWhisper => "faster-whisper",
        ModelEngine::ParakeetOnnx => "parakeet",
        ModelEngine::WhisperCpp => return Err("whisper.cpp models download directly.".to_string()),
    };

    let mut command = Command::new(interpreter_path());
    command
        .arg("-u")
        .arg(&script)
        .arg("--download")
        .args(["--engine", engine_arg])
        .args(["--model", repo])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    apply_environment(&mut command);

    let mut child = command
        .spawn()
        .map_err(|e| format!("Could not start the model download: {e}"))?;

    if let Some(stdout) = child.stdout.take() {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let Some(fraction) = parse_progress_line(&line) {
                progress(Progress::Fraction(fraction));
            }
        }
    }

    let mut stderr_tail = String::new();
    if let Some(stderr) = child.stderr.take() {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            tracing::debug!("[download] {line}");
            if !line.trim().is_empty() {
                stderr_tail = line;
            }
        }
    }

    let status = child
        .wait()
        .map_err(|e| format!("The model download failed: {e}"))?;
    if status.success() {
        Ok(())
    } else if stderr_tail.is_empty() {
        Err("The model download failed.".to_string())
    } else {
        Err(format!("The model download failed: {stderr_tail}"))
    }
}

/// Parses a `PROGRESS <fraction>` line from the sidecar.
fn parse_progress_line(line: &str) -> Option<f32> {
    let rest = line.trim().strip_prefix("PROGRESS ")?;
    let value: f32 = rest.trim().parse().ok()?;
    if value.is_finite() {
        Some(value.clamp(0.0, 1.0))
    } else {
        None
    }
}

/// Removes a downloaded model's files.
pub fn remove_model(model: &LocalModel) -> Result<(), String> {
    match model.source {
        ModelSource::DirectFile { file_name, .. } => {
            let path = paths::models_dir().join(file_name);
            match std::fs::remove_file(&path) {
                Ok(()) => Ok(()),
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(err) => Err(format!("Could not remove the model: {err}")),
            }
        }
        ModelSource::HuggingFaceRepo { repo } => {
            let dir_name = format!("models--{}", repo.replace('/', "--"));
            let path = paths::hf_cache_dir().join(dir_name);
            match std::fs::remove_dir_all(&path) {
                Ok(()) => Ok(()),
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(err) => Err(format!("Could not remove the model: {err}")),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn supported_python_versions_exclude_ones_without_wheels() {
        assert!(version_is_supported("3.12.7"));
        assert!(version_is_supported("3.11.9"));
        assert!(version_is_supported("3.13.0"));
        // The version an up-to-date Arch install ships: no ML wheels yet.
        assert!(!version_is_supported("3.14.7"));
        assert!(!version_is_supported("3.9.18"));
        assert!(!version_is_supported("2.7.18"));
    }

    #[test]
    fn malformed_version_strings_are_rejected_rather_than_panicking() {
        assert!(!version_is_supported(""));
        assert!(!version_is_supported("python3"));
        assert!(!version_is_supported("3"));
        assert!(!version_is_supported("x.y.z"));
    }

    #[test]
    fn faster_whisper_gets_cuda_libraries_only_when_a_gpu_is_wanted() {
        let gpu = packages_for(ModelEngine::FasterWhisper, ComputeDevice::Auto);
        assert!(gpu.iter().any(|p| p == "faster-whisper"));
        assert!(gpu.iter().any(|p| p.starts_with("nvidia-cudnn")));

        let cpu = packages_for(ModelEngine::FasterWhisper, ComputeDevice::Cpu);
        assert!(cpu.iter().any(|p| p == "faster-whisper"));
        assert!(!cpu.iter().any(|p| p.starts_with("nvidia-")));
    }

    #[test]
    fn onnx_runtime_cpu_and_gpu_builds_are_never_both_installed() {
        // Installing both distributions leaves onnxruntime importing the wrong
        // one, which fails at load with an opaque provider error.
        let gpu = packages_for(ModelEngine::ParakeetOnnx, ComputeDevice::Cuda);
        assert!(gpu.iter().any(|p| p == "onnxruntime-gpu"));
        assert!(!gpu.iter().any(|p| p == "onnxruntime"));

        let cpu = packages_for(ModelEngine::ParakeetOnnx, ComputeDevice::Cpu);
        assert!(cpu.iter().any(|p| p == "onnxruntime"));
        assert!(!cpu.iter().any(|p| p == "onnxruntime-gpu"));
    }

    #[test]
    fn whisper_cpp_needs_no_python_packages_at_all() {
        assert!(packages_for(ModelEngine::WhisperCpp, ComputeDevice::Auto).is_empty());
        assert!(packages_for(ModelEngine::WhisperCpp, ComputeDevice::Cpu).is_empty());
    }

    #[test]
    fn every_python_engine_pulls_in_the_download_and_array_libraries() {
        for engine in [ModelEngine::FasterWhisper, ModelEngine::ParakeetOnnx] {
            let packages = packages_for(engine, ComputeDevice::Auto);
            assert!(
                packages.iter().any(|p| p == "huggingface_hub"),
                "{engine:?}"
            );
            assert!(packages.iter().any(|p| p == "numpy"), "{engine:?}");
        }
    }

    #[test]
    fn progress_lines_are_parsed_and_clamped() {
        assert_eq!(parse_progress_line("PROGRESS 0.5000"), Some(0.5));
        assert_eq!(parse_progress_line("  PROGRESS 1.0  "), Some(1.0));
        // A rounding overshoot must not produce a bar past 100%.
        assert_eq!(parse_progress_line("PROGRESS 1.4"), Some(1.0));
        assert_eq!(parse_progress_line("PROGRESS -0.2"), Some(0.0));
    }

    #[test]
    fn non_progress_output_is_ignored() {
        assert_eq!(parse_progress_line("downloaded"), None);
        assert_eq!(parse_progress_line("Fetching 3 files: 100%"), None);
        assert_eq!(parse_progress_line("PROGRESS not-a-number"), None);
        assert_eq!(parse_progress_line("PROGRESS NaN"), None);
        assert_eq!(parse_progress_line(""), None);
    }

    #[test]
    fn an_unsupported_interpreter_explains_how_to_fix_it() {
        let base = BasePython::Unsupported {
            found: Some("3.14.7".to_string()),
        };
        let message = base.describe();
        assert!(message.contains("uv") || message.contains("python3.12"));
    }

    #[test]
    fn installing_the_runtime_for_whisper_cpp_is_refused() {
        let sink: ProgressSink = Box::new(|_| {});
        assert!(install(ModelEngine::WhisperCpp, ComputeDevice::Auto, &sink).is_err());
    }
}
