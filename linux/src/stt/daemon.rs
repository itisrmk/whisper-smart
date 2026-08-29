//! Resident Python sidecar client.
//!
//! Drives `python/stt_daemon.py` for the faster-whisper and Parakeet engines.
//! The design mirrors `MLXSTTProvider.swift`: keep the model loaded in a
//! long-lived process and send utterances over stdio, so the multi-second model
//! load is paid once at startup instead of on every dictation.
//!
//! The daemon is restarted transparently if it dies (an OOM kill, a CUDA fault,
//! the user reinstalling the runtime underneath it), because a dictation app
//! that needs to be restarted after one bad utterance is not usable.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

use base64::Engine as _;

use crate::core::model_catalog::{LocalModel, ModelEngine};
use crate::core::settings::{ComputeDevice, Settings};
use crate::stt::runtime;
use crate::stt::Transcriber;

/// How long to wait for the daemon to report `ready` after spawning.
/// A cold large model on CPU can genuinely take this long to load.
const READY_TIMEOUT: Duration = Duration::from_secs(180);

/// How long to wait for one utterance's response.
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(180);

/// Everything needed to launch the sidecar, resolved up front.
///
/// Keeping this separate from [`DaemonTranscriber`] splits "work out what to
/// run" from "run it and speak the protocol", which lets the protocol client be
/// exercised against a stand-in sidecar rather than a multi-gigabyte model.
#[derive(Debug, Clone)]
pub struct DaemonCommand {
    /// Interpreter to launch, normally the managed virtualenv's python.
    pub interpreter: PathBuf,
    /// Path to `stt_daemon.py`.
    pub script: PathBuf,
    /// `--engine` argument.
    pub engine_arg: String,
    /// `--model` argument: a local snapshot directory once downloaded.
    pub model_id: String,
    pub device: ComputeDevice,
    pub language: String,
}

pub struct DaemonTranscriber {
    engine: ModelEngine,
    command: DaemonCommand,
    model_name: String,
    process: Option<DaemonProcess>,
    next_request_id: u64,
}

struct DaemonProcess {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl DaemonTranscriber {
    pub fn new(settings: &Settings) -> Result<Self, String> {
        let model = settings
            .selected_model()
            .ok_or_else(|| "No local model is selected.".to_string())?;
        let engine = model.engine;
        let engine_arg = engine_argument(engine)?;

        if !runtime::is_installed() {
            return Err(
                "The local inference runtime is not installed. Open Settings → Provider to install it."
                    .to_string(),
            );
        }
        let model_id = resolve_model_argument(&model)?;
        let script = runtime::daemon_script_path().ok_or_else(|| {
            "The STT sidecar script is missing from the installation.".to_string()
        })?;

        Ok(Self::with_command(
            engine,
            model.display_name.to_string(),
            DaemonCommand {
                interpreter: runtime::interpreter_path(),
                script,
                engine_arg: engine_arg.to_string(),
                model_id,
                device: settings.provider.compute_device,
                language: settings.provider.language.trim().to_string(),
            },
        ))
    }

    /// Builds a transcriber around an already-resolved launch command.
    pub fn with_command(engine: ModelEngine, model_name: String, command: DaemonCommand) -> Self {
        Self {
            engine,
            command,
            model_name,
            process: None,
            next_request_id: 1,
        }
    }

    fn ensure_running(&mut self) -> Result<(), String> {
        if let Some(process) = self.process.as_mut() {
            // try_wait returning Some means the daemon exited behind our back.
            match process.child.try_wait() {
                Ok(None) => return Ok(()),
                Ok(Some(status)) => {
                    tracing::warn!("STT daemon exited with {status}; restarting");
                    self.process = None;
                }
                Err(err) => {
                    tracing::warn!("could not poll the STT daemon ({err}); restarting");
                    self.process = None;
                }
            }
        }
        self.spawn()
    }

    fn spawn(&mut self) -> Result<(), String> {
        let script = &self.command.script;

        let device_arg = match self.command.device {
            ComputeDevice::Auto => "auto",
            ComputeDevice::Cuda => "cuda",
            ComputeDevice::Cpu => "cpu",
        };

        tracing::info!(
            "starting STT daemon: engine={} model={} device={device_arg}",
            self.command.engine_arg,
            self.command.model_id
        );

        let mut command = Command::new(&self.command.interpreter);
        command
            // -u keeps stdout unbuffered so responses arrive as they are written
            // rather than sitting in a 4 KB pipe buffer.
            .arg("-u")
            .arg(script)
            .arg("--serve")
            .args(["--engine", self.command.engine_arg.as_str()])
            .args(["--model", self.command.model_id.as_str()])
            .args(["--device", device_arg])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        if !self.command.language.is_empty() {
            command.args(["--language", self.command.language.as_str()]);
        }
        runtime::apply_environment(&mut command);

        let mut child = command
            .spawn()
            .map_err(|e| format!("Could not start the local inference runtime: {e}"))?;

        let stdin = child.stdin.take().ok_or("The sidecar has no stdin.")?;
        let stdout = child.stdout.take().ok_or("The sidecar has no stdout.")?;
        // Drain stderr on its own thread; a full stderr pipe would otherwise
        // block the daemon mid-inference.
        if let Some(stderr) = child.stderr.take() {
            let label = self.model_name.clone();
            std::thread::Builder::new()
                .name("stt-daemon-log".to_string())
                .spawn(move || {
                    for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                        tracing::debug!("[{label}] {line}");
                    }
                })
                .ok();
        }

