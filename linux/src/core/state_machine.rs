//! Central dictation coordinator.
//!
//! A port of `DictationStateMachine.swift`. Every state transition in the app
//! flows through here, and the transition rules — including the awkward
//! recovery paths that only exist because real input hardware drops events —
//! are preserved deliberately.
//!
//! ```text
//!  ┌──────┐  hold started   ┌───────────┐  hold ended   ┌──────────────┐
//!  │ Idle │ ───────────────▶ │ Recording │ ────────────▶ │ Transcribing │
//!  └──────┘                  └───────────┘               └──────┬───────┘
//!      ▲                                                        │
//!      │              result received / error                   │
//!      └────────────────────────────────────────────────────────┘
//! ```
//!
//! ## Differences from the macOS original
//!
//! * **No microphone permission state.** macOS gates the mic behind TCC, so the
//!   Swift machine carries a `pendingPermissionRecordingStart` flag and an async
//!   grant callback. Linux has no such prompt for a PipeWire/ALSA client, so a
//!   device that cannot be opened is simply a capture error.
//! * **Stale results are rejected by generation counter** rather than by object
//!   identity (`self.sttProvider === provider`), because Rust's ownership rules
//!   make a live back-reference from a worker thread awkward. The effect is the
//!   same: a result from a provider that has since been swapped out is dropped.

use std::time::{Duration, Instant};

use crate::core::post_processing::Pipeline;

/// Audio level at or above which a buffer counts as speech. Matches the
/// macOS build so the "no speech detected" behaviour is identical.
pub const SPEECH_LEVEL_THRESHOLD: f32 = 0.08;

/// How long `Success` is shown before returning to `Idle`.
pub const SUCCESS_DISPLAY: Duration = Duration::from_millis(450);

/// Polling interval for the silence auto-stop watchdog.
pub const SILENCE_POLL_INTERVAL: Duration = Duration::from_millis(100);

/// Floor for the transcription timeout, regardless of what a provider asks for.
pub const MIN_TRANSCRIBE_TIMEOUT: Duration = Duration::from_secs(10);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum State {
    Idle,
    Recording,
    Transcribing,
    Success,
    Error(String),
}

impl State {
    pub fn is_error(&self) -> bool {
        matches!(self, State::Error(_))
    }
}

/// Timers the machine schedules. Each is at most singly-outstanding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Timer {
    /// Return to `Idle` after showing `Success`.
    SuccessReset,
    /// Give up on a provider that never delivered a final result.
    TranscribeTimeout,
    /// Poll for the silence that ends a hands-free session.
    SilenceWatchdog,
}

/// Everything that can drive the machine.
#[derive(Debug, Clone)]
pub enum Event {
    /// Hotkey went down; hold not yet confirmed.
    PressBegan,
    /// Hotkey released before the hold threshold.
    PressAbandoned,
    /// Hold threshold reached.
    HoldStarted,
    /// Hotkey released after a confirmed hold.
    HoldEnded,
    /// Double-press detected; start a hands-free session.
    HandsFreeLockStarted,
    /// Hotkey pressed while hands-free; stop and transcribe.
    HandsFreeLockStopRequested,
    /// Esc pressed; abandon the session without transcribing.
    EscapePressed,
    /// The hotkey listener could not start.
    HotkeyStartFailed(String),
    /// Menu-driven start (the tray "Start dictation" item).
    OneShotStartRequested,
    /// Menu-driven stop.
    OneShotStopRequested,
    /// Microphone level in 0..=1.
    AudioLevel(f32),
    /// Capture failed or was interrupted.
    AudioError(String),
    /// A streaming partial transcript, tagged with its provider generation.
    ///
    /// None of the Linux engines stream today — whisper.cpp, CTranslate2, and
    /// ONNX Runtime all decode a complete utterance — so nothing constructs
    /// this outside the tests. It is kept because the handling is real,
    /// tested, and drives the overlay's live transcript the moment an engine
    /// that does stream is added.
    #[allow(dead_code)]
    SttPartial { generation: u64, text: String },
    /// The final transcript, tagged with its provider generation.
    SttFinal { generation: u64, text: String },
    /// A provider failure, tagged with its provider generation.
    SttError { generation: u64, message: String },
    /// A scheduled timer elapsed. `token` guards against a cancelled timer
    /// that had already been handed to the executor.
    TimerFired { timer: Timer, token: u64 },
}

// ---------------------------------------------------------------------------
// Dependencies
// ---------------------------------------------------------------------------

/// Microphone capture.
pub trait AudioCapturing {
    /// Begins capture. `device` is a cpal device name; empty means default.
    fn start(&mut self, device: &str) -> Result<(), String>;
    fn stop(&mut self);
}

/// Controls one speech-to-text session. Results are delivered asynchronously as
/// [`Event::SttPartial`] / [`Event::SttFinal`] / [`Event::SttError`].
pub trait SttControl {
    fn display_name(&self) -> String;
    fn begin_session(&mut self) -> Result<(), String>;
    /// Finalise: the provider should deliver its last result.
    fn end_session(&mut self);
    /// Abort: the provider must not deliver anything further for this session.
    fn cancel_session(&mut self);
    /// How long to wait after `end_session` for the final result.
    fn transcription_timeout(&self) -> Duration;
}

/// Places the final transcript into the focused application.
pub trait TextInjecting {
    fn inject(&self, text: &str);
}

/// Schedules a [`Event::TimerFired`] to be delivered after a delay.
pub trait Scheduling {
    fn schedule(&self, timer: Timer, token: u64, delay: Duration);
}

/// Monotonic clock, injectable so tests can drive the silence watchdog without
/// sleeping.
pub trait Clock {
    fn now(&self) -> Instant;
}

/// Real clock.
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
}

/// Observer invoked on each state transition.
pub type StateObserver = Box<dyn FnMut(&State)>;
/// Observer invoked with each microphone level sample, in 0..=1.
pub type LevelObserver = Box<dyn FnMut(f32)>;
/// Observer invoked with the post-processed transcript, partial or final.
pub type TranscriptObserver = Box<dyn FnMut(&str)>;

/// UI-facing callbacks, mirroring the Swift machine's closures.
#[derive(Default)]
pub struct Observers {
    pub on_state_change: Option<StateObserver>,
    pub on_audio_level: Option<LevelObserver>,
    pub on_transcript: Option<TranscriptObserver>,
}

impl Observers {
    fn state(&mut self, state: &State) {
        if let Some(cb) = self.on_state_change.as_mut() {
            cb(state);
        }
    }

    fn level(&mut self, level: f32) {
        if let Some(cb) = self.on_audio_level.as_mut() {
            cb(level);
        }
    }

    fn transcript(&mut self, text: &str) {
        if let Some(cb) = self.on_transcript.as_mut() {
            cb(text);
        }
    }
}

