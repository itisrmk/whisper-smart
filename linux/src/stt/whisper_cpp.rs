//! whisper.cpp provider.
//!
//! This is the Linux answer to "the default provider must work without a
//! toolchain adventure". macOS defaults to Apple Speech because it ships with
//! the OS; here the nearest thing is a distro package (`whisper.cpp`) plus one
//! GGUF file — no Python, no pip, no CUDA wheel matching.
//!
//! Inference runs by invoking `whisper-cli` on a scratch WAV. That is a process
//! spawn per utterance rather than a resident model, so the first-token latency
//! is worse than the resident daemon used by the Python engines. It is the
//! deliberate trade: this provider optimises for *always working*, and the
//! daemon-backed providers optimise for speed.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use crate::core::model_catalog::{LocalModel, ModelSource};
use crate::core::paths;
use crate::core::settings::{ComputeDevice, Settings};
use crate::stt::wav::{self, ScratchWav};
use crate::stt::Transcriber;

pub struct WhisperCppTranscriber {
    binary: PathBuf,
    model_path: PathBuf,
    model_name: String,
    language: String,
    threads: usize,
    device: ComputeDevice,
}

impl WhisperCppTranscriber {
    /// Builds the transcriber, failing with a user-actionable message when the
    /// binary or the weights are missing.
    pub fn new(settings: &Settings) -> Result<Self, String> {
        let binary = crate::platform::diagnostics::whisper_cli_path().ok_or_else(|| {
            "whisper-cli was not found. Install it with: sudo pacman -S whisper-cpp".to_string()
        })?;

        let model = settings
            .selected_model()
            .ok_or_else(|| "No whisper.cpp model is selected.".to_string())?;
        let model_path = model_file_path(&model)
            .ok_or_else(|| format!("{} has no downloadable file.", model.display_name))?;

        if !model_path.is_file() {
            return Err(format!(
                "{} is not downloaded yet. Open Settings → Provider to download it.",
                model.display_name
            ));
        }

        Ok(Self {
            binary,
            model_path,
            model_name: model.display_name.to_string(),
            language: settings.provider.language.trim().to_string(),
            device: settings.provider.compute_device,
            // Leave headroom so a long transcription does not starve the
            // desktop; whisper.cpp scales poorly past physical cores anyway.
            threads: std::thread::available_parallelism()
                .map(|n| (n.get().saturating_sub(2)).clamp(1, 16))
                .unwrap_or(4),
        })
    }
}

/// The `whisper-cli` arguments for one utterance. Split out from the spawn so
/// the flag policy is testable without a multi-gigabyte model on disk.
fn cli_args(
    model_path: &Path,
    wav: &Path,
    threads: usize,
    language: &str,
    device: ComputeDevice,
) -> Vec<String> {
    let mut args = vec![
        "-m".to_string(),
        model_path.to_string_lossy().into_owned(),
        "-f".to_string(),
        wav.to_string_lossy().into_owned(),
        // -nt strips timestamps, -np suppresses the banner and progress, so
        // stdout carries the transcript and nothing else.
        "-nt".to_string(),
        "-np".to_string(),
        "-t".to_string(),
        threads.to_string(),
    ];

    // `compute_device` previously never reached whisper-cli, so a user who
    // picked "CPU only" still silently got GPU inference. Honour it now. Note
    // the memory direction is counter-intuitive on a CUDA build: keeping the
    // GPU costs far less host RAM than forcing CPU, because the CPU backend
    // repacks the weights.
    if device == ComputeDevice::Cpu {
        args.push("-ng".to_string());
    }

    args.push("-l".to_string());
    args.push(if language.is_empty() {
        "auto".to_string()
    } else {
        language.to_string()
    });

    args
}

/// Where a direct-download model's file lives.
pub fn model_file_path(model: &LocalModel) -> Option<PathBuf> {
    match model.source {
        ModelSource::DirectFile { file_name, .. } => Some(paths::models_dir().join(file_name)),
        ModelSource::HuggingFaceRepo { .. } => None,
    }
}

impl Transcriber for WhisperCppTranscriber {
    fn name(&self) -> String {
        format!("whisper.cpp · {}", self.model_name)
    }