        let mut process = DaemonProcess {
            child,
            stdin,
            stdout: BufReader::new(stdout),
        };
        wait_for_ready(&mut process).inspect_err(|_| {
            let _ = process.child.kill();
        })?;

        self.process = Some(process);
        Ok(())
    }

    fn shutdown_process(&mut self) {
        if let Some(mut process) = self.process.take() {
            // Closing stdin is the documented way to ask the daemon to exit.
            drop(process.stdin);
            let _ = process.child.wait();
        }
    }
}

fn engine_argument(engine: ModelEngine) -> Result<&'static str, String> {
    match engine {
        ModelEngine::FasterWhisper => Ok("faster-whisper"),
        ModelEngine::ParakeetOnnx => Ok("parakeet"),
        ModelEngine::WhisperCpp => {
            Err("whisper.cpp does not run in the Python sidecar.".to_string())
        }
    }
}

/// The `--model` argument: a local snapshot directory when the weights have
/// been downloaded, so the daemon never reaches for the network mid-dictation.
fn resolve_model_argument(model: &LocalModel) -> Result<String, String> {
    let repo = model
        .repo()
        .ok_or_else(|| format!("{} is not a Hugging Face model.", model.display_name))?;

    match crate::platform::diagnostics::hf_snapshot_dir(repo) {
        Some(dir) => Ok(dir.to_string_lossy().to_string()),
        None => Err(format!(
            "{} is not downloaded yet. Open Settings → Provider to download it.",
            model.display_name
        )),
    }
}

/// Reads protocol lines until `ready`, a load error, or the timeout.
fn wait_for_ready(process: &mut DaemonProcess) -> Result<(), String> {
    let deadline = Instant::now() + READY_TIMEOUT;

    loop {
        if Instant::now() > deadline {
            return Err("The local inference runtime did not finish loading in time.".to_string());
        }

        let mut line = String::new();
        match process.stdout.read_line(&mut line) {
            Ok(0) => {
                return Err(
                    "The local inference runtime exited before it finished loading.".to_string(),
                )
            }
            Ok(_) => {}
            Err(err) => return Err(format!("Lost contact with the inference runtime: {err}")),
        }

        let Ok(value) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
            continue; // not a protocol line
        };

        match value.get("event").and_then(|e| e.as_str()) {
            Some("ready") => {
                if let Some(device) = value.get("device").and_then(|d| d.as_str()) {
                    tracing::info!("STT daemon ready on {device}");
                }
                return Ok(());
            }
            Some("error") => {
                let message = value
                    .get("error")
                    .and_then(|e| e.as_str())
                    .unwrap_or("the model could not be loaded");
                return Err(format!("Local inference failed to start: {message}"));
            }
            _ => {}
        }
    }
}

impl Transcriber for DaemonTranscriber {
    fn name(&self) -> String {
        let engine = match self.engine {
            ModelEngine::FasterWhisper => "faster-whisper",
            ModelEngine::ParakeetOnnx => "Parakeet",
            ModelEngine::WhisperCpp => "whisper.cpp",
        };
        format!("{engine} · {}", self.model_name)
    }

    fn timeout(&self) -> Duration {
        // Generous: this covers a cold daemon restart plus inference.
        Duration::from_secs(90)
    }

    fn prewarm(&mut self) {
        if let Err(err) = self.ensure_running() {
            // Not fatal here: the first transcribe retries and surfaces the
            // error where the user can actually see it.
            tracing::warn!("STT daemon prewarm failed: {err}");
        }
    }

    fn transcribe(&mut self, pcm: &[i16]) -> Result<String, String> {
        if pcm.is_empty() {
            return Ok(String::new());
        }

        // One retry: if the daemon died since the last utterance, restarting
        // and trying again is invisible to the user.
        let mut last_error = None;
        for attempt in 0..2 {
            if attempt > 0 {
                tracing::info!("retrying transcription after restarting the daemon");
                self.shutdown_process();
            }
            match self.transcribe_once(pcm) {
                Ok(text) => return Ok(text),
                Err(TranscribeFailure::Fatal(message)) => return Err(message),
                Err(TranscribeFailure::Retryable(message)) => last_error = Some(message),
            }
        }
        Err(last_error.unwrap_or_else(|| "Local transcription failed.".to_string()))
    }