// ---------------------------------------------------------------------------
// Machine
// ---------------------------------------------------------------------------

pub struct DictationStateMachine {
    state: State,

    audio: Box<dyn AudioCapturing>,
    stt: Box<dyn SttControl>,
    injector: Box<dyn TextInjecting>,
    scheduler: Box<dyn Scheduling>,
    clock: Box<dyn Clock>,
    pipeline: Pipeline,
    pub observers: Observers,

    /// Input device name passed to the capture layer.
    input_device: String,
    /// Silence that ends a hands-free session.
    silence_timeout: Duration,

    /// Bumped on every provider swap; results carrying an older value are stale.
    provider_generation: u64,
    /// Bumped per timer schedule; a fired timer with an older token is stale.
    timer_tokens: [u64; 3],

    /// Capture running between key-down and hold confirmation. State stays
    /// `Idle` and no UI is shown, so an abandoned tap is invisible.
    speculative_capture: bool,
    /// True while a menu-initiated or hands-free session is running, which is
    /// what arms the silence auto-stop watchdog.
    one_shot_active: bool,
    one_shot_pending: bool,
    /// True between a double-press and the press that stops it.
    hands_free_lock: bool,
    /// Whether any buffer in this recording crossed the speech threshold.
    detected_speech: bool,
    last_speech_at: Option<Instant>,
    session_started_at: Option<Instant>,
    transcribing_started_at: Option<Instant>,
}

/// What the machine wants the surrounding app to do about the hotkey monitor's
/// own lock state. The Swift build calls `hotkeyMonitor.endHandsFreeLock()`
/// directly; here it is returned so the machine stays free of a back-reference.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Outcome {
    /// The hotkey monitor should clear its hands-free lock.
    pub release_hands_free_lock: bool,
}

pub struct Dependencies {
    pub audio: Box<dyn AudioCapturing>,
    pub stt: Box<dyn SttControl>,
    pub injector: Box<dyn TextInjecting>,
    pub scheduler: Box<dyn Scheduling>,
    pub clock: Box<dyn Clock>,
    pub pipeline: Pipeline,
}

impl DictationStateMachine {
    pub fn new(deps: Dependencies) -> Self {
        Self {
            state: State::Idle,
            audio: deps.audio,
            stt: deps.stt,
            injector: deps.injector,
            scheduler: deps.scheduler,
            clock: deps.clock,
            pipeline: deps.pipeline,
            observers: Observers::default(),
            input_device: String::new(),
            silence_timeout: Duration::from_secs(2),
            provider_generation: 0,
            timer_tokens: [0; 3],
            speculative_capture: false,
            one_shot_active: false,
            one_shot_pending: false,
            hands_free_lock: false,
            detected_speech: false,
            last_speech_at: None,
            session_started_at: None,
            transcribing_started_at: None,
        }
    }

    pub fn state(&self) -> &State {
        &self.state
    }

    pub fn provider_generation(&self) -> u64 {
        self.provider_generation
    }

    pub fn set_input_device(&mut self, device: String) {
        self.input_device = device;
    }

    pub fn set_silence_timeout(&mut self, timeout: Duration) {
        self.silence_timeout = timeout;
    }

    pub fn set_pipeline(&mut self, pipeline: Pipeline) {
        self.pipeline = pipeline;
    }

    /// The generation the *next* provider will be given.
    ///
    /// A provider has to be constructed with its generation baked in — its
    /// worker thread tags every event with it — but the counter only advances
    /// inside [`Self::replace_provider`]. This lets the caller build the
    /// provider first and hand it over second.
    pub fn next_provider_generation(&self) -> u64 {
        self.provider_generation + 1
    }

    /// Hot-swaps the STT provider, mirroring `replaceProvider()`.
    ///
    /// Any in-flight session is torn down first, and the generation counter is
    /// bumped so results still in flight from the old provider are ignored.
    /// Returns the new generation, which the caller must tag the new provider's
    /// events with.
    pub fn replace_provider(&mut self, mut new_provider: Box<dyn SttControl>) -> u64 {
        let prior = self.state.clone();
        tracing::info!(
            "replacing STT provider {} → {} (state={:?})",
            self.stt.display_name(),
            new_provider.display_name(),
            prior
        );

        self.cancel_timer(Timer::TranscribeTimeout);
        self.cancel_timer(Timer::SuccessReset);
        self.cancel_timer(Timer::SilenceWatchdog);
        self.discard_speculative_capture();
        self.hands_free_lock = false;
        self.one_shot_active = false;
        self.one_shot_pending = false;
        self.detected_speech = false;

        match prior {
            State::Recording => {
                self.audio.stop();
                self.stt.end_session();
            }
            State::Transcribing => self.stt.end_session(),
            _ => {}
        }

        std::mem::swap(&mut self.stt, &mut new_provider);
        self.provider_generation += 1;

        if prior != State::Idle {
            self.transition(State::Idle);
        }
        self.provider_generation
    }

    /// Tears everything down, e.g. at shutdown or when dictation is disabled.
    pub fn deactivate(&mut self) -> Outcome {
        tracing::info!("deactivating state machine (state={:?})", self.state);
        self.discard_speculative_capture();
        self.audio.stop();
        self.cancel_timer(Timer::TranscribeTimeout);
        self.cancel_timer(Timer::SuccessReset);
        self.cancel_timer(Timer::SilenceWatchdog);
        let outcome = self.release_hands_free_lock();

        if matches!(self.state, State::Recording | State::Transcribing) {
            self.stt.end_session();
        }

        self.observers.level(0.0);
        self.observers.transcript("");
        self.detected_speech = false;
        self.session_started_at = None;
        self.transcribing_started_at = None;
        self.transition(State::Idle);
        outcome
    }

    // -----------------------------------------------------------------------
    // Event entry point
    // -----------------------------------------------------------------------

