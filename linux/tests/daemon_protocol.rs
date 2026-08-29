//! Exercises the STT sidecar protocol end to end.
//!
//! The real sidecar needs a multi-gigabyte model and a Python with ML wheels,
//! neither of which belongs in a test run. What *is* worth testing is the part
//! most likely to break: the client's half of the protocol — the `ready`
//! handshake, request/response correlation by id, error propagation, and
//! recovery when the daemon dies mid-session.
//!
//! So these run the real `DaemonTranscriber` against stand-in sidecars written
//! in stdlib-only Python that speak the same JSONL protocol as
//! `python/stt_daemon.py`.

use std::path::{Path, PathBuf};
use std::time::Duration;

use whisper_smart::core::model_catalog::ModelEngine;
use whisper_smart::core::settings::ComputeDevice;
use whisper_smart::stt::daemon::{DaemonCommand, DaemonTranscriber};
use whisper_smart::stt::Transcriber;

/// Writes a stand-in sidecar and returns its path.
fn write_sidecar(name: &str, body: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("ws-daemon-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let path = dir.join(format!("{name}.py"));
    std::fs::write(&path, body).expect("write sidecar");
    path
}

fn transcriber(script: &Path) -> DaemonTranscriber {
    DaemonTranscriber::with_command(
        ModelEngine::FasterWhisper,
        "Stand-in".to_string(),
        DaemonCommand {
            interpreter: PathBuf::from("python3"),
            script: script.to_path_buf(),
            engine_arg: "faster-whisper".to_string(),
            model_id: "stand-in".to_string(),
            device: ComputeDevice::Cpu,
            language: String::new(),
        },
    )
}

/// The happy path: announce ready, then echo a fixed transcript per request.
const ECHOING_SIDECAR: &str = r#"
import json, sys
print(json.dumps({"event": "ready", "device": "cpu"}), flush=True)
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    request = json.loads(line)
    # Prove the audio actually arrived by reporting its size.
    payload = request.get("pcm") or ""
    print(json.dumps({"id": request["id"], "text": f"heard {len(payload)} bytes"}), flush=True)
"#;

#[test]
fn a_ready_daemon_answers_a_transcription_request() {
    let script = write_sidecar("echoing", ECHOING_SIDECAR);
    let mut transcriber = transcriber(&script);

    let text = transcriber.transcribe(&[1i16; 160]).expect("a transcript");
    assert!(text.starts_with("heard "), "unexpected transcript: {text}");
    assert!(
        !text.contains("heard 0 "),
        "the audio payload did not reach the sidecar"
    );
}

#[test]
fn the_model_stays_loaded_across_utterances() {
    // The whole reason for a resident daemon: the second utterance must not
    // pay for another startup.
    let script = write_sidecar("echoing", ECHOING_SIDECAR);
    let mut transcriber = transcriber(&script);

    assert!(transcriber.transcribe(&[1i16; 160]).is_ok());
    let started = std::time::Instant::now();
    assert!(transcriber.transcribe(&[1i16; 160]).is_ok());
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "the second utterance appears to have restarted the daemon"
    );
}

#[test]
fn an_empty_utterance_never_reaches_the_daemon() {
    let script = write_sidecar("echoing", ECHOING_SIDECAR);
    let mut transcriber = transcriber(&script);
    assert_eq!(transcriber.transcribe(&[]).unwrap(), "");
}

/// Reports a load failure instead of becoming ready.
const FAILING_LOAD_SIDECAR: &str = r#"
import json, sys
print(json.dumps({"event": "error", "error": "CUDA driver version is insufficient"}), flush=True)
sys.exit(1)
"#;

#[test]
fn a_model_that_fails_to_load_surfaces_its_reason() {
    let script = write_sidecar("failing_load", FAILING_LOAD_SIDECAR);
    let mut transcriber = transcriber(&script);

    let err = transcriber.transcribe(&[1i16; 160]).unwrap_err();
    assert!(
        err.contains("CUDA driver version is insufficient"),
        "the load failure should reach the user verbatim: {err}"
    );
}