    fn timeout(&self) -> Duration {
        // A process spawn plus a cold model load on CPU is slow; the state
        // machine's floor of 10s is not enough for the larger models.
        Duration::from_secs(120)
    }

    fn transcribe(&mut self, pcm: &[i16]) -> Result<String, String> {
        if pcm.is_empty() {
            return Ok(String::new());
        }

        let scratch_dir = paths::cache_dir();
        let scratch = ScratchWav::create(pcm, &scratch_dir, "whisper-cpp-session.wav")
            .map_err(|e| format!("Could not write the audio for transcription: {e}"))?;

        let mut command = Command::new(&self.binary);
        command.args(cli_args(
            &self.model_path,
            scratch.path(),
            self.threads,
            &self.language,
            self.device,
        ));

        tracing::debug!(
            "running whisper-cli on {:.1}s of audio",
            wav::duration(pcm).as_secs_f64()
        );

        let output = command
            .output()
            .map_err(|e| format!("Could not run whisper-cli: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("whisper-cli failed: {}", extract_error(&stderr)));
        }

        Ok(clean_output(&String::from_utf8_lossy(&output.stdout)))
    }
}

/// Picks the meaningful line out of whisper-cli's stderr.
///
/// A crash produces a lot of noise: a repeated backend-search warning, a
/// terminal-styling complaint, and a whole gdb backtrace. Taking the last line
/// lands on that noise and hides the one line that says what actually went
/// wrong, so known error markers are preferred and known noise is filtered out.
fn extract_error(stderr: &str) -> String {
    const MARKERS: &[&str] = &[
        "ggml_assert",
        "error:",
        "failed to",
        "unable to",
        "cannot ",
        "no such file",
        "out of memory",
        "invalid model",
    ];

    let is_noise = |line: &str| {
        let lower = line.to_ascii_lowercase();
        lower.contains("search path")
            || lower.contains("support styling")
            || lower.contains("debuginfod")
            || lower.contains("thread debugging")
            || lower.contains("libthread_db")
            || lower.starts_with('#') // gdb backtrace frames
            || lower.starts_with("0x") // gdb frame addresses
            || lower.starts_with("[inferior")
            || lower.starts_with("[thread")
    };

    let candidates: Vec<&str> = stderr
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !is_noise(line))
        .collect();

    // An explicit error marker beats position every time.
    if let Some(line) = candidates.iter().find(|line| {
        let lower = line.to_ascii_lowercase();
        MARKERS.iter().any(|marker| lower.contains(marker))
    }) {
        return (*line).to_string();
    }

    candidates
        .last()
        .map(|l| (*l).to_string())
        .unwrap_or_else(|| "no output".to_string())
}