    pub fn handle(&mut self, event: Event) -> Outcome {
        match event {
            Event::PressBegan => {
                self.handle_press_began();
                Outcome::default()
            }
            Event::PressAbandoned => {
                if self.speculative_capture {
                    tracing::debug!("press abandoned before hold threshold; discarding capture");
                    self.discard_speculative_capture();
                }
                Outcome::default()
            }
            Event::HoldStarted => self.handle_hold_started(),
            Event::HoldEnded => self.handle_hold_ended(),
            Event::HandsFreeLockStarted => self.handle_hands_free_lock_started(),
            Event::HandsFreeLockStopRequested => {
                tracing::info!("hands-free stop requested");
                let mut outcome = self.release_hands_free_lock();
                self.one_shot_pending = false;
                let ended = self.handle_hold_ended();
                outcome.release_hands_free_lock |= ended.release_hands_free_lock;
                outcome
            }
            Event::EscapePressed => self.handle_escape(),
            Event::HotkeyStartFailed(message) => {
                tracing::error!("hotkey monitor failed to start: {message}");
                self.transition(State::Error(message));
                Outcome::default()
            }
            Event::OneShotStartRequested => self.start_one_shot(),
            Event::OneShotStopRequested => {
                self.one_shot_pending = false;
                self.handle_hold_ended()
            }
            Event::AudioLevel(level) => {
                self.handle_audio_level(level);
                Outcome::default()
            }
            Event::AudioError(message) => self.recover_from_capture_failure(message),
            Event::SttPartial { generation, text } => {
                if self.is_stale(generation) {
                    return Outcome::default();
                }
                self.handle_stt_result(&text, false)
            }
            Event::SttFinal { generation, text } => {
                if self.is_stale(generation) {
                    return Outcome::default();
                }
                self.handle_stt_result(&text, true)
            }
            Event::SttError {
                generation,
                message,
            } => {
                if self.is_stale(generation) {
                    return Outcome::default();
                }
                tracing::error!("STT provider error: {message}");
                self.cancel_timer(Timer::TranscribeTimeout);
                let outcome = self.release_hands_free_lock();
                self.one_shot_active = false;
                self.transition(State::Error(message));
                outcome
            }
            Event::TimerFired { timer, token } => self.handle_timer(timer, token),
        }
    }

    fn is_stale(&self, generation: u64) -> bool {
        if generation != self.provider_generation {
            tracing::warn!(
                "ignoring event from stale provider generation {generation} (current {})",
                self.provider_generation
            );
            return true;
        }
        false
    }

    // -----------------------------------------------------------------------
    // Press / hold
    // -----------------------------------------------------------------------

    /// Key-down before the hold threshold: open the mic now so speech during
    /// the confirmation window is not lost. No state change and no UI, because
    /// a tap that never becomes a hold must be invisible.
    fn handle_press_began(&mut self) {
        if self.state != State::Idle || self.speculative_capture {
            return;
        }

        if let Err(err) = self.stt.begin_session() {
            tracing::debug!("speculative capture unavailable: {err}");
            self.stt.cancel_session();
            return;
        }
        if let Err(err) = self.audio.start(&self.input_device) {
            tracing::debug!("speculative capture unavailable: {err}");
            self.stt.cancel_session();
            self.audio.stop();
            return;
        }

        self.speculative_capture = true;
        self.session_started_at = Some(self.clock.now());
        tracing::debug!("speculative capture started");
    }

    fn discard_speculative_capture(&mut self) {
        if !self.speculative_capture {
            return;
        }
        self.speculative_capture = false;
        self.detected_speech = false;
        self.session_started_at = None;
        self.audio.stop();
        self.stt.cancel_session();
    }

    fn handle_hold_started(&mut self) -> Outcome {
        let mut outcome = Outcome::default();

        if self.state == State::Success {
            self.cancel_timer(Timer::SuccessReset);
            self.transition(State::Idle);
        }
        if self.state.is_error() {
            tracing::info!("hold-start in error state; recovering to idle");
            self.transition(State::Idle);
        }
        if self.state == State::Transcribing {
            // The user wants to dictate again *now*. Swallowing the press
            // would make the hotkey feel dead until the old request lands.
            tracing::info!("hold-start during transcribing; cancelling in-flight transcription");
            self.cancel_timer(Timer::TranscribeTimeout);
            self.stt.cancel_session();
            self.session_started_at = None;
            self.transcribing_started_at = None;
            self.observers.transcript("");
            self.transition(State::Idle);
        }
        if self.state == State::Recording {
            // A release lost to a dropped evdev event can orphan `Recording`.
            // Without this branch only every second press would work.
            tracing::warn!("hold-start while already recording; recovering orphaned session");
            self.cancel_timer(Timer::SilenceWatchdog);
            outcome = self.release_hands_free_lock();
            self.one_shot_active = false;
            self.detected_speech = false;
            self.audio.stop();
            self.stt.cancel_session();
            self.session_started_at = None;
            self.transcribing_started_at = None;
            self.transition(State::Idle);
        }

        if self.state != State::Idle {
            return outcome;
        }

        self.begin_recording_session(outcome)
    }

    fn begin_recording_session(&mut self, mut outcome: Outcome) -> Outcome {
        self.observers.transcript("");

        // Adopt a speculative capture: the mic and STT session are already
        // running and hold the leading audio.
        if self.speculative_capture {
            self.speculative_capture = false;
            self.one_shot_active = self.one_shot_pending;
            self.one_shot_pending = false;
            self.last_speech_at = Some(self.clock.now());
            if self.one_shot_active {
                self.schedule_silence_watchdog();
            }
            self.transcribing_started_at = None;
            tracing::info!("recording session adopted speculative capture");
            self.transition(State::Recording);
            return outcome;
        }

        let mut began_stt = false;
        let result = self.stt.begin_session().and_then(|()| {
            began_stt = true;
            self.audio.start(&self.input_device)
        });

        match result {
            Ok(()) => {
                self.one_shot_active = self.one_shot_pending;
                self.one_shot_pending = false;
                self.detected_speech = false;
                self.last_speech_at = Some(self.clock.now());
                if self.one_shot_active {
                    self.schedule_silence_watchdog();
                }
                self.session_started_at = Some(self.clock.now());
                self.transcribing_started_at = None;
                tracing::info!("recording session started ({})", self.stt.display_name());
                self.transition(State::Recording);
            }
            Err(message) => {
                if began_stt {
                    self.stt.end_session();
                }
                // `audio.start` can fail partway through; stop() reverts it.
                self.audio.stop();
                // A failed one-shot start must not leak its pending flag into
                // the next hold, which would silently become a one-shot session
                // and auto-stop on silence mid-hold.
                self.one_shot_pending = false;
                let released = self.release_hands_free_lock();
                outcome.release_hands_free_lock |= released.release_hands_free_lock;
                tracing::error!("failed to start recording: {message}");
                self.transition(State::Error(message));
            }
        }
        outcome
    }

    fn handle_hold_ended(&mut self) -> Outcome {
        if self.state != State::Recording {
            // A hold that ends during the speculative window never became a
            // recording; drop the capture rather than transcribing silence.
            self.discard_speculative_capture();
            return Outcome::default();
        }

        self.cancel_timer(Timer::SilenceWatchdog);
        let outcome = self.release_hands_free_lock();
        let had_speech = self.detected_speech;
        self.one_shot_active = false;
        self.detected_speech = false;

        self.audio.stop();
        if let Some(started) = self.session_started_at {
            tracing::info!(
                "recording duration {}ms",
                self.clock.now().duration_since(started).as_millis()
            );
        }

        // Sending silence to the provider costs a round-trip and produces
        // nothing useful, so skip transcription entirely.
        if !had_speech {
            tracing::info!("no speech detected; skipping transcription");
            self.stt.end_session();
            self.session_started_at = None;
            self.transcribing_started_at = None;
            self.observers.level(0.0);
            self.transition(State::Idle);
            return outcome;
        }

        // Transition *before* end_session so a provider that answers
        // synchronously finds the machine already in `Transcribing`.
        self.transcribing_started_at = Some(self.clock.now());
        self.transition(State::Transcribing);
        self.schedule_transcribe_timeout();
        self.stt.end_session();
        outcome
    }

