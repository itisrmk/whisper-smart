//! Application lifecycle and dependency wiring.
//!
//! Port of `AppDelegate.swift`. Everything the app owns is created here, the
//! state machine's collaborators are wired together, and every asynchronous
//! source — the keyboard hook, the audio callback, the STT workers, the timer
//! service — funnels into one [`Event`] channel that the egui frame drains.
//!
//! That single-consumer design is what keeps the port honest: the macOS build
//! relies on `DispatchQueue.main` to serialise all of this, and the
//! equivalent here is that the state machine is only ever touched from the UI
//! thread. Each sender wakes the frame through [`crate::bus::EventBus`], so
//! the app idles at zero frames per second and still reacts immediately.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use crossbeam_channel::{Receiver, Sender};

use crate::bus::{EventBus, Waker};
use crate::core::paths;
use crate::core::post_processing::Pipeline;
use crate::core::provider::ProviderKind;
use crate::core::settings::{Settings, SettingsStore};
use crate::core::state_machine::{
    Dependencies, DictationStateMachine, Event, State, SttControl, SystemClock,
};
use crate::core::transcript_log::{now_epoch_secs, TranscriptEntry, TranscriptLog};
use crate::platform::audio::{AudioCapture, PcmSink};
use crate::platform::diagnostics::{self, Capabilities};
use crate::platform::injector::Injector;
use crate::platform::scheduler::TimerService;
use crate::platform::{hotkey, notify};
use crate::stt::daemon::DaemonTranscriber;
use crate::stt::openai::OpenAiTranscriber;
use crate::stt::whisper_cpp::WhisperCppTranscriber;
use crate::stt::{StubTranscriber, Transcriber, WorkerProvider};
use crate::ui::overlay::Overlay;
use crate::ui::settings::{SettingsUi, Tab, UiCommand};
use crate::ui::tokens;
use crate::ui::tray::{Tray, TrayCommand};

/// How many queued events one frame drains before yielding, so a burst cannot
/// starve painting.
const EVENTS_PER_FRAME: usize = 64;

/// Runs the app. Returns the process exit code.
pub fn run() -> i32 {
    ensure_directories();
    init_logging();

    let store = SettingsStore::load();
    let waker = Waker::new();
    let (bus, events_rx) = EventBus::new(waker.clone());

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Whisper Smart")
            .with_inner_size([tokens::size::SETTINGS_WIDTH, tokens::size::SETTINGS_HEIGHT])
            .with_min_inner_size([480.0, 360.0])
            // The app lives in the tray; the settings window starts hidden
            // and is shown on demand.
            .with_visible(false)
            .with_icon(app_icon()),
        centered: true,
        ..Default::default()
    };

    let result = eframe::run_native(
        "Whisper Smart",
        options,
        Box::new(move |cc| {
            waker.install(cc.egui_ctx.clone());
            crate::ui::fonts::install(&cc.egui_ctx);
            tokens::apply_style(&cc.egui_ctx);
            Ok(Box::new(App::new(store, bus, events_rx)))
        }),
    );

    match result {
        Ok(()) => 0,
        Err(err) => {
            eprintln!("could not start the UI: {err}");
            1
        }
    }
}

/// Creates the directories the app writes to, so the first run does not fail
/// on a missing parent halfway through a download or a settings save.
fn ensure_directories() {
    for dir in [
        paths::config_dir(),
        paths::data_dir(),
        paths::cache_dir(),
        paths::state_dir(),
    ] {
        if let Err(err) = paths::ensure_dir(&dir) {
            eprintln!("could not create {}: {err}", dir.display());
        }
    }
}

/// Logs to a file: a GUI-subsystem process has no stderr anyone can see, so
/// the log file is the only record when something goes wrong in the field.
fn init_logging() {
    // RUST_LOG wins if set, so a user chasing a bug can turn everything up.
    let filter = std::env::var("RUST_LOG").unwrap_or_else(|_| "whisper_smart=info".to_string());
    let builder = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::new(filter))
        .with_target(false)
        .with_ansi(false);

    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(paths::log_file());
    match file {
        Ok(file) => builder.with_writer(Mutex::new(file)).init(),
        Err(_) => builder.with_writer(std::io::stderr).init(),
    }
}

