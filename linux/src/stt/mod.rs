//! Speech-to-text providers.
//!
//! The macOS build's `STTProvider` protocol is streaming-shaped: buffers are
//! pushed in as they arrive and results come back through callbacks. That shape
//! is preserved here, with one structural difference forced by Rust's threading
//! model — instead of each provider owning a session and calling back into the
//! state machine, every provider is a [`WorkerProvider`] wrapping a
//! [`Transcriber`] that runs on its own thread and posts
//! [`Event`](crate::core::state_machine::Event)s into the same channel the
//! hotkey and audio layers use.
//!
//! The upshot is that a slow model can never block the UI, and a result that
//! arrives after the user switched providers is dropped by the generation tag
//! rather than needing a live back-reference.

pub mod daemon;
pub mod openai;
pub mod runtime;
pub mod wav;
pub mod whisper_cpp;

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crossbeam_channel::{Receiver, Sender};

use crate::core::state_machine::{Event, SttControl};
use crate::platform::audio::PcmSink;

/// Maximum audio a single utterance may hold, as 16 kHz mono samples.
/// Ten minutes is far beyond any dictation, and the cap stops a stuck
/// hands-free session from growing until the machine swaps.
const MAX_SESSION_SAMPLES: usize = 16_000 * 60 * 10;

/// Anything that can turn one utterance's PCM into text.
///
/// Implementations run on a worker thread and may block for as long as
/// inference takes.
pub trait Transcriber: Send {
    /// Name shown in the UI and in errors.
    fn name(&self) -> String;

    /// How long the state machine should wait after the session ends.
    fn timeout(&self) -> Duration {
        Duration::from_secs(30)
    }

    /// Transcribes 16 kHz mono PCM. An empty result is valid (silence).
    fn transcribe(&mut self, pcm: &[i16]) -> Result<String, String>;

    /// Optional: load the model before the first utterance, so the first
    /// dictation is not several seconds slower than the rest.
    fn prewarm(&mut self) {}

    /// Optional: release resources when the provider is swapped out.
    fn shutdown(&mut self) {}
}

/// Control messages sent from the state machine's thread to the worker.
enum Control {
    Begin,
    End,
    Cancel,
    Shutdown,
}

/// Wraps a [`Transcriber`] as an [`SttControl`] the state machine can drive.
pub struct WorkerProvider {
    name: String,
    timeout: Duration,
    control: Sender<Control>,
    pcm_sink: PcmSink,
    /// Our own end of the audio channel, kept so `Drop` can tell whether the
    /// sink still belongs to us before detaching it.
    pcm_tx: Sender<Vec<i16>>,
    /// Bumped on cancel so a result computed for an abandoned session is
    /// discarded instead of being injected into whatever the user is doing now.
    session: Arc<AtomicU64>,
    /// True between begin_session and end/cancel, so a double begin is refused
    /// the same way the macOS providers refuse one.
    active: bool,
}

impl WorkerProvider {
    /// Spawns the worker thread and installs this provider's audio sink.
    ///
    /// `generation` tags every event this provider emits; the state machine
    /// drops events whose generation no longer matches the installed provider.
    pub fn spawn(
        transcriber: Box<dyn Transcriber>,
        pcm_sink: PcmSink,
        events: Sender<Event>,
        generation: u64,
    ) -> Self {
        let name = transcriber.name();
        let timeout = transcriber.timeout();

        // Bounded so a wedged worker applies backpressure and drops audio
        // rather than growing without limit. 400 chunks is ~20 seconds.
        let (pcm_tx, pcm_rx) = crossbeam_channel::bounded::<Vec<i16>>(400);
        let (control_tx, control_rx) = crossbeam_channel::unbounded::<Control>();
        let session = Arc::new(AtomicU64::new(0));

        {
            let mut guard = pcm_sink.lock().expect("pcm sink poisoned");
            *guard = Some(pcm_tx.clone());
        }

        let worker_session = Arc::clone(&session);
        let worker_name = name.clone();
        std::thread::Builder::new()
            .name(format!("stt-{}", name.replace(' ', "-")))
            .spawn(move || {
                run_worker(
                    transcriber,
                    control_rx,
                    pcm_rx,
                    events,
                    generation,
                    worker_session,
                );
                tracing::debug!("{worker_name} worker exited");
            })
            .expect("failed to spawn the STT worker thread");

        Self {
            name,
            timeout,
            control: control_tx,
            pcm_sink,
            pcm_tx,
            session,
            active: false,
        }
    }
}