    fn shutdown(&mut self) {
        self.shutdown_process();
    }
}

/// Distinguishes "the daemon broke, try again" from "this request is bad".
enum TranscribeFailure {
    Retryable(String),
    Fatal(String),
}

impl DaemonTranscriber {
    fn transcribe_once(&mut self, pcm: &[i16]) -> Result<String, TranscribeFailure> {
        self.ensure_running()
            .map_err(TranscribeFailure::Retryable)?;

        let request_id = self.next_request_id;
        self.next_request_id += 1;

        let encoded = encode_pcm(pcm);
        let request = serde_json::json!({ "id": request_id, "pcm": encoded });

        let process = self
            .process
            .as_mut()
            .expect("ensure_running installed a process");

        writeln!(process.stdin, "{request}")
            .and_then(|()| process.stdin.flush())
            .map_err(|e| {
                TranscribeFailure::Retryable(format!("Lost contact with the runtime: {e}"))
            })?;

        let deadline = Instant::now() + RESPONSE_TIMEOUT;
        loop {
            if Instant::now() > deadline {
                return Err(TranscribeFailure::Retryable(
                    "Local transcription did not return in time.".to_string(),
                ));
            }

            let mut line = String::new();
            match process.stdout.read_line(&mut line) {
                Ok(0) => {
                    return Err(TranscribeFailure::Retryable(
                        "The local inference runtime stopped unexpectedly.".to_string(),
                    ))
                }
                Ok(_) => {}
                Err(err) => {
                    return Err(TranscribeFailure::Retryable(format!(
                        "Lost contact with the runtime: {err}"
                    )))
                }
            }

            let Ok(value) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
                continue;
            };

            // Ignore anything not answering this request, so a late response
            // from a previous utterance cannot be mistaken for this one's.
            let id = value.get("id").and_then(serde_json::Value::as_u64);
            if id != Some(request_id) {
                continue;
            }

            if let Some(error) = value.get("error").and_then(|e| e.as_str()) {
                // The model is loaded and answered; the request itself failed.
                return Err(TranscribeFailure::Fatal(format!(
                    "Local transcription failed: {error}"
                )));
            }
            if let Some(text) = value.get("text").and_then(|t| t.as_str()) {
                return Ok(text.trim().to_string());
            }
        }
    }
}

impl Drop for DaemonTranscriber {
    fn drop(&mut self) {
        self.shutdown_process();
    }
}

/// Encodes PCM as base64 int16 little-endian, matching `decode_pcm` in the
/// sidecar. Base64 over stdio avoids a temp file per utterance.
fn encode_pcm(pcm: &[i16]) -> String {
    let mut bytes = Vec::with_capacity(pcm.len() * 2);
    for sample in pcm {
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::model_catalog;

    #[test]
    fn engines_map_to_the_sidecars_argument_names() {
        assert_eq!(
            engine_argument(ModelEngine::FasterWhisper).unwrap(),
            "faster-whisper"
        );
        assert_eq!(
            engine_argument(ModelEngine::ParakeetOnnx).unwrap(),
            "parakeet"
        );
        // whisper.cpp has its own provider and must never reach the sidecar.
        assert!(engine_argument(ModelEngine::WhisperCpp).is_err());
    }

    #[test]
    fn pcm_encodes_as_little_endian_int16_base64() {
        // 1 -> 0x01 0x00, -2 -> 0xFE 0xFF
        let encoded = encode_pcm(&[1, -2]);
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .unwrap();
        assert_eq!(decoded, vec![0x01, 0x00, 0xFE, 0xFF]);
    }

    #[test]
    fn an_empty_buffer_encodes_to_an_empty_payload() {
        assert_eq!(encode_pcm(&[]), "");
    }

    #[test]
    fn full_scale_samples_survive_encoding() {
        let encoded = encode_pcm(&[i16::MIN, i16::MAX]);
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .unwrap();
        assert_eq!(decoded, vec![0x00, 0x80, 0xFF, 0x7F]);
    }

    #[test]
    fn a_model_that_is_not_downloaded_reports_where_to_download_it() {
        // PARAKEET_V3 will not be present in a test environment's cache.
        let err = resolve_model_argument(&model_catalog::PARAKEET_V3).unwrap_err();
        assert!(
            err.contains("Settings"),
            "the error should tell the user what to do: {err}"
        );
    }

    #[test]
    fn a_gguf_model_is_rejected_by_the_sidecar_path() {
        let err = resolve_model_argument(&model_catalog::CPP_BASE).unwrap_err();
        assert!(err.contains("Hugging Face"));
    }
}
