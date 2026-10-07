//! whisper.cpp provider.
//!
//! This is the Windows answer to "the default provider must work without a
//! toolchain adventure". macOS defaults to Apple Speech because it ships with
//! the OS; Linux leans on a distro package. Windows has neither, so the app
//! installs the official prebuilt `whisper-cli.exe` from the whisper.cpp
//! releases on request (see [`crate::stt::runtime::install_whisper_cpp`]) —
//! still no Python, no pip, no CUDA wheel matching.
//!
//! Inference runs by invoking `whisper-cli` on a scratch WAV. That is a
//! process spawn per utterance rather than a resident model, so the
//! first-token latency is worse than the resident daemon used by the Python
//! engines. It is the deliberate trade: this provider optimises for *always
//! working*, and the daemon-backed providers optimise for speed.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

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
    /// Large models get a longer leash on CPU.
    large_model: bool,
}

impl WhisperCppTranscriber {
    /// Builds the transcriber, failing with a user-actionable message when the
    /// binary or the weights are missing.
    pub fn new(settings: &Settings) -> Result<Self, String> {
        let binary = crate::platform::diagnostics::whisper_cli_path().ok_or_else(|| {
            "whisper-cli.exe was not found. Open Settings → Provider and press \
             \"Install whisper.cpp\"."
                .to_string()
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
            large_model: model.prefers_gpu,
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

    // The managed binary is the CPU build, where -ng is a no-op; a user who
    // installed their own CUDA build gets the setting honoured.
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

pub(crate) enum RunFailure {
    Spawn(std::io::Error),
    TimedOut,
}

/// NT status codes a process exits with when it could not even start.
/// The official whisper.cpp binaries link the MSVC runtime dynamically, so a
/// machine without the VC++ Redistributable dies with one of these.
const STARTUP_FAILURE_CODES: [i32; 3] = [
    0xC0000135u32 as i32, // STATUS_DLL_NOT_FOUND
    0xC0000139u32 as i32, // STATUS_ENTRYPOINT_NOT_FOUND
    0xC0000142u32 as i32, // STATUS_DLL_INIT_FAILED
];

/// Translates an exit status into a remedy when the process never really ran.
fn startup_failure(status: &std::process::ExitStatus) -> Option<String> {
    let code = status.code()?;
    STARTUP_FAILURE_CODES.contains(&code).then(|| {
        format!(
            "whisper-cli.exe cannot start on this machine (exit code {code:#X}): a required \
             system library is missing. Install the Microsoft Visual C++ Redistributable \
             (x64) from https://aka.ms/vs/17/release/vc_redist.x64.exe and try again."
        )
    })
}

/// Verifies the binary can actually start — DLLs resolved, process runs.
/// `-h` prints usage and exits; any exit at all proves the loader is happy.
pub(crate) fn probe_binary(binary: &Path) -> Result<(), String> {
    let mut command = Command::new(binary);
    command.arg("-h");
    crate::platform::hide_console(&mut command);
    match run_with_deadline(command, Duration::from_secs(20)) {
        Ok(output) => match startup_failure(&output.status) {
            Some(message) => Err(message),
            None => Ok(()),
        },
        Err(RunFailure::Spawn(e)) => Err(format!("whisper-cli.exe could not be started: {e}")),
        Err(RunFailure::TimedOut) => Err(
            "whisper-cli.exe did not respond. Antivirus software may be blocking it; check \
             your security software's quarantine and allow the file."
                .to_string(),
        ),
    }
}

/// Runs a command to completion with an upper bound, killing it when the
/// bound is hit. Both pipes are drained on their own threads so a chatty
/// child can never deadlock against a full pipe while we poll.
pub(crate) fn run_with_deadline(
    mut command: Command,
    deadline: Duration,
) -> Result<std::process::Output, RunFailure> {
    use std::io::Read;

    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().map_err(RunFailure::Spawn)?;

    let mut stdout_pipe = child.stdout.take().expect("stdout was piped");
    let mut stderr_pipe = child.stderr.take().expect("stderr was piped");
    let stdout_reader = std::thread::spawn(move || {
        let mut buffer = Vec::new();
        let _ = stdout_pipe.read_to_end(&mut buffer);
        buffer
    });
    let stderr_reader = std::thread::spawn(move || {
        let mut buffer = Vec::new();
        let _ = stderr_pipe.read_to_end(&mut buffer);
        buffer
    });

    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {
                if started.elapsed() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(RunFailure::TimedOut);
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(err) => {
                let _ = child.kill();
                return Err(RunFailure::Spawn(err));
            }
        }
    };

    Ok(std::process::Output {
        status,
        stdout: stdout_reader.join().unwrap_or_default(),
        stderr: stderr_reader.join().unwrap_or_default(),
    })
}

impl Transcriber for WhisperCppTranscriber {
    fn name(&self) -> String {
        format!("whisper.cpp · {}", self.model_name)
    }

    fn timeout(&self) -> Duration {
        // A process spawn plus a cold model load on CPU is slow; the state
        // machine's floor of 10s is not enough for real models, and the
        // large ones can legitimately need minutes per utterance on CPU.
        if self.large_model {
            Duration::from_secs(300)
        } else {
            Duration::from_secs(120)
        }
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
        crate::platform::hide_console(&mut command);

        tracing::info!(
            "whisper-cli start: {:.1}s of audio, model {}, {} threads",
            wav::duration(pcm).as_secs_f64(),
            self.model_name,
            self.threads,
        );

        // Killed a little before the state machine's own timeout: a hung
        // whisper-cli would otherwise outlive the session and block the
        // worker thread, leaving every following dictation queued behind it —
        // the app looks dead until the zombie exits.
        let deadline = self.timeout().saturating_sub(Duration::from_secs(10));
        let started = Instant::now();
        let output = run_with_deadline(command, deadline).map_err(|err| match err {
            RunFailure::Spawn(e) => format!("Could not run whisper-cli: {e}"),
            RunFailure::TimedOut => {
                tracing::error!(
                    "whisper-cli killed after {:.0}s (model {})",
                    deadline.as_secs_f64(),
                    self.model_name
                );
                format!(
                    "{} took longer than {:.0} minutes on this machine. Pick a smaller \
                     model (Balanced) in Settings → Provider.",
                    self.model_name,
                    deadline.as_secs_f64() / 60.0
                )
            }
        })?;

        tracing::info!(
            "whisper-cli finished in {:.1}s ({})",
            started.elapsed().as_secs_f64(),
            output.status,
        );

        if !output.status.success() {
            if let Some(message) = startup_failure(&output.status) {
                return Err(message);
            }
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("whisper-cli failed: {}", extract_error(&stderr)));
        }

        Ok(clean_output(&String::from_utf8_lossy(&output.stdout)))
    }
}

/// Picks the meaningful line out of whisper-cli's stderr.
///
/// A crash produces a lot of noise: repeated backend-search warnings and a
/// terminal-styling complaint. Taking the last line lands on that noise and
/// hides the one line that says what actually went wrong, so known error
/// markers are preferred and known noise is filtered out.
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
            || lower.starts_with('#')
            || lower.starts_with("0x")
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
            Path::new(r"C:\models\ggml-base.bin"),
            Path::new(r"C:\tmp\session.wav"),
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
    fn a_missing_model_file_is_reported_clearly() {
        let stderr = "whisper_init_from_file_with_params_no_state: failed to open 'C:\\nope.bin'";
        assert!(extract_error(stderr).contains("failed to open"));
    }

    #[test]
    fn with_no_markers_the_last_real_line_is_used() {
        let stderr = concat!(
            "ggml_backend_load_best: search path C:\\ggml does not exist\n",
            "something unexpected happened\n",
        );
        assert_eq!(extract_error(stderr), "something unexpected happened");
    }

    #[test]
    fn entirely_empty_output_still_produces_a_message() {
        assert_eq!(extract_error(""), "no output");
        assert_eq!(extract_error("   \n \n"), "no output");
    }
}