/// The window/taskbar icon, decoded from the same PNG every build ships.
fn app_icon() -> egui::IconData {
    const LOGO: &[u8] = include_bytes!("../resources/whisper-smart-logo.png");
    match image::load_from_memory(LOGO) {
        Ok(decoded) => {
            let rgba = decoded.to_rgba8();
            let (width, height) = rgba.dimensions();
            egui::IconData {
                rgba: rgba.into_raw(),
                width,
                height,
            }
        }
        Err(_) => egui::IconData::default(),
    }
}

// The post-processed transcript behind the current success state, captured by
// the observer so the history writer can read it without threading it through
// the state machine's public API.
thread_local! {
    static LAST_TRANSCRIPT: RefCell<String> = const { RefCell::new(String::new()) };
}

pub struct App {
    machine: DictationStateMachine,
    store: SettingsStore,
    pcm_sink: PcmSink,
    bus: EventBus,
    events_rx: Receiver<Event>,

    hotkey: Option<hotkey::HotkeyHandle>,

    tray: Option<Tray>,
    tray_attempted: bool,
    tray_rx: Receiver<TrayCommand>,
    tray_tx: Sender<TrayCommand>,

    overlay: Rc<RefCell<Overlay>>,
    settings_ui: SettingsUi,
    settings_visible: bool,

    ui_rx: Receiver<UiCommand>,

    /// Set when the app cannot dictate at all; shown in the tray and settings.
    blocker: Option<String>,
    /// Name of the provider currently installed, for the history log.
    provider_name: String,

    /// True once Quit was chosen, so the close request is honoured instead of
    /// being converted into a hide.
    quitting: bool,
}

impl App {
    fn new(store: SettingsStore, bus: EventBus, events_rx: Receiver<Event>) -> Self {
        let settings = store.get();
        let pcm_sink: PcmSink = Arc::new(Mutex::new(None));

        let overlay = Rc::new(RefCell::new(Overlay::new(
            settings.overlay.style,
            settings.overlay.show_transcript,
        )));

        let audio = AudioCapture::new(bus.clone(), Arc::clone(&pcm_sink));
        let scheduler = TimerService::start(bus.clone());
        let injector = Injector::new(settings.injection.clone());

        // Start with the stub: the real provider is installed immediately
        // below through the same hot-swap path a settings change uses, so
        // there is only one code path to get wrong.
        let stub = WorkerProvider::spawn(
            Box::new(StubTranscriber),
            Arc::clone(&pcm_sink),
            bus.clone(),
            0,
        );

        let mut machine = DictationStateMachine::new(Dependencies {
            audio: Box::new(audio),
            stt: Box::new(stub),
            injector: Box::new(injector),
            scheduler: Box::new(scheduler),
            clock: Box::new(SystemClock),
            pipeline: Pipeline::from_settings(&settings.text),
        });
        machine.set_input_device(settings.general.input_device.clone());
        machine.set_silence_timeout(settings.silence_timeout());

        let (tray_tx, tray_rx) = crossbeam_channel::unbounded::<TrayCommand>();
        let (ui_tx, ui_rx) = crossbeam_channel::unbounded::<UiCommand>();
        let settings_ui = SettingsUi::new(ui_tx, &store);

        let mut app = App {
            machine,
            store,
            pcm_sink,
            bus,
            events_rx,
            hotkey: None,
            tray: None,
            tray_attempted: false,
            tray_rx,
            tray_tx,
            overlay,
            settings_ui,
            settings_visible: false,
            ui_rx,
            blocker: None,
            provider_name: String::new(),
            quitting: false,
        };

        app.install_provider();
        tracing::debug!("provider generation {}", app.machine.provider_generation());
        app.start_hotkey_monitor();
        app.wire_observers();
        app
    }