    // -----------------------------------------------------------------------
    // One-shot and hands-free
    // -----------------------------------------------------------------------

    fn start_one_shot(&mut self) -> Outcome {
        if !matches!(self.state, State::Idle | State::Success | State::Error(_)) {
            tracing::warn!("one-shot start ignored in state {:?}", self.state);
            return Outcome::default();
        }
        if self.state == State::Success || self.state.is_error() {
            self.transition(State::Idle);
        }
        self.observers.transcript("");
        self.one_shot_pending = true;
        self.handle_hold_started()
    }

    fn handle_hands_free_lock_started(&mut self) -> Outcome {
        if !matches!(self.state, State::Idle | State::Success | State::Error(_)) {
            tracing::info!(
                "hands-free lock requested in state {:?}; ignoring",
                self.state
            );
            return Outcome {
                release_hands_free_lock: true,
            };
        }
        tracing::info!("hands-free lock started");
        self.hands_free_lock = true;
        let mut outcome = self.start_one_shot();
        if self.state != State::Recording {
            // The recording never started, so release the lock: otherwise the
            // next press is consumed as a phantom "stop".
            let released = self.release_hands_free_lock();
            outcome.release_hands_free_lock |= released.release_hands_free_lock;
        }
        outcome
    }

    /// Clears the lock on this machine and tells the caller to clear it on the
    /// hotkey monitor too.
    fn release_hands_free_lock(&mut self) -> Outcome {
        if !self.hands_free_lock {
            return Outcome::default();
        }
        self.hands_free_lock = false;
        Outcome {
            release_hands_free_lock: true,
        }
    }

    fn handle_escape(&mut self) -> Outcome {
        if self.speculative_capture {
            self.discard_speculative_capture();
        }
        if self.state != State::Recording {
            return Outcome::default();
        }

        tracing::info!("escape pressed; cancelling recording without transcription");
        self.cancel_timer(Timer::SilenceWatchdog);
        let outcome = self.release_hands_free_lock();
        self.one_shot_active = false;
        self.one_shot_pending = false;
        self.detected_speech = false;
        self.audio.stop();
        self.stt.cancel_session();
        self.session_started_at = None;
        self.transcribing_started_at = None;
        self.observers.level(0.0);
        self.observers.transcript("");
        self.transition(State::Idle);
        outcome
    }

    // -----------------------------------------------------------------------
    // Audio + results
    // -----------------------------------------------------------------------

    fn handle_audio_level(&mut self, level: f32) {
        self.observers.level(level);
        // Speech during the speculative window counts: once adopted it is the
        // same recording.
        if self.state != State::Recording && !self.speculative_capture {
            return;
        }
        if level >= SPEECH_LEVEL_THRESHOLD {
            self.detected_speech = true;
            self.last_speech_at = Some(self.clock.now());
        }
    }

    fn handle_stt_result(&mut self, text: &str, is_final: bool) -> Outcome {
        if !matches!(self.state, State::Transcribing | State::Recording) {
            tracing::warn!("STT result in unexpected state {:?}; ignoring", self.state);
            return Outcome::default();
        }

        let processed = self.pipeline.process(text.trim(), is_final);
        self.observers.transcript(&processed);

        if !is_final {
            return Outcome::default();
        }

        let mut outcome = Outcome::default();

        // A provider can finalise while still `Recording` (a streaming engine
        // hitting its own endpoint). Shut capture down so the mic does not stay
        // hot after the success transition.
        if self.state == State::Recording {
            self.cancel_timer(Timer::SilenceWatchdog);
            outcome = self.release_hands_free_lock();
            self.one_shot_active = false;
            self.detected_speech = false;
            self.audio.stop();
        }

        self.cancel_timer(Timer::TranscribeTimeout);

        let now = self.clock.now();
        if let Some(started) = self.transcribing_started_at {
            tracing::info!(
                "transcription took {}ms",
                now.duration_since(started).as_millis()
            );
        }
        if let Some(started) = self.session_started_at {
            tracing::info!("end-to-end {}ms", now.duration_since(started).as_millis());
        }

        if processed.is_empty() {
            tracing::info!("transcript empty after post-processing; skipping injection");
        } else {
            tracing::info!(
                "injecting transcription ({} chars)",
                processed.chars().count()
            );
            self.injector.inject(&processed);
        }

        self.session_started_at = None;
        self.transcribing_started_at = None;
        self.observers.level(0.0);
        self.transition(State::Success);
        self.schedule(Timer::SuccessReset, SUCCESS_DISPLAY);
        outcome
    }

    fn recover_from_capture_failure(&mut self, message: String) -> Outcome {
        tracing::error!("audio capture failure: {message}");
        self.cancel_timer(Timer::TranscribeTimeout);
        self.cancel_timer(Timer::SuccessReset);
        self.cancel_timer(Timer::SilenceWatchdog);
        self.discard_speculative_capture();
        let outcome = self.release_hands_free_lock();
        self.one_shot_active = false;
        self.one_shot_pending = false;
        self.detected_speech = false;
        self.session_started_at = None;
        self.transcribing_started_at = None;

        if matches!(self.state, State::Recording | State::Transcribing) {
            self.stt.end_session();
        }
        self.audio.stop();
        self.observers.level(0.0);
        // Deliberately no automatic retry: the user starts the next recording.
        self.transition(State::Error(message));
        outcome
    }

    // -----------------------------------------------------------------------
    // Timers
    // -----------------------------------------------------------------------

    fn timer_slot(timer: Timer) -> usize {
        match timer {
            Timer::SuccessReset => 0,
            Timer::TranscribeTimeout => 1,
            Timer::SilenceWatchdog => 2,
        }
    }

    fn schedule(&mut self, timer: Timer, delay: Duration) {
        let slot = Self::timer_slot(timer);
        self.timer_tokens[slot] += 1;
        let token = self.timer_tokens[slot];
        self.scheduler.schedule(timer, token, delay);
    }

    /// Invalidates any outstanding fire of `timer`. The executor may still
    /// deliver it; the token check in [`Self::handle_timer`] discards it.
    fn cancel_timer(&mut self, timer: Timer) {
        self.timer_tokens[Self::timer_slot(timer)] += 1;
    }

    fn schedule_transcribe_timeout(&mut self) {
        let timeout = self.stt.transcription_timeout().max(MIN_TRANSCRIBE_TIMEOUT);
        self.schedule(Timer::TranscribeTimeout, timeout);
    }