/// Strips whisper.cpp's non-speech annotations and joins its segment lines.
///
/// Even with `-nt`, whisper.cpp emits bracketed markers such as `[BLANK_AUDIO]`
/// and `(wind blowing)` for non-speech. Injecting those into a document would
/// be worse than injecting nothing.
fn clean_output(stdout: &str) -> String {
    let mut parts: Vec<String> = Vec::new();

    for line in stdout.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        // A line that is entirely one annotation carries no speech.
        let is_annotation = (line.starts_with('[') && line.ends_with(']'))
            || (line.starts_with('(') && line.ends_with(')'))
            || (line.starts_with('*') && line.ends_with('*'));
        if is_annotation {
            continue;
        }
        parts.push(line.to_string());
    }

    parts.join(" ").trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::model_catalog;

    fn args_for(device: ComputeDevice, language: &str) -> Vec<String> {
        cli_args(
            Path::new("/models/ggml-base.bin"),
            Path::new("/tmp/session.wav"),
            4,
            language,
            device,
        )
    }

    #[test]
    fn cpu_only_passes_no_gpu_so_the_setting_is_not_silently_ignored() {
        assert!(args_for(ComputeDevice::Cpu, "").contains(&"-ng".to_string()));
    }

    #[test]
    fn auto_and_cuda_leave_the_gpu_enabled() {
        // On a CUDA build the GPU path also uses dramatically less host RAM,
        // so defaulting away from it would cost memory as well as speed.
        assert!(!args_for(ComputeDevice::Auto, "").contains(&"-ng".to_string()));
        assert!(!args_for(ComputeDevice::Cuda, "").contains(&"-ng".to_string()));
    }

    #[test]
    fn an_empty_language_asks_whisper_to_autodetect() {
        let args = args_for(ComputeDevice::Auto, "");
        let idx = args.iter().position(|a| a == "-l").expect("-l is passed");
        assert_eq!(args[idx + 1], "auto");
    }

    #[test]
    fn an_explicit_language_is_forwarded_verbatim() {
        let args = args_for(ComputeDevice::Auto, "de");
        let idx = args.iter().position(|a| a == "-l").expect("-l is passed");
        assert_eq!(args[idx + 1], "de");
    }

    #[test]
    fn segment_lines_are_joined_into_one_transcript() {
        let stdout = " Hello there.\n This is a test.\n";
        assert_eq!(clean_output(stdout), "Hello there. This is a test.");
    }

    #[test]
    fn non_speech_annotations_are_stripped() {
        assert_eq!(clean_output("[BLANK_AUDIO]\n"), "");
        assert_eq!(clean_output("(wind blowing)\nHello\n"), "Hello");
        assert_eq!(clean_output("*laughs*\nOkay\n"), "Okay");
    }

    #[test]
    fn a_silent_recording_produces_an_empty_transcript_not_a_marker() {
        // Injecting "[BLANK_AUDIO]" into the user's document would be worse
        // than injecting nothing at all.
        assert_eq!(clean_output("\n[BLANK_AUDIO]\n\n"), "");
    }

    #[test]
    fn brackets_inside_real_speech_are_preserved() {
        assert_eq!(
            clean_output("The array is [1, 2, 3] in total.\n"),
            "The array is [1, 2, 3] in total."
        );
    }

    #[test]
    fn empty_output_is_handled() {
        assert_eq!(clean_output(""), "");
        assert_eq!(clean_output("   \n  \n"), "");
    }

    #[test]
    fn direct_download_models_resolve_to_a_file_and_hf_models_do_not() {
        let cpp = model_file_path(&model_catalog::CPP_BASE).expect("gguf models have a path");
        assert!(cpp.ends_with("ggml-base.bin"));
        assert_eq!(model_file_path(&model_catalog::PARAKEET_V3), None);
    }

    #[test]
    fn the_real_error_is_preferred_over_surrounding_noise() {
        // Exactly what a backend-less ggml produces: the assert is buried
        // between a repeated warning and a gdb backtrace.
        let stderr = concat!(
            "ggml_backend_load_best: search path /usr/lib/ggml does not exist\n",
            "ggml_backend_load_best: search path /usr/lib/ggml does not exist\n",
            "/usr/src/debug/ggml/ggml/src/ggml-backend.cpp:595: GGML_ASSERT(device) failed\n",
            "warning: The current terminal doesn't support styling.\n",
            "[Thread debugging using libthread_db enabled]\n",
            "#0  0x00007fce3530553d in wait4 () from /usr/lib/libc.so.6\n",
            "[Inferior 1 (process 288740) detached]\n",
        );
        let extracted = extract_error(stderr);
        assert!(
            extracted.contains("GGML_ASSERT(device) failed"),
            "got: {extracted}"
        );
    }

    #[test]
    fn a_missing_model_file_is_reported_clearly() {
        let stderr = "whisper_init_from_file_with_params_no_state: failed to open '/nope.bin'";
        assert!(extract_error(stderr).contains("failed to open"));
    }

    #[test]
    fn with_no_markers_the_last_real_line_is_used() {
        let stderr = concat!(
            "ggml_backend_load_best: search path /usr/lib/ggml does not exist\n",
            "something unexpected happened\n",
        );
        assert_eq!(extract_error(stderr), "something unexpected happened");
    }

    #[test]
    fn entirely_empty_output_still_produces_a_message() {
        assert_eq!(extract_error(""), "no output");
        assert_eq!(extract_error("   \n \n"), "no output");
    }

    #[test]
    fn pure_noise_does_not_masquerade_as_an_error() {
        let stderr = concat!(
            "ggml_backend_load_best: search path /usr/lib/ggml does not exist\n",
            "[Thread debugging using libthread_db enabled]\n",
        );
        assert_eq!(extract_error(stderr), "no output");
    }
}