    // -----------------------------------------------------------------------
    // Observers
    // -----------------------------------------------------------------------

    /// Wires the state machine's callbacks to the overlay.
    ///
    /// The tray is deliberately *not* updated from here. These callbacks fire
    /// from inside `machine.handle`, at which point the app is already
    /// mutably borrowed. [`Self::after_event`] updates it once the borrow has
    /// been released.
    fn wire_observers(&mut self) {
        let overlay = Rc::clone(&self.overlay);
        self.machine.observers.on_state_change = Some(Box::new(move |state| {
            overlay.borrow_mut().set_state(state);
        }));

        let overlay = Rc::clone(&self.overlay);
        self.machine.observers.on_audio_level = Some(Box::new(move |level| {
            overlay.borrow_mut().set_level(level);
        }));

        let overlay = Rc::clone(&self.overlay);
        self.machine.observers.on_transcript = Some(Box::new(move |text| {
            overlay.borrow_mut().set_transcript(text);
            // Remember the post-processed text, which is what was actually
            // inserted, so the history records that rather than the engine's
            // raw output. Cleared to "" when a new recording starts.
            LAST_TRANSCRIPT.with(|cell| *cell.borrow_mut() = text.to_string());
        }));
    }

    // -----------------------------------------------------------------------
    // Provider
    // -----------------------------------------------------------------------

    /// Builds the provider for the current settings and hot-swaps it in.
    fn install_provider(&mut self) {
        let settings = self.store.get();
        let generation = self.machine.next_provider_generation();
        let (provider, name) = build_provider(
            &settings,
            Arc::clone(&self.pcm_sink),
            self.bus.clone(),
            generation,
        );

        let installed = self.machine.replace_provider(provider);
        debug_assert_eq!(installed, generation, "provider generation drifted");
        self.provider_name = name;
        self.refresh_blocker();
    }

    /// Recomputes whether the app can dictate at all.
    fn refresh_blocker(&mut self) {
        let settings = self.store.get();
        let mut blocker = None;

        let access = hotkey::check_input_access();
        if !access.is_available() {
            blocker = Some(access.message());
        } else {
            let caps = Capabilities::probe(&settings);
            let resolution = diagnostics::resolve_provider(
                settings.provider.kind,
                caps,
                settings.provider.cloud_fallback_enabled,
            );
            if !resolution.did_fall_back() {
                blocker = diagnostics::unavailable_reason(settings.provider.kind, caps);
            }
        }

        self.blocker = blocker;
        self.update_tray_status();
    }

    // -----------------------------------------------------------------------
    // Hotkey
    // -----------------------------------------------------------------------

    fn start_hotkey_monitor(&mut self) {
        if let Some(existing) = self.hotkey.take() {
            existing.stop();
        }

        let binding = self.store.get().hotkey;
        match hotkey::start(binding.clone(), self.bus.clone()) {
            Ok(handle) => {
                tracing::info!("hotkey bound to {}", binding.display_string());
                self.hotkey = Some(handle);
            }
            Err(err) => {
                tracing::error!("could not start the hotkey monitor: {err}");
                let _ = self.bus.send(Event::HotkeyStartFailed(err));
            }
        }
    }

    // -----------------------------------------------------------------------
    // Tray
    // -----------------------------------------------------------------------

    fn start_tray(&mut self) {
        self.tray_attempted = true;
        match Tray::new(
            self.provider_name.clone(),
            self.tray_tx.clone(),
            self.bus.waker(),
        ) {
            Ok(tray) => {
                self.tray = Some(tray);
                self.update_tray_status();
            }
            Err(err) => {
                // Dictation still works entirely from the hotkey.
                tracing::warn!("no system tray available ({err}); running without a tray icon");
            }
        }
    }

    fn update_tray_status(&mut self) {
        let name = self.provider_name.clone();
        let blocker = self.blocker.clone();
        if let Some(tray) = &mut self.tray {
            tray.set_status(name, blocker);
        }
    }

    // -----------------------------------------------------------------------
    // Commands
    // -----------------------------------------------------------------------