/// Becomes ready, then reports a per-request error.
const REQUEST_ERROR_SIDECAR: &str = r#"
import json, sys
print(json.dumps({"event": "ready", "device": "cpu"}), flush=True)
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    request = json.loads(line)
    print(json.dumps({"id": request["id"], "error": "RuntimeError: bad audio"}), flush=True)
"#;

#[test]
fn a_request_level_error_is_reported_without_restarting_the_daemon() {
    let script = write_sidecar("request_error", REQUEST_ERROR_SIDECAR);
    let mut transcriber = transcriber(&script);

    let err = transcriber.transcribe(&[1i16; 160]).unwrap_err();
    assert!(err.contains("bad audio"), "unexpected error: {err}");
    // A second attempt must reach the same still-running daemon and fail the
    // same way, rather than the client having torn it down.
    assert!(transcriber
        .transcribe(&[1i16; 160])
        .unwrap_err()
        .contains("bad audio"));
}

/// Exits after answering once, so the next request finds a dead daemon.
const DIES_AFTER_ONE_SIDECAR: &str = r#"
import json, sys
print(json.dumps({"event": "ready", "device": "cpu"}), flush=True)
line = sys.stdin.readline()
request = json.loads(line)
print(json.dumps({"id": request["id"], "text": "first"}), flush=True)
sys.exit(0)
"#;

#[test]
fn a_daemon_that_dies_is_restarted_transparently() {
    // A dictation app that needs restarting after one crash is not usable.
    let script = write_sidecar("dies_after_one", DIES_AFTER_ONE_SIDECAR);
    let mut transcriber = transcriber(&script);

    assert_eq!(transcriber.transcribe(&[1i16; 160]).unwrap(), "first");
    // The daemon has now exited. The next utterance must still succeed.
    assert_eq!(transcriber.transcribe(&[1i16; 160]).unwrap(), "first");
}

/// Emits noise on stdout and a stale response before the real one, to check the
/// client correlates by id rather than taking the first line it sees.
const NOISY_SIDECAR: &str = r#"
import json, sys
print("loading model...", flush=True)
print(json.dumps({"event": "ready", "device": "cpu"}), flush=True)
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    request = json.loads(line)
    print("not json at all", flush=True)
    # A late answer to an utterance the user already abandoned.
    print(json.dumps({"id": 9999, "text": "STALE"}), flush=True)
    print(json.dumps({"event": "progress"}), flush=True)
    print(json.dumps({"id": request["id"], "text": "correct"}), flush=True)
"#;

#[test]
fn responses_are_matched_by_id_and_noise_is_ignored() {
    let script = write_sidecar("noisy", NOISY_SIDECAR);
    let mut transcriber = transcriber(&script);

    let text = transcriber.transcribe(&[1i16; 160]).unwrap();
    assert_eq!(
        text, "correct",
        "a stale or unrelated line was mistaken for the answer"
    );
}

#[test]
fn a_missing_interpreter_fails_with_a_message_rather_than_hanging() {
    let script = write_sidecar("echoing", ECHOING_SIDECAR);
    let mut transcriber = DaemonTranscriber::with_command(
        ModelEngine::FasterWhisper,
        "Stand-in".to_string(),
        DaemonCommand {
            interpreter: PathBuf::from("/nonexistent/python"),
            script,
            engine_arg: "faster-whisper".to_string(),
            model_id: "stand-in".to_string(),
            device: ComputeDevice::Cpu,
            language: String::new(),
        },
    );

    let err = transcriber.transcribe(&[1i16; 160]).unwrap_err();
    assert!(!err.is_empty());
}

#[test]
fn the_transcriber_names_its_engine_and_model() {
    let script = write_sidecar("echoing", ECHOING_SIDECAR);
    let transcriber = transcriber(&script);
    let name = transcriber.name();
    assert!(name.contains("faster-whisper"), "unexpected name: {name}");
    assert!(name.contains("Stand-in"), "unexpected name: {name}");
}