impl SttControl for WorkerProvider {
    fn display_name(&self) -> String {
        self.name.clone()
    }

    fn begin_session(&mut self) -> Result<(), String> {
        if self.active {
            return Err(format!("{} is already transcribing.", self.name));
        }
        self.control
            .send(Control::Begin)
            .map_err(|_| format!("{} stopped unexpectedly.", self.name))?;
        self.active = true;
        Ok(())
    }

    fn end_session(&mut self) {
        if !self.active {
            return;
        }
        self.active = false;
        let _ = self.control.send(Control::End);
    }

    fn cancel_session(&mut self) {
        // Bump first: a result already being computed must be discarded even
        // if the worker never sees the Cancel message in time.
        self.session.fetch_add(1, Ordering::SeqCst);
        self.active = false;
        let _ = self.control.send(Control::Cancel);
    }

    fn transcription_timeout(&self) -> Duration {
        self.timeout
    }
}

impl Drop for WorkerProvider {
    fn drop(&mut self) {
        let _ = self.control.send(Control::Shutdown);

        // Detach the audio sink so the capture layer stops feeding a worker
        // that is on its way out — but only if the installed sink is still
        // ours. A provider swap builds the replacement first (it needs its
        // generation baked in) and drops the outgoing provider second, so
        // clearing unconditionally would wipe the sink the *new* provider had
        // just installed. Audio would then reach nobody and every dictation
        // would come back empty.
        if let Ok(mut guard) = self.pcm_sink.lock() {
            let is_ours = guard
                .as_ref()
                .is_some_and(|tx| tx.same_channel(&self.pcm_tx));
            if is_ours {
                *guard = None;
            }
        }
    }
}

fn run_worker(
    mut transcriber: Box<dyn Transcriber>,
    control: Receiver<Control>,
    pcm: Receiver<Vec<i16>>,
    events: Sender<Event>,
    generation: u64,
    session: Arc<AtomicU64>,
) {
    transcriber.prewarm();

    let mut buffer: Vec<i16> = Vec::new();
    let mut recording = false;
    let mut audio_open = true;

    loop {
        // Control messages take strict priority over audio. A `select!` here
        // would pick at random between two ready channels, so a `Begin` could
        // be handled *after* the first audio chunk had already been read and
        // dropped for arriving outside a session — losing the leading word.
        match control.try_recv() {
            Ok(message) => {
                match handle_control(
                    message,
                    &mut transcriber,
                    &pcm,
                    &events,
                    &session,
                    generation,
                    &mut buffer,
                    &mut recording,
                ) {
                    ControlOutcome::Continue => continue,
                    ControlOutcome::Stop => return,
                }
            }
            Err(crossbeam_channel::TryRecvError::Empty) => {}
            Err(crossbeam_channel::TryRecvError::Disconnected) => {
                transcriber.shutdown();
                return;
            }
        }

        if !audio_open {
            // The capture side is gone, but control messages may still arrive
            // (a final `End`, or `Shutdown`), so block on that channel alone.
            match control.recv() {
                Ok(message) => {
                    match handle_control(
                        message,
                        &mut transcriber,
                        &pcm,
                        &events,
                        &session,
                        generation,
                        &mut buffer,
                        &mut recording,
                    ) {
                        ControlOutcome::Continue => continue,
                        ControlOutcome::Stop => return,
                    }
                }
                Err(_) => {
                    transcriber.shutdown();
                    return;
                }
            }
        }

        // Time-boxed so control is re-checked promptly even while audio flows.
        match pcm.recv_timeout(Duration::from_millis(20)) {
            Ok(chunk) => {
                // A chunk and a control message can become ready at the same
                // instant, and which one wakes this thread first is arbitrary.
                // Rather than letting that coin-flip decide whether audio is
                // kept, drain control while holding the chunk and place it
                // deliberately:
                //
                //   * before an `End`, because audio in flight when the user
                //     released the key belongs to that utterance;
                //   * after a `Begin`, because it is the leading audio of the
                //     new one;
                //   * dropped after a `Cancel`, or if no session is open.
                let mut held = Some(chunk);

                loop {
                    match control.try_recv() {
                        Ok(message) => {
                            if matches!(message, Control::End) && recording {
                                if let Some(chunk) = held.take() {
                                    push_capped(&mut buffer, chunk);
                                }
                            }
                            match handle_control(
                                message,
                                &mut transcriber,
                                &pcm,
                                &events,
                                &session,
                                generation,
                                &mut buffer,
                                &mut recording,
                            ) {
                                ControlOutcome::Continue => {}
                                ControlOutcome::Stop => return,
                            }
                        }
                        Err(crossbeam_channel::TryRecvError::Empty) => break,
                        Err(crossbeam_channel::TryRecvError::Disconnected) => {
                            transcriber.shutdown();
                            return;
                        }
                    }
                }

                if recording {
                    if let Some(chunk) = held {
                        push_capped(&mut buffer, chunk);
                    }
                }
            }
            Err(crossbeam_channel::RecvTimeoutError::Timeout) => {}
            Err(crossbeam_channel::RecvTimeoutError::Disconnected) => audio_open = false,
        }
    }
}

