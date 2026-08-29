//! Application lifecycle and dependency wiring.
//!
//! Port of `AppDelegate.swift`. Everything the app owns is created here, the
//! state machine's collaborators are wired together, and every asynchronous
//! source — the hotkey reader, the audio callback, the STT workers, the timer
//! service — funnels into one [`Event`] channel that the GTK main loop drains.
//!
//! That single-consumer design is what keeps the port honest: the macOS build
//! relies on `DispatchQueue.main` to serialise all of this, and the equivalent
//! here is that the state machine is only ever touched from the GTK thread.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use crossbeam_channel::{Receiver, Sender};
use gtk::glib;
use gtk::prelude::*;

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
use crate::ui::settings::{self as settings_ui, Tab, UiCommand};
use crate::ui::tokens;
use crate::ui::tray::{TrayCommand, WhisperTray};

/// How often the GTK loop drains the event channel.
///
/// Audio levels arrive every ~50 ms and key events are already debounced by the
/// 300 ms hold threshold, so 8 ms polling is imperceptible and costs nothing
/// measurable, while keeping all state changes on the main thread.
const EVENT_POLL: std::time::Duration = std::time::Duration::from_millis(8);

pub struct App {
    machine: DictationStateMachine,
    store: SettingsStore,
    pcm_sink: PcmSink,
    events_tx: Sender<Event>,
    hotkey: Option<hotkey::HotkeyHandle>,
    tray: Option<ksni::blocking::Handle<WhisperTray>>,
    overlay: Rc<RefCell<Overlay>>,
    /// Set when the app cannot dictate at all; shown in the tray and settings.
    blocker: Option<String>,
    /// Name of the provider currently installed, for the history log.
    provider_name: String,
    settings_window: Option<gtk::ApplicationWindow>,
}

/// Runs the app. Returns the process exit code.
pub fn run() -> i32 {
    ensure_directories();
    init_logging();

    let store = SettingsStore::load();

    let application = gtk::Application::builder()
        .application_id("com.whispersmart.desktop")
        // The app lives in the tray; it must not exit when the settings window
        // is closed, and must not require a window to stay alive.
        .flags(gtk::gio::ApplicationFlags::NON_UNIQUE)
        .build();

    let app_cell: Rc<RefCell<Option<App>>> = Rc::new(RefCell::new(None));

    {
        let store = store.clone();
        let app_cell = Rc::clone(&app_cell);
        application.connect_activate(move |application| {
            if app_cell.borrow().is_some() {
                // Activated again (e.g. a second launch); just show settings.
                if let Some(app) = app_cell.borrow_mut().as_mut() {
                    app.open_settings(application, Tab::General);
                }
                return;
            }
            // The brand font has to exist on disk before the stylesheet that
            // names it is parsed, or the first launch falls back a family.
            crate::ui::fonts::ensure_installed();
            load_stylesheet();
            let app = App::start(application, store.clone(), Rc::clone(&app_cell));
            *app_cell.borrow_mut() = Some(app);
        });
    }

    // Hold the application alive with no window, the way a tray app should.
    let _guard = application.hold();
    application.run_with_args::<&str>(&[]).into()
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

fn init_logging() {
    // RUST_LOG wins if set, so a user chasing a bug can turn everything up.
    let filter = std::env::var("RUST_LOG").unwrap_or_else(|_| "whisper_smart=info".to_string());
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::new(filter))
        .with_writer(std::io::stderr)
        .with_target(false)
        .init();
}

fn load_stylesheet() {
    let provider = gtk::CssProvider::new();
    provider.load_from_string(tokens::STYLESHEET);
    if let Some(display) = gtk::gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
}