    fn schedule_silence_watchdog(&mut self) {
        self.schedule(Timer::SilenceWatchdog, SILENCE_POLL_INTERVAL);
    }

    fn handle_timer(&mut self, timer: Timer, token: u64) -> Outcome {
        if token != self.timer_tokens[Self::timer_slot(timer)] {
            // Cancelled before it fired.
            return Outcome::default();
        }

        match timer {
            Timer::SuccessReset => {
                if self.state == State::Success {
                    self.transition(State::Idle);
                }
                Outcome::default()
            }
            Timer::TranscribeTimeout => {
                if self.state != State::Transcribing {
                    return Outcome::default();
                }
                let name = self.stt.display_name();
                tracing::error!("transcription timed out waiting for {name}");
                // Cancel the hung session so the provider's in-flight flag
                // clears; otherwise the next begin_session is refused and the
                // hotkey looks dead until the stale request finally lands.
                self.stt.cancel_session();
                let outcome = self.release_hands_free_lock();
                self.transition(State::Error(format!(
                    "{name} did not return a transcript in time. Try a smaller model or switch provider in Settings."
                )));
                outcome
            }
            Timer::SilenceWatchdog => {
                if self.state != State::Recording || !self.one_shot_active {
                    return Outcome::default();
                }
                let now = self.clock.now();
                let last_voice = self.last_speech_at.unwrap_or(now);
                let elapsed = now.saturating_duration_since(last_voice);

                // A faster endpoint when nothing has been said at all, so an
                // accidental hands-free start does not hold the mic open.
                let timeout = if self.detected_speech {
                    self.silence_timeout
                } else {
                    self.silence_timeout.min(
                        self.silence_timeout
                            .mul_f64(0.7)
                            .max(Duration::from_millis(450)),
                    )
                };

                if elapsed >= timeout {
                    tracing::info!(
                        "silence timeout reached ({}ms >= {}ms, speech={})",
                        elapsed.as_millis(),
                        timeout.as_millis(),
                        self.detected_speech
                    );
                    self.handle_hold_ended()
                } else {
                    self.schedule_silence_watchdog();
                    Outcome::default()
                }
            }
        }
    }

    fn transition(&mut self, new_state: State) {
        if new_state != State::Success {
            self.cancel_timer(Timer::SuccessReset);
        }
        if self.state == new_state {
            return;
        }
        tracing::debug!("state {:?} → {:?}", self.state, new_state);
        self.state = new_state;
        let snapshot = self.state.clone();
        self.observers.state(&snapshot);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    use crate::core::post_processing::Pipeline;
    use crate::core::settings::TextSettings;

    /// Shared recorder the mocks write into, so assertions can inspect what the
    /// machine actually asked its collaborators to do (London-school style,
    /// matching `tests/smoke/qa_smoke.swift` on macOS).
    #[derive(Default)]
    struct Recorder {
        audio_starts: usize,
        audio_stops: usize,
        audio_start_error: Option<String>,
        stt_begins: usize,
        stt_ends: usize,
        stt_cancels: usize,
        stt_begin_error: Option<String>,
        injected: Vec<String>,
        scheduled: Vec<(Timer, u64, Duration)>,
        states: Vec<State>,
        transcripts: Vec<String>,
    }

    type Shared = Rc<RefCell<Recorder>>;

    struct MockAudio(Shared);

    impl AudioCapturing for MockAudio {
        fn start(&mut self, _device: &str) -> Result<(), String> {
            let mut r = self.0.borrow_mut();
            if let Some(err) = r.audio_start_error.clone() {
                return Err(err);
            }
            r.audio_starts += 1;
            Ok(())
        }

        fn stop(&mut self) {
            self.0.borrow_mut().audio_stops += 1;
        }
    }

    struct MockStt {
        shared: Shared,
        name: String,
        timeout: Duration,
    }

    impl SttControl for MockStt {
        fn display_name(&self) -> String {
            self.name.clone()
        }

        fn begin_session(&mut self) -> Result<(), String> {
            let mut r = self.shared.borrow_mut();
            if let Some(err) = r.stt_begin_error.clone() {
                return Err(err);
            }
            r.stt_begins += 1;
            Ok(())
        }

        fn end_session(&mut self) {
            self.shared.borrow_mut().stt_ends += 1;
        }

        fn cancel_session(&mut self) {
            self.shared.borrow_mut().stt_cancels += 1;
        }

        fn transcription_timeout(&self) -> Duration {
            self.timeout
        }
    }

    struct MockInjector(Shared);

    impl TextInjecting for MockInjector {
        fn inject(&self, text: &str) {
            self.0.borrow_mut().injected.push(text.to_string());
        }
    }

    struct MockScheduler(Shared);

    impl Scheduling for MockScheduler {
        fn schedule(&self, timer: Timer, token: u64, delay: Duration) {
            self.0.borrow_mut().scheduled.push((timer, token, delay));
        }
    }

    /// Clock the test advances by hand, so the silence watchdog can be driven
    /// without sleeping.
    #[derive(Clone)]
    struct MockClock(Rc<RefCell<Instant>>);

    impl MockClock {
        fn new() -> Self {
            Self(Rc::new(RefCell::new(Instant::now())))
        }

        fn advance(&self, by: Duration) {
            let mut now = self.0.borrow_mut();
            *now += by;
        }
    }

    impl Clock for MockClock {
        fn now(&self) -> Instant {
            *self.0.borrow()
        }
    }

    struct Harness {
        machine: DictationStateMachine,
        shared: Shared,
        clock: MockClock,
    }

    impl Harness {
        fn new() -> Self {
            let shared: Shared = Rc::new(RefCell::new(Recorder::default()));
            let clock = MockClock::new();
            let observer_shared = Rc::clone(&shared);
            let transcript_shared = Rc::clone(&shared);

            let mut machine = DictationStateMachine::new(Dependencies {
                audio: Box::new(MockAudio(Rc::clone(&shared))),
                stt: Box::new(MockStt {
                    shared: Rc::clone(&shared),
                    name: "Mock".to_string(),
                    timeout: Duration::from_secs(30),
                }),
                injector: Box::new(MockInjector(Rc::clone(&shared))),
                scheduler: Box::new(MockScheduler(Rc::clone(&shared))),
                clock: Box::new(clock.clone()),
                pipeline: Pipeline::from_settings(&TextSettings::default()),
            });

            machine.observers.on_state_change = Some(Box::new(move |state| {
                observer_shared.borrow_mut().states.push(state.clone());
            }));
            machine.observers.on_transcript = Some(Box::new(move |text| {
                transcript_shared
                    .borrow_mut()
                    .transcripts
                    .push(text.to_string());
            }));

            Self {
                machine,
                shared,
                clock,
            }
        }

        fn send(&mut self, event: Event) -> Outcome {
            self.machine.handle(event)
        }

        fn state(&self) -> State {
            self.machine.state().clone()
        }

        fn generation(&self) -> u64 {
            self.machine.provider_generation()
        }

        /// Delivers the most recently scheduled fire of `timer`, as the real
        /// executor would.
        fn fire(&mut self, timer: Timer) -> Outcome {
            let token = self
                .shared
                .borrow()
                .scheduled
                .iter()
                .rev()
                .find(|(t, _, _)| *t == timer)
                .map(|(_, token, _)| *token)
                .unwrap_or_else(|| panic!("{timer:?} was never scheduled"));
            self.send(Event::TimerFired { timer, token })
        }

        fn speak(&mut self) {
            self.send(Event::AudioLevel(0.5));
        }

        fn recorder(&self) -> std::cell::Ref<'_, Recorder> {
            self.shared.borrow()
        }

        fn scheduled_count(&self, timer: Timer) -> usize {
            self.shared
                .borrow()
                .scheduled
                .iter()
                .filter(|(t, _, _)| *t == timer)
                .count()
        }
    }