enum ControlOutcome {
    Continue,
    Stop,
}

#[allow(clippy::too_many_arguments)]
fn handle_control(
    message: Control,
    transcriber: &mut Box<dyn Transcriber>,
    pcm: &Receiver<Vec<i16>>,
    events: &Sender<Event>,
    session: &Arc<AtomicU64>,
    generation: u64,
    buffer: &mut Vec<i16>,
    recording: &mut bool,
) -> ControlOutcome {
    match message {
        Control::Begin => {
            buffer.clear();
            *recording = true;
        }
        Control::End => {
            *recording = false;
            // Drain whatever the audio thread queued but we have not read yet;
            // those are the final milliseconds of speech.
            while let Ok(chunk) = pcm.try_recv() {
                push_capped(buffer, chunk);
            }

            let started = session.load(Ordering::SeqCst);
            let audio = std::mem::take(buffer);
            if audio.is_empty() {
                // Nothing captured: report an empty final rather than leaving
                // the state machine waiting for its timeout, which would look
                // like a freeze.
                let _ = events.send(Event::SttFinal {
                    generation,
                    text: String::new(),
                });
                return ControlOutcome::Continue;
            }

            let result = transcriber.transcribe(&audio);

            // The session was cancelled while we were busy.
            if session.load(Ordering::SeqCst) != started {
                tracing::info!("discarding result from a cancelled session");
                return ControlOutcome::Continue;
            }

            let event = match result {
                Ok(text) => Event::SttFinal { generation, text },
                Err(message) => Event::SttError {
                    generation,
                    message,
                },
            };
            if events.send(event).is_err() {
                return ControlOutcome::Stop;
            }
        }
        Control::Cancel => {
            *recording = false;
            buffer.clear();
            while pcm.try_recv().is_ok() {}
        }
        Control::Shutdown => {
            transcriber.shutdown();
            return ControlOutcome::Stop;
        }
    }
    ControlOutcome::Continue
}

fn push_capped(buffer: &mut Vec<i16>, chunk: Vec<i16>) {
    if buffer.len() >= MAX_SESSION_SAMPLES {
        return;
    }
    let room = MAX_SESSION_SAMPLES - buffer.len();
    if chunk.len() <= room {
        buffer.extend_from_slice(&chunk);
    } else {
        buffer.extend_from_slice(&chunk[..room]);
        tracing::warn!("utterance hit the 10 minute cap; further audio is dropped");
    }
}

/// Provider that never transcribes, used for tests and as a safe placeholder
/// before a real provider is constructed.
pub struct StubTranscriber;

impl Transcriber for StubTranscriber {
    fn name(&self) -> String {
        "Stub (testing only)".to_string()
    }