    fn handle_tray_command(&mut self, ctx: &egui::Context, command: TrayCommand) {
        match command {
            TrayCommand::Activate => {
                // Left click toggles dictation when it can work, and opens
                // Settings when it cannot — failing silently helps nobody.
                let usable = self.blocker.is_none() && *self.machine.state() != State::Transcribing;
                if usable {
                    self.handle_tray_command(ctx, TrayCommand::ToggleDictation);
                } else {
                    self.open_settings(ctx, Tab::General);
                }
            }
            TrayCommand::ToggleDictation => {
                let event = if *self.machine.state() == State::Recording {
                    Event::OneShotStopRequested
                } else {
                    Event::OneShotStartRequested
                };
                self.dispatch(event);
            }
            TrayCommand::OpenSettings => self.open_settings(ctx, Tab::General),
            TrayCommand::OpenHistory => self.open_settings(ctx, Tab::History),
            TrayCommand::Repair => {
                tracing::info!("re-running setup checks and restarting the hotkey listener");
                self.start_hotkey_monitor();
                self.install_provider();
            }
            TrayCommand::Quit => {
                self.shutdown();
                self.quitting = true;
                ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            }
        }
    }

    fn handle_ui_command(&mut self, command: UiCommand) {
        match command {
            UiCommand::ProviderChanged => self.install_provider(),
            UiCommand::HotkeyChanged => self.start_hotkey_monitor(),
            UiCommand::PreferencesChanged => self.apply_preferences(),
            UiCommand::Reinject(text) => {
                // Re-insert straight through the injector; this is not a
                // dictation, so the state machine is not involved.
                use crate::core::state_machine::TextInjecting;
                Injector::new(self.store.get().injection.clone()).inject(&text);
            }
        }
    }

    /// Re-reads settings that do not require rebuilding the provider.
    fn apply_preferences(&mut self) {
        let settings = self.store.get();
        self.machine
            .set_pipeline(Pipeline::from_settings(&settings.text));
        self.machine
            .set_input_device(settings.general.input_device.clone());
        self.machine.set_silence_timeout(settings.silence_timeout());

        let mut overlay = self.overlay.borrow_mut();
        overlay.apply_style(settings.overlay.style);
        overlay.set_show_transcript(settings.overlay.show_transcript);
    }

    fn open_settings(&mut self, ctx: &egui::Context, tab: Tab) {
        self.settings_ui.tab = tab;
        self.settings_ui.refresh(&self.store);
        self.settings_visible = true;
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(true));
        ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
    }

    fn hide_settings(&mut self, ctx: &egui::Context) {
        self.settings_visible = false;
        ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
    }

    fn dispatch(&mut self, event: Event) {
        let outcome = self.machine.handle(event);
        if outcome.release_hands_free_lock {
            if let Some(handle) = &self.hotkey {
                handle.end_hands_free_lock();
            }
        }
    }

    /// Called after each event so side effects that need `&mut self` (history,
    /// notifications, the tray) happen outside the state machine's own borrow.
    fn after_event(&mut self, previous: &State) {
        let current = self.machine.state().clone();
        if *previous == current {
            return;
        }

        match &current {
            State::Success => self.record_history(),
            State::Error(message) if self.store.get().general.notify_on_error => {
                notify::error("Dictation failed", message);
            }
            _ => {}
        }

        if let Some(tray) = &mut self.tray {
            tray.set_state(current);
        }
    }

    fn record_history(&mut self) {
        let settings = self.store.get();
        if !settings.history.enabled {
            return;
        }
        let text = LAST_TRANSCRIPT.with(|cell| cell.borrow().clone());
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return;
        }

        let log = TranscriptLog::new(paths::transcript_log_file(), settings.history.max_entries);
        let entry = TranscriptEntry {
            timestamp: now_epoch_secs(),
            text: trimmed.to_string(),
            provider: self.provider_name.clone(),
        };
        if let Err(err) = log.append(&entry) {
            tracing::error!("could not write the transcript history: {err}");
        }
    }

    fn shutdown(&mut self) {
        tracing::info!("shutting down");
        if let Some(handle) = self.hotkey.take() {
            handle.stop();
        }
        self.machine.deactivate();
        self.tray = None;
    }
}