    // -- happy path ---------------------------------------------------------

    #[test]
    fn a_full_dictation_runs_idle_to_success_and_back() {
        let mut h = Harness::new();
        let generation = h.generation();

        h.send(Event::HoldStarted);
        assert_eq!(h.state(), State::Recording);

        h.speak();
        h.send(Event::HoldEnded);
        assert_eq!(h.state(), State::Transcribing);

        h.send(Event::SttFinal {
            generation,
            text: "hello, world".into(),
        });
        assert_eq!(h.state(), State::Success);
        assert_eq!(h.recorder().injected, vec!["Hello, world"]);

        h.fire(Timer::SuccessReset);
        assert_eq!(h.state(), State::Idle);
    }

    #[test]
    fn partial_results_update_the_transcript_without_injecting() {
        let mut h = Harness::new();
        let generation = h.generation();
        h.send(Event::HoldStarted);
        h.speak();

        h.send(Event::SttPartial {
            generation,
            text: "hello".into(),
        });
        assert_eq!(
            h.state(),
            State::Recording,
            "a partial must not end the recording"
        );
        assert!(
            h.recorder().injected.is_empty(),
            "partials must never be injected"
        );
        assert!(h.recorder().transcripts.iter().any(|t| t == "Hello"));
    }

    #[test]
    fn an_empty_final_transcript_is_not_injected() {
        let mut h = Harness::new();
        let generation = h.generation();
        h.send(Event::HoldStarted);
        h.speak();
        h.send(Event::HoldEnded);

        h.send(Event::SttFinal {
            generation,
            text: "   ".into(),
        });
        assert_eq!(h.state(), State::Success);
        assert!(h.recorder().injected.is_empty());
    }

    // -- silence ------------------------------------------------------------

    #[test]
    fn a_recording_with_no_speech_skips_transcription_entirely() {
        let mut h = Harness::new();
        h.send(Event::HoldStarted);
        // No AudioLevel above the threshold at all.
        h.send(Event::AudioLevel(0.01));
        h.send(Event::HoldEnded);

        assert_eq!(
            h.state(),
            State::Idle,
            "silence must return straight to idle"
        );
        assert_eq!(h.scheduled_count(Timer::TranscribeTimeout), 0);
        assert!(h.recorder().injected.is_empty());
    }

    #[test]
    fn the_speech_threshold_matches_the_macos_build() {
        let mut h = Harness::new();
        h.send(Event::HoldStarted);
        // Just below the threshold does not count.
        h.send(Event::AudioLevel(SPEECH_LEVEL_THRESHOLD - 0.001));
        h.send(Event::HoldEnded);
        assert_eq!(h.state(), State::Idle);

        h.send(Event::HoldStarted);
        h.send(Event::AudioLevel(SPEECH_LEVEL_THRESHOLD));
        h.send(Event::HoldEnded);
        assert_eq!(
            h.state(),
            State::Transcribing,
            "exactly at the threshold counts as speech"
        );
    }

    // -- speculative capture ------------------------------------------------

    #[test]
    fn a_press_captures_speculatively_without_showing_any_ui() {
        let mut h = Harness::new();
        h.send(Event::PressBegan);

        assert_eq!(
            h.state(),
            State::Idle,
            "speculative capture must not leave idle"
        );
        assert_eq!(h.recorder().audio_starts, 1, "the mic opens at key-down");
        assert!(
            h.recorder().states.is_empty(),
            "no state change means no UI flash"
        );
    }

    #[test]
    fn an_abandoned_tap_discards_the_speculative_capture() {
        let mut h = Harness::new();
        h.send(Event::PressBegan);
        h.send(Event::PressAbandoned);

        assert_eq!(h.state(), State::Idle);
        assert_eq!(h.recorder().audio_stops, 1);
        assert_eq!(
            h.recorder().stt_cancels,
            1,
            "the speculative session must be cancelled, not ended"
        );
    }

    #[test]
    fn a_confirmed_hold_adopts_the_speculative_capture_without_restarting_it() {
        let mut h = Harness::new();
        let generation = h.generation();
        h.send(Event::PressBegan);
        h.speak(); // spoken during the confirmation window
        h.send(Event::HoldStarted);

        assert_eq!(h.state(), State::Recording);
        assert_eq!(
            h.recorder().audio_starts,
            1,
            "adoption must reuse the running capture"
        );
        assert_eq!(
            h.recorder().stt_begins,
            1,
            "adoption must reuse the running STT session"
        );

        h.send(Event::HoldEnded);
        assert_eq!(
            h.state(),
            State::Transcribing,
            "speech from the speculative window still counts"
        );
        h.send(Event::SttFinal {
            generation,
            text: "speculative works".into(),
        });
        assert_eq!(h.recorder().injected, vec!["Speculative works"]);
    }

    #[test]
    fn a_failed_speculative_capture_leaves_the_hold_path_free_to_retry() {
        let mut h = Harness::new();
        h.shared.borrow_mut().audio_start_error = Some("device busy".into());
        h.send(Event::PressBegan);
        assert_eq!(
            h.state(),
            State::Idle,
            "a failed speculative capture stays silent"
        );

        h.shared.borrow_mut().audio_start_error = None;
        h.send(Event::HoldStarted);
        assert_eq!(
            h.state(),
            State::Recording,
            "the confirmed hold retries via the normal path"
        );
    }

    // -- provider swap ------------------------------------------------------

    #[test]
    fn results_from_a_replaced_provider_are_ignored() {
        let mut h = Harness::new();
        let old_generation = h.generation();

        h.send(Event::HoldStarted);
        h.speak();
        h.send(Event::HoldEnded);

        let new_generation = h.machine.replace_provider(Box::new(MockStt {
            shared: Rc::clone(&h.shared),
            name: "Replacement".to_string(),
            timeout: Duration::from_secs(30),
        }));
        assert_ne!(old_generation, new_generation);
        assert_eq!(h.state(), State::Idle, "swapping mid-flight resets to idle");

        // The old provider finally answers. It must be ignored.
        h.send(Event::SttFinal {
            generation: old_generation,
            text: "stale".into(),
        });
        assert!(
            h.recorder().injected.is_empty(),
            "stale results must never be injected"
        );
        assert_eq!(h.state(), State::Idle);
    }