    fn transcribe(&mut self, _pcm: &[i16]) -> Result<String, String> {
        Err(
            "The stub provider cannot transcribe. Choose a real provider in Settings → Provider."
                .to_string(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct EchoTranscriber {
        /// Returned verbatim, so a test can assert the plumbing end to end.
        response: Result<String, String>,
        /// Samples seen by the last call.
        seen: Arc<AtomicU64>,
        delay: Duration,
    }

    impl Transcriber for EchoTranscriber {
        fn name(&self) -> String {
            "Echo".to_string()
        }

        fn transcribe(&mut self, pcm: &[i16]) -> Result<String, String> {
            self.seen.store(pcm.len() as u64, Ordering::SeqCst);
            std::thread::sleep(self.delay);
            self.response.clone()
        }
    }

    fn harness(
        response: Result<String, String>,
        delay: Duration,
    ) -> (WorkerProvider, Receiver<Event>, PcmSink, Arc<AtomicU64>) {
        let (events_tx, events_rx) = crossbeam_channel::unbounded();
        let sink: PcmSink = Arc::new(std::sync::Mutex::new(None));
        let seen = Arc::new(AtomicU64::new(0));
        let provider = WorkerProvider::spawn(
            Box::new(EchoTranscriber {
                response,
                seen: Arc::clone(&seen),
                delay,
            }),
            Arc::clone(&sink),
            events_tx,
            7,
        );
        (provider, events_rx, sink, seen)
    }

    fn feed(sink: &PcmSink, samples: usize) {
        let guard = sink.lock().unwrap();
        let tx = guard.as_ref().expect("sink installed");
        tx.send(vec![1i16; samples]).unwrap();
    }

    #[test]
    fn audio_fed_during_a_session_reaches_the_transcriber() {
        let (mut provider, events, sink, seen) = harness(Ok("hello".to_string()), Duration::ZERO);

        provider.begin_session().unwrap();
        feed(&sink, 1_000);
        feed(&sink, 600);
        // Let the worker drain before ending.
        std::thread::sleep(Duration::from_millis(50));
        provider.end_session();

        let event = events
            .recv_timeout(Duration::from_secs(5))
            .expect("a final result");
        match event {
            Event::SttFinal { generation, text } => {
                assert_eq!(generation, 7, "events must carry the provider generation");
                assert_eq!(text, "hello");
            }
            other => panic!("unexpected {other:?}"),
        }
        assert_eq!(seen.load(Ordering::SeqCst), 1_600);
    }

    #[test]
    fn a_transcriber_error_surfaces_as_an_stt_error() {
        let (mut provider, events, sink, _) =
            harness(Err("model exploded".to_string()), Duration::ZERO);

        provider.begin_session().unwrap();
        feed(&sink, 100);
        std::thread::sleep(Duration::from_millis(50));
        provider.end_session();

        let event = events
            .recv_timeout(Duration::from_secs(5))
            .expect("an error");
        assert!(matches!(event, Event::SttError { message, .. } if message == "model exploded"));
    }

    #[test]
    fn a_session_with_no_audio_finalises_empty_instead_of_hanging() {
        // Otherwise the state machine would sit in Transcribing until its
        // timeout, which looks like a freeze to the user.
        let (mut provider, events, _sink, _) = harness(Ok("unused".to_string()), Duration::ZERO);

        provider.begin_session().unwrap();
        provider.end_session();

        let event = events
            .recv_timeout(Duration::from_secs(5))
            .expect("an empty final");
        assert!(matches!(event, Event::SttFinal { text, .. } if text.is_empty()));
    }

    #[test]
    fn a_cancelled_session_never_delivers_its_result() {
        let (mut provider, events, sink, _) =
            harness(Ok("too late".to_string()), Duration::from_millis(300));

        provider.begin_session().unwrap();
        feed(&sink, 500);
        std::thread::sleep(Duration::from_millis(50));
        provider.end_session();
        // Cancel while the (deliberately slow) transcription is in flight.
        std::thread::sleep(Duration::from_millis(50));
        provider.cancel_session();

        assert!(
            events.recv_timeout(Duration::from_millis(800)).is_err(),
            "a cancelled session must not inject text into whatever the user is doing now"
        );
    }

    #[test]
    fn cancelling_discards_buffered_audio() {
        let (mut provider, events, sink, seen) = harness(Ok("fresh".to_string()), Duration::ZERO);

        provider.begin_session().unwrap();
        feed(&sink, 4_000);
        std::thread::sleep(Duration::from_millis(50));
        provider.cancel_session();

        // A new session must not inherit the cancelled session's audio.
        provider.begin_session().unwrap();
        feed(&sink, 300);
        std::thread::sleep(Duration::from_millis(50));
        provider.end_session();

        let event = events
            .recv_timeout(Duration::from_secs(5))
            .expect("a final result");
        assert!(matches!(event, Event::SttFinal { text, .. } if text == "fresh"));
        assert_eq!(
            seen.load(Ordering::SeqCst),
            300,
            "stale audio leaked into the new session"
        );
    }

    #[test]
    fn beginning_twice_is_refused() {
        let (mut provider, _events, _sink, _) = harness(Ok(String::new()), Duration::ZERO);
        provider.begin_session().unwrap();
        assert!(provider.begin_session().is_err());
    }

    #[test]
    fn ending_without_beginning_is_a_no_op() {
        let (mut provider, events, _sink, _) = harness(Ok("nope".to_string()), Duration::ZERO);
        provider.end_session();
        assert!(events.recv_timeout(Duration::from_millis(200)).is_err());
    }

    #[test]
    fn audio_arriving_outside_a_session_is_ignored() {
        let (mut provider, events, sink, seen) =
            harness(Ok("only new".to_string()), Duration::ZERO);

        // Audio before begin_session (a stray speculative chunk).
        feed(&sink, 9_000);
        std::thread::sleep(Duration::from_millis(50));

        provider.begin_session().unwrap();
        feed(&sink, 128);
        std::thread::sleep(Duration::from_millis(50));
        provider.end_session();

        events
            .recv_timeout(Duration::from_secs(5))
            .expect("a final result");
        assert_eq!(seen.load(Ordering::SeqCst), 128);
    }

    #[test]
    fn the_session_buffer_is_capped() {
        let mut buffer = vec![0i16; MAX_SESSION_SAMPLES - 10];
        push_capped(&mut buffer, vec![1i16; 1_000]);
        assert_eq!(buffer.len(), MAX_SESSION_SAMPLES);
        // Further pushes are dropped rather than growing the buffer.
        push_capped(&mut buffer, vec![1i16; 1_000]);
        assert_eq!(buffer.len(), MAX_SESSION_SAMPLES);
    }

    #[test]
    fn the_stub_provider_reports_a_helpful_error() {
        let mut stub = StubTranscriber;
        let err = stub.transcribe(&[0; 16]).unwrap_err();
        assert!(err.contains("Settings"));
    }

    #[test]
    fn replacing_a_provider_leaves_the_new_ones_audio_sink_installed() {
        // A provider swap constructs the replacement before dropping the
        // outgoing one. If the old provider's Drop cleared the sink
        // unconditionally it would wipe the new provider's, and every
        // subsequent dictation would transcribe silence.
        let (events_tx, events_rx) = crossbeam_channel::unbounded();
        let sink: PcmSink = Arc::new(std::sync::Mutex::new(None));
        let seen = Arc::new(AtomicU64::new(0));

        let old = WorkerProvider::spawn(
            Box::new(EchoTranscriber {
                response: Ok("old".to_string()),
                seen: Arc::new(AtomicU64::new(0)),
                delay: Duration::ZERO,
            }),
            Arc::clone(&sink),
            events_tx.clone(),
            1,
        );

        // Build the replacement first, exactly as the app does...
        let mut new = WorkerProvider::spawn(
            Box::new(EchoTranscriber {
                response: Ok("new".to_string()),
                seen: Arc::clone(&seen),
                delay: Duration::ZERO,
            }),
            Arc::clone(&sink),
            events_tx,
            2,
        );
        // ...then drop the outgoing one.
        drop(old);

        assert!(
            sink.lock().unwrap().is_some(),
            "the audio sink was detached by the old provider"
        );

        new.begin_session().unwrap();
        feed(&sink, 512);
        std::thread::sleep(Duration::from_millis(50));
        new.end_session();

        let event = events_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("a final result");
        match event {
            Event::SttFinal { generation, text } => {
                assert_eq!(generation, 2);
                assert_eq!(text, "new");
            }
            other => panic!("unexpected {other:?}"),
        }
        assert_eq!(
            seen.load(Ordering::SeqCst),
            512,
            "audio never reached the new provider"
        );
    }

    #[test]
    fn dropping_the_installed_provider_does_detach_its_sink() {
        let (events_tx, _rx) = crossbeam_channel::unbounded();
        let sink: PcmSink = Arc::new(std::sync::Mutex::new(None));
        let provider =
            WorkerProvider::spawn(Box::new(StubTranscriber), Arc::clone(&sink), events_tx, 1);
        assert!(sink.lock().unwrap().is_some());
        drop(provider);
        assert!(
            sink.lock().unwrap().is_none(),
            "a lone provider should detach on drop"
        );
    }
}