impl App {
    fn start(
        application: &gtk::Application,
        store: SettingsStore,
        app_cell: Rc<RefCell<Option<App>>>,
    ) -> App {
        let settings = store.get();

        // One channel for every asynchronous source.
        let (events_tx, events_rx) = crossbeam_channel::unbounded::<Event>();
        let pcm_sink: PcmSink = Arc::new(Mutex::new(None));

        let overlay = Rc::new(RefCell::new(Overlay::new(
            application,
            settings.overlay.style,
            settings.overlay.show_transcript,
        )));

        let audio = AudioCapture::new(events_tx.clone(), Arc::clone(&pcm_sink));
        let scheduler = TimerService::start(events_tx.clone());
        let injector = Injector::new(settings.injection.clone());

        // Start with the stub: the real provider is installed immediately
        // below through the same hot-swap path a settings change uses, so
        // there is only one code path to get wrong.
        let stub = WorkerProvider::spawn(
            Box::new(StubTranscriber),
            Arc::clone(&pcm_sink),
            events_tx.clone(),
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

        let mut app = App {
            machine,
            store,
            pcm_sink,
            events_tx,
            hotkey: None,
            tray: None,
            overlay,
            blocker: None,
            provider_name: String::new(),
            settings_window: None,
        };

        app.install_provider();
        tracing::debug!("provider generation {}", app.machine.provider_generation());
        app.start_hotkey_monitor();
        app.start_tray(tray_tx);
        app.wire_observers();

        pump(application, app_cell, events_rx, tray_rx, ui_rx, ui_tx);
        app
    }

    // -----------------------------------------------------------------------
    // Observers
    // -----------------------------------------------------------------------

    /// Wires the state machine's callbacks to the overlay.
    ///
    /// The tray is deliberately *not* updated from here. These callbacks fire
    /// from inside `machine.handle`, at which point the app is already mutably
    /// borrowed, so reaching back for the tray handle could only ever fail.
    /// [`Self::after_event`] updates it once the borrow has been released.
    fn wire_observers(&mut self) {
        let overlay = Rc::clone(&self.overlay);
        self.machine.observers.on_state_change = Some(Box::new(move |state| {
            overlay.borrow_mut().set_state(state);
        }));

        let overlay = Rc::clone(&self.overlay);
        self.machine.observers.on_audio_level = Some(Box::new(move |level| {
            overlay.borrow().set_level(level);
        }));

        let overlay = Rc::clone(&self.overlay);
        self.machine.observers.on_transcript = Some(Box::new(move |text| {
            overlay.borrow().set_transcript(text);
            // Remember the post-processed text, which is what was actually
            // inserted, so the history records that rather than the engine's
            // raw output. Cleared to "" when a new recording starts.
            LAST_TRANSCRIPT.with(|cell| *cell.borrow_mut() = text.to_string());
        }));
    }

    fn update_tray_state(&self, state: State) {
        if let Some(tray) = &self.tray {
            tray.update(|tray| tray.set_state(state));
        }
    }

    fn update_tray_blocker(&self) {
        if let Some(tray) = &self.tray {
            let blocker = self.blocker.clone();
            let name = self.provider_name.clone();
            tray.update(move |tray| {
                tray.set_blocker(blocker);
                tray.set_provider_name(name);
            });
        }
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
            self.events_tx.clone(),
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

        if !hotkey::check_input_access().is_available() {
            blocker = Some(hotkey::check_input_access().message());
        } else if !crate::platform::injector::available_tools().any_strategy_available() {
            blocker = Some("No way to insert text: install wtype or wl-clipboard.".to_string());
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
        self.update_tray_blocker();
    }

    // -----------------------------------------------------------------------
    // Hotkey
    // -----------------------------------------------------------------------

    fn start_hotkey_monitor(&mut self) {
        if let Some(existing) = self.hotkey.take() {
            existing.stop();
        }

        let binding = self.store.get().hotkey;
        match hotkey::start(binding.clone(), self.events_tx.clone()) {
            Ok(handle) => {
                tracing::info!("hotkey bound to {}", binding.display_string());
                self.hotkey = Some(handle);
            }
            Err(err) => {
                tracing::error!("could not start the hotkey monitor: {err}");
                let _ = self.events_tx.send(Event::HotkeyStartFailed(err));
            }
        }
    }

    // -----------------------------------------------------------------------
    // Tray
    // -----------------------------------------------------------------------

    fn start_tray(&mut self, commands: Sender<TrayCommand>) {
        use ksni::blocking::TrayMethods;

        let tray = WhisperTray::new(self.provider_name.clone(), commands);
        match tray.spawn() {
            Ok(handle) => {
                self.tray = Some(handle);
                self.update_tray_blocker();
            }
            Err(err) => {
                // No StatusNotifierItem host (a bare compositor with no bar).
                // Dictation still works entirely from the hotkey.
                tracing::warn!("no system tray available ({err}); running without a tray icon");
            }
        }
    }

    // -----------------------------------------------------------------------
    // Commands
    // -----------------------------------------------------------------------

    fn handle_tray_command(&mut self, application: &gtk::Application, command: TrayCommand) {
        match command {
            TrayCommand::ToggleDictation => {
                let event = if *self.machine.state() == State::Recording {
                    Event::OneShotStopRequested
                } else {
                    Event::OneShotStartRequested
                };
                self.dispatch(event);
            }
            TrayCommand::OpenSettings => self.open_settings(application, Tab::General),
            TrayCommand::OpenHistory => self.open_settings(application, Tab::History),
            TrayCommand::Repair => {
                tracing::info!("re-running setup checks and restarting the hotkey listener");
                self.start_hotkey_monitor();
                self.install_provider();
            }
            TrayCommand::Quit => {
                self.shutdown();
                application.quit();
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

    fn open_settings(&mut self, application: &gtk::Application, tab: Tab) {
        if let Some(window) = &self.settings_window {
            if window.is_visible() {
                window.present();
                return;
            }
        }
        // The command channel is recreated per window; the pump picks it up
        // through the shared receiver installed at start-up.
        let window = settings_ui::present(
            application,
            self.store.clone(),
            UI_COMMANDS.with(|tx| tx.borrow().clone().expect("ui command channel installed")),
            tab,
        );
        self.settings_window = Some(window);
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
    /// notifications) happen outside the state machine's own borrow.
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

        self.update_tray_state(current);
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
        if let Some(tray) = self.tray.take() {
            tray.shutdown();
        }
    }
}

// The post-processed transcript behind the current success state, captured by
// the observer so the history writer can read it without threading it through
// the state machine's public API.
thread_local! {
    static LAST_TRANSCRIPT: RefCell<String> = const { RefCell::new(String::new()) };
    static UI_COMMANDS: RefCell<Option<Sender<UiCommand>>> = const { RefCell::new(None) };
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
    events: Sender<Event>,
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

// ---------------------------------------------------------------------------
// Event pump
// ---------------------------------------------------------------------------

/// Installs the main-loop callback that drains every channel.
fn pump(
    application: &gtk::Application,
    app_cell: Rc<RefCell<Option<App>>>,
    events: Receiver<Event>,
    tray_commands: Receiver<TrayCommand>,
    ui_commands: Receiver<UiCommand>,
    ui_tx: Sender<UiCommand>,
) {
    UI_COMMANDS.with(|cell| *cell.borrow_mut() = Some(ui_tx));

    let application = application.clone();
    glib::timeout_add_local(EVENT_POLL, move || {
        // Drain in bounded batches so a burst cannot starve the frame clock.
        for _ in 0..64 {
            let Ok(event) = events.try_recv() else { break };

            let mut guard = app_cell.borrow_mut();
            let Some(app) = guard.as_mut() else { continue };
            let previous = app.machine.state().clone();
            app.dispatch(event);
            app.after_event(&previous);
        }

        while let Ok(command) = tray_commands.try_recv() {
            let mut guard = app_cell.borrow_mut();
            if let Some(app) = guard.as_mut() {
                app.handle_tray_command(&application, command);
            }
        }

        while let Ok(command) = ui_commands.try_recv() {
            let mut guard = app_cell.borrow_mut();
            if let Some(app) = guard.as_mut() {
                app.handle_ui_command(command);
            }
        }

        glib::ControlFlow::Continue
    });
}