    #[test]
    fn errors_from_a_replaced_provider_do_not_surface() {
        let mut h = Harness::new();
        let old_generation = h.generation();
        h.machine.replace_provider(Box::new(MockStt {
            shared: Rc::clone(&h.shared),
            name: "Replacement".to_string(),
            timeout: Duration::from_secs(30),
        }));

        h.send(Event::SttError {
            generation: old_generation,
            message: "stale boom".into(),
        });
        assert_eq!(
            h.state(),
            State::Idle,
            "a stale error must not put the app in an error state"
        );
    }

    // -- recovery paths -----------------------------------------------------

    #[test]
    fn a_hold_during_transcribing_cancels_it_and_starts_a_new_recording() {
        let mut h = Harness::new();
        let generation = h.generation();
        h.send(Event::HoldStarted);
        h.speak();
        h.send(Event::HoldEnded);
        assert_eq!(h.state(), State::Transcribing);

        h.send(Event::HoldStarted);
        assert_eq!(
            h.state(),
            State::Recording,
            "the new press must not be swallowed"
        );
        assert_eq!(
            h.recorder().stt_cancels,
            1,
            "the in-flight session is cancelled"
        );

        h.speak();
        h.send(Event::HoldEnded);
        h.send(Event::SttFinal {
            generation,
            text: "take two".into(),
        });
        assert_eq!(h.recorder().injected, vec!["Take two"]);
    }

    #[test]
    fn a_hold_while_already_recording_recovers_the_orphaned_session() {
        let mut h = Harness::new();
        let generation = h.generation();
        h.send(Event::HoldStarted);
        assert_eq!(h.state(), State::Recording);

        // A release lost to a dropped input event: the machine is stuck in
        // Recording and the next press must recover rather than be ignored.
        h.send(Event::HoldStarted);
        assert_eq!(h.state(), State::Recording);

        h.speak();
        h.send(Event::HoldEnded);
        h.send(Event::SttFinal {
            generation,
            text: "recovered".into(),
        });
        assert_eq!(h.recorder().injected, vec!["Recovered"]);
    }

    #[test]
    fn a_hold_from_the_error_state_recovers_and_records() {
        let mut h = Harness::new();
        h.send(Event::HotkeyStartFailed("tap died".into()));
        assert!(h.state().is_error());

        h.send(Event::HoldStarted);
        assert_eq!(h.state(), State::Recording);
    }

    #[test]
    fn a_hold_during_the_success_flash_starts_a_new_recording() {
        let mut h = Harness::new();
        let generation = h.generation();
        h.send(Event::HoldStarted);
        h.speak();
        h.send(Event::HoldEnded);
        h.send(Event::SttFinal {
            generation,
            text: "first".into(),
        });
        assert_eq!(h.state(), State::Success);

        h.send(Event::HoldStarted);
        assert_eq!(h.state(), State::Recording);
    }

    #[test]
    fn a_capture_failure_surfaces_as_an_error_and_stops_everything() {
        let mut h = Harness::new();
        h.send(Event::HoldStarted);
        h.speak();

        h.send(Event::AudioError("input device disappeared".into()));
        assert_eq!(h.state(), State::Error("input device disappeared".into()));
        assert!(h.recorder().audio_stops >= 1);
    }

    #[test]
    fn a_failed_start_does_not_leak_one_shot_mode_into_the_next_hold() {
        let mut h = Harness::new();
        h.shared.borrow_mut().audio_start_error = Some("no device".into());
        h.send(Event::OneShotStartRequested);
        assert!(h.state().is_error());

        // The next hold must be an ordinary hold, not a silently one-shot
        // session that auto-stops on silence mid-hold.
        h.shared.borrow_mut().audio_start_error = None;
        h.send(Event::HoldStarted);
        assert_eq!(h.state(), State::Recording);
        assert_eq!(
            h.scheduled_count(Timer::SilenceWatchdog),
            0,
            "an ordinary hold must not arm the silence watchdog"
        );
    }

    // -- hands-free ---------------------------------------------------------

    #[test]
    fn a_double_press_starts_a_hands_free_session_that_a_press_stops() {
        let mut h = Harness::new();
        let generation = h.generation();

        h.send(Event::HandsFreeLockStarted);
        assert_eq!(h.state(), State::Recording);
        assert!(
            h.scheduled_count(Timer::SilenceWatchdog) > 0,
            "hands-free arms the watchdog"
        );

        h.speak();
        let outcome = h.send(Event::HandsFreeLockStopRequested);
        assert_eq!(h.state(), State::Transcribing);
        assert!(
            outcome.release_hands_free_lock,
            "the monitor's lock must be released"
        );

        h.send(Event::SttFinal {
            generation,
            text: "locked dictation".into(),
        });
        assert_eq!(h.recorder().injected, vec!["Locked dictation"]);
    }

    #[test]
    fn a_hands_free_lock_that_fails_to_start_releases_the_lock() {
        let mut h = Harness::new();
        h.shared.borrow_mut().audio_start_error = Some("no device".into());

        let outcome = h.send(Event::HandsFreeLockStarted);
        assert!(h.state().is_error());
        assert!(
            outcome.release_hands_free_lock,
            "otherwise the next press is eaten as a phantom stop"
        );
    }

    #[test]
    fn escape_cancels_a_hands_free_session_and_releases_the_lock() {
        let mut h = Harness::new();
        h.send(Event::HandsFreeLockStarted);
        h.speak();

        let outcome = h.send(Event::EscapePressed);
        assert_eq!(h.state(), State::Idle);
        assert!(outcome.release_hands_free_lock);
        assert_eq!(
            h.recorder().stt_cancels,
            1,
            "cancelled, so no transcript is produced"
        );
        assert!(h.recorder().injected.is_empty());
    }

    #[test]
    fn escape_cancels_a_held_recording_and_the_release_is_a_no_op() {
        let mut h = Harness::new();
        h.send(Event::HoldStarted);
        h.speak();
        h.send(Event::EscapePressed);
        assert_eq!(h.state(), State::Idle);

        h.send(Event::HoldEnded);
        assert_eq!(
            h.state(),
            State::Idle,
            "the key release after a cancel must do nothing"
        );
        assert!(h.recorder().injected.is_empty());
    }

    #[test]
    fn escape_while_idle_is_ignored() {
        let mut h = Harness::new();
        h.send(Event::EscapePressed);
        assert_eq!(h.state(), State::Idle);
        assert_eq!(h.recorder().stt_cancels, 0);
    }