impl eframe::App for App {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        tokens::BG.to_normalized_gamma_f32()
    }

    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // The tray needs the event loop running before it can be created, so
        // it is built on the first frame rather than in `new`.
        if !self.tray_attempted {
            self.start_tray();
        }

        // Closing the settings window hides it — the app lives in the tray —
        // unless Quit already ran.
        if ctx.input(|i| i.viewport().close_requested()) && !self.quitting {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            self.hide_settings(ctx);
        }

        // Drain in bounded batches so a burst cannot starve the frame.
        for _ in 0..EVENTS_PER_FRAME {
            let Ok(event) = self.events_rx.try_recv() else {
                break;
            };
            let previous = self.machine.state().clone();
            self.dispatch(event);
            self.after_event(&previous);
        }
        if !self.events_rx.is_empty() {
            ctx.request_repaint();
        }

        while let Ok(command) = self.tray_rx.try_recv() {
            self.handle_tray_command(ctx, command);
        }
        while let Ok(command) = self.ui_rx.try_recv() {
            self.handle_ui_command(command);
        }

        if self.settings_visible {
            self.settings_ui.show(ctx, &self.store);
        } else {
            // The root viewport still paints while hidden; keep it cheap.
            egui::CentralPanel::default()
                .frame(egui::Frame::new().fill(tokens::BG))
                .show(ctx, |_ui| {});
        }

        self.overlay.borrow_mut().show(ctx);
    }
}

// ---------------------------------------------------------------------------
// Provider construction
// ---------------------------------------------------------------------------

/// Builds the provider the settings ask for, applying the fallback rules.
///
/// A provider that cannot be constructed becomes a [`FailingTranscriber`]
/// rather than a panic or a silent no-op, so the reason reaches the user the
/// moment they try to dictate.
fn build_provider(
    settings: &Settings,
    pcm_sink: PcmSink,
    events: EventBus,
    generation: u64,
) -> (Box<dyn SttControl>, String) {
    let caps = Capabilities::probe(settings);
    let resolution = diagnostics::resolve_provider(
        settings.provider.kind,
        caps,
        settings.provider.cloud_fallback_enabled,
    );

    if let Some(reason) = &resolution.fallback_reason {
        tracing::warn!("{reason}");
    }

    let built: Result<Box<dyn Transcriber>, String> = match resolution.effective {
        ProviderKind::WhisperCpp => {
            WhisperCppTranscriber::new(settings).map(|t| Box::new(t) as Box<dyn Transcriber>)
        }
        ProviderKind::FasterWhisper | ProviderKind::Parakeet => {
            DaemonTranscriber::new(settings).map(|t| Box::new(t) as Box<dyn Transcriber>)
        }
        ProviderKind::OpenAiApi => {
            OpenAiTranscriber::new(settings).map(|t| Box::new(t) as Box<dyn Transcriber>)
        }
        ProviderKind::Stub => Ok(Box::new(StubTranscriber)),
    };

    let transcriber: Box<dyn Transcriber> = match built {
        Ok(transcriber) => transcriber,
        Err(message) => {
            tracing::error!(
                "could not start {}: {message}",
                resolution.effective.display_name()
            );
            Box::new(FailingTranscriber {
                name: resolution.effective.display_name().to_string(),
                message,
            })
        }
    };

    let name = transcriber.name();
    let provider = WorkerProvider::spawn(transcriber, pcm_sink, events, generation);
    (Box::new(provider), name)
}

/// Stands in for a provider that could not be constructed, reporting why.
struct FailingTranscriber {
    name: String,
    message: String,
}

impl Transcriber for FailingTranscriber {
    fn name(&self) -> String {
        self.name.clone()
    }

    fn transcribe(&mut self, _pcm: &[i16]) -> Result<String, String> {
        Err(self.message.clone())
    }
}