    // -- watchdog and timeouts ----------------------------------------------

    #[test]
    fn the_silence_watchdog_auto_stops_a_hands_free_session() {
        let mut h = Harness::new();
        h.machine.set_silence_timeout(Duration::from_secs(2));
        h.send(Event::HandsFreeLockStarted);
        h.speak();

        // Not yet silent for long enough: the watchdog reschedules itself.
        h.clock.advance(Duration::from_millis(500));
        h.fire(Timer::SilenceWatchdog);
        assert_eq!(h.state(), State::Recording);

        h.clock.advance(Duration::from_millis(2_000));
        h.fire(Timer::SilenceWatchdog);
        assert_eq!(
            h.state(),
            State::Transcribing,
            "silence should end the session"
        );
    }

    #[test]
    fn the_watchdog_endpoints_faster_when_nothing_was_ever_said() {
        let mut h = Harness::new();
        h.machine.set_silence_timeout(Duration::from_secs(2));
        h.send(Event::HandsFreeLockStarted);
        // Never speaks.

        h.clock.advance(Duration::from_millis(1_500));
        h.fire(Timer::SilenceWatchdog);
        // 2s * 0.7 = 1.4s, so 1.5s of nothing already ends it — and with no
        // speech it returns straight to idle rather than transcribing silence.
        assert_eq!(h.state(), State::Idle);
    }

    #[test]
    fn the_watchdog_does_not_fire_for_an_ordinary_hold() {
        let mut h = Harness::new();
        h.send(Event::HoldStarted);
        assert_eq!(
            h.scheduled_count(Timer::SilenceWatchdog),
            0,
            "a held hotkey is stopped by the user, not by silence"
        );
    }

    #[test]
    fn a_transcription_that_never_returns_times_out_into_an_error() {
        let mut h = Harness::new();
        h.send(Event::HoldStarted);
        h.speak();
        h.send(Event::HoldEnded);
        assert_eq!(h.state(), State::Transcribing);

        h.fire(Timer::TranscribeTimeout);
        assert!(h.state().is_error());
        assert_eq!(
            h.recorder().stt_cancels,
            1,
            "the hung session must be cancelled or the next begin_session is refused"
        );
    }

    #[test]
    fn the_transcription_timeout_never_drops_below_the_floor() {
        let shared: Shared = Rc::new(RefCell::new(Recorder::default()));
        let clock = MockClock::new();
        let mut machine = DictationStateMachine::new(Dependencies {
            audio: Box::new(MockAudio(Rc::clone(&shared))),
            // A provider asking for an unreasonably short timeout.
            stt: Box::new(MockStt {
                shared: Rc::clone(&shared),
                name: "Impatient".into(),
                timeout: Duration::from_millis(1),
            }),
            injector: Box::new(MockInjector(Rc::clone(&shared))),
            scheduler: Box::new(MockScheduler(Rc::clone(&shared))),
            clock: Box::new(clock),
            pipeline: Pipeline::from_settings(&TextSettings::default()),
        });

        machine.handle(Event::HoldStarted);
        machine.handle(Event::AudioLevel(0.5));
        machine.handle(Event::HoldEnded);

        let delay = shared
            .borrow()
            .scheduled
            .iter()
            .rev()
            .find(|(t, _, _)| *t == Timer::TranscribeTimeout)
            .map(|(_, _, d)| *d)
            .expect("timeout scheduled");
        assert_eq!(delay, MIN_TRANSCRIBE_TIMEOUT);
    }

    #[test]
    fn a_cancelled_timer_that_still_fires_is_ignored() {
        let mut h = Harness::new();
        let generation = h.generation();
        h.send(Event::HoldStarted);
        h.speak();
        h.send(Event::HoldEnded);

        let stale_token = h
            .shared
            .borrow()
            .scheduled
            .iter()
            .rev()
            .find(|(t, _, _)| *t == Timer::TranscribeTimeout)
            .map(|(_, token, _)| *token)
            .unwrap();

        // The result arrives, which cancels the timeout...
        h.send(Event::SttFinal {
            generation,
            text: "done in time".into(),
        });
        assert_eq!(h.state(), State::Success);

        // ...but the executor had already queued the fire.
        h.send(Event::TimerFired {
            timer: Timer::TranscribeTimeout,
            token: stale_token,
        });
        assert_eq!(
            h.state(),
            State::Success,
            "a cancelled timeout must not clobber success"
        );
    }

    #[test]
    fn a_success_reset_that_arrives_after_a_new_recording_is_ignored() {
        let mut h = Harness::new();
        let generation = h.generation();
        h.send(Event::HoldStarted);
        h.speak();
        h.send(Event::HoldEnded);
        h.send(Event::SttFinal {
            generation,
            text: "first take".into(),
        });

        let stale_token = h
            .shared
            .borrow()
            .scheduled
            .iter()
            .rev()
            .find(|(t, _, _)| *t == Timer::SuccessReset)
            .map(|(_, token, _)| *token)
            .unwrap();

        h.send(Event::HoldStarted);
        assert_eq!(h.state(), State::Recording);

        h.send(Event::TimerFired {
            timer: Timer::SuccessReset,
            token: stale_token,
        });
        assert_eq!(
            h.state(),
            State::Recording,
            "a stale reset must not cancel the new recording"
        );
    }

    // -- lifecycle ----------------------------------------------------------

    #[test]
    fn deactivate_tears_down_an_active_recording() {
        let mut h = Harness::new();
        h.send(Event::HoldStarted);
        h.speak();

        h.machine.deactivate();
        assert_eq!(h.state(), State::Idle);
        assert!(h.recorder().audio_stops >= 1);
        assert_eq!(h.recorder().stt_ends, 1);
    }

    #[test]
    fn the_state_observer_sees_every_transition_in_order() {
        let mut h = Harness::new();
        let generation = h.generation();
        h.send(Event::HoldStarted);
        h.speak();
        h.send(Event::HoldEnded);
        h.send(Event::SttFinal {
            generation,
            text: "observed".into(),
        });
        h.fire(Timer::SuccessReset);

        assert_eq!(
            h.recorder().states,
            vec![
                State::Recording,
                State::Transcribing,
                State::Success,
                State::Idle
            ]
        );
    }

    #[test]
    fn one_shot_start_and_stop_from_the_tray_menu_round_trip() {
        let mut h = Harness::new();
        let generation = h.generation();

        h.send(Event::OneShotStartRequested);
        assert_eq!(h.state(), State::Recording);
        assert!(h.scheduled_count(Timer::SilenceWatchdog) > 0);

        h.speak();
        h.send(Event::OneShotStopRequested);
        assert_eq!(h.state(), State::Transcribing);

        h.send(Event::SttFinal {
            generation,
            text: "menu driven".into(),
        });
        assert_eq!(h.recorder().injected, vec!["Menu driven"]);
    }
}
