//! Settings window.
//!
//! Port of `SettingsView.swift`, tab for tab: General, Hotkey, Dictionary,
//! Provider, History, plus the Setup tab the Linux build introduced — the
//! things that can be missing on Windows (the whisper.cpp binary, a Python
//! runtime, model weights) all need explaining and a button that fixes them,
//! whereas macOS surfaces the equivalent as system permission prompts.
//!
//! The window owns no application state. Every change is written straight to
//! the [`SettingsStore`] and, when it needs the running app to react, sent as
//! a [`UiCommand`] so the reaction happens on the main loop.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use crossbeam_channel::Sender;
use egui::{RichText, Ui};

use crate::core::hotkey_binding::HotkeyBinding;
use crate::core::model_catalog::{self, LocalModel, ModelEngine};
use crate::core::provider::ProviderKind;
use crate::core::settings::{
    ComputeDevice, Correction, InjectionMode, OverlayStyle, Settings, SettingsStore, WritingStyle,
};
use crate::core::transcript_log::{TranscriptEntry, TranscriptLog};
use crate::core::{credentials, paths};
use crate::platform::diagnostics::{self, Check, CheckStatus};
use crate::stt::runtime::{self, Progress};
use crate::ui::{tokens, widgets};

/// Something the settings window needs the running app to do.
#[derive(Debug, Clone)]
pub enum UiCommand {
    /// The provider or model changed; rebuild the STT provider.
    ProviderChanged,
    /// The hotkey binding changed; rebind the listener.
    HotkeyChanged,
    /// Overlay, injection, or text settings changed; re-read them.
    PreferencesChanged,
    /// Insert a transcript from the history list.
    Reinject(String),
}

/// The pages, in sidebar order. Mirrors `SettingsTab` in
/// `app/UI/SettingsView.swift`, including the subtitles and ledes, so the
/// builds read as the same product.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tab {
    General,
    Hotkey,
    Dictionary,
    Provider,
    History,
    Setup,
}

impl Tab {
    pub fn all() -> [Tab; 6] {
        [
            Tab::General,
            Tab::Hotkey,
            Tab::Dictionary,
            Tab::Provider,
            Tab::History,
            Tab::Setup,
        ]
    }

    fn label(self) -> &'static str {
        match self {
            Tab::General => "General",
            Tab::Hotkey => "Hotkey",
            Tab::Dictionary => "Dictionary & Style",
            Tab::Provider => "Provider",
            Tab::History => "History",
            Tab::Setup => "Setup",
        }
    }

    fn subtitle(self) -> &'static str {
        match self {
            Tab::General => "Startup, audio & overlay",
            Tab::Hotkey => "Global shortcut controls",
            Tab::Dictionary => "Styles, snippets & corrections",
            Tab::Provider => "Models & cloud setup",
            Tab::History => "Transcript metrics & logs",
            Tab::Setup => "Runtimes & dependencies",
        }
    }

    /// The lede under the page title.
    fn lede(self) -> &'static str {
        match self {
            Tab::General => "Startup, audio, and your everyday dictation workflow.",
            Tab::Hotkey => {
                "One global shortcut for hands-free dictation, anywhere on your desktop."
            }
            Tab::Dictionary => {
                "Writing styles, voice commands, and corrections — tuned to how you write."
            }
            Tab::Provider => {
                "Choose where transcription runs — right on your machine, or in the cloud."
            }
            Tab::History => "Everything you've dictated, with timing so you can spot what to tune.",
            Tab::Setup => "What Whisper Smart needs from your system, and how to provide it.",
        }
    }

    fn icon(self) -> &'static str {
        match self {
            Tab::General => "⚙",
            Tab::Hotkey => "⌨",
            Tab::Dictionary => "✏",
            Tab::Provider => "☁",
            Tab::History => "☰",
            Tab::Setup => "🔧",
        }
    }
}

/// A one-click preset: what most people actually want to choose between.
///
/// The macOS Provider page offers Light / Balanced / Best / Cloud rather than
/// an engine matrix, and that framing carries over. Every local tier is
/// whisper.cpp, the path that needs no Python runtime — the engines that do
/// are still available under Advanced.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Tier {
    Light,
    Balanced,
    Best,
    Cloud,
}

impl Tier {
    fn all() -> [Tier; 4] {
        [Tier::Light, Tier::Balanced, Tier::Best, Tier::Cloud]
    }

    fn badge(self) -> &'static str {
        match self {
            Tier::Light => "LGT",
            Tier::Balanced => "BAL",
            Tier::Best => "MAX",
            Tier::Cloud => "API",
        }
    }

    fn title(self) -> &'static str {
        match self {
            Tier::Light => "Light",
            Tier::Balanced => "Balanced",
            Tier::Best => "Best",
            Tier::Cloud => "Cloud",
        }
    }

    fn description(self) -> &'static str {
        match self {
            Tier::Light => "Whisper Base · fastest, lowest accuracy",
            Tier::Balanced => "Whisper Small · a good middle ground",
            Tier::Best => "Whisper Large-v3 Turbo · highest local accuracy",
            Tier::Cloud => "OpenAI Whisper API · audio leaves your machine",
        }
    }

    fn kind(self) -> ProviderKind {
        match self {
            Tier::Light | Tier::Balanced | Tier::Best => ProviderKind::WhisperCpp,
            Tier::Cloud => ProviderKind::OpenAiApi,
        }
    }

    /// The model a local tier resolves to.
    fn model(self) -> Option<LocalModel> {
        match self {
            Tier::Light => Some(model_catalog::CPP_BASE),
            Tier::Balanced => Some(model_catalog::CPP_SMALL),
            Tier::Best => Some(model_catalog::CPP_LARGE_V3_TURBO),
            Tier::Cloud => None,
        }
    }

    /// Whether the current settings are exactly this tier.
    fn matches(self, settings: &Settings) -> bool {
        if settings.provider.kind != self.kind() {
            return false;
        }
        match self.model() {
            Some(model) => settings.provider.whisper_cpp_model == model.id,
            None => true,
        }
    }
}

/// A background install/download the UI is watching.
struct Task {
    running: bool,
    status: String,
    slot: Arc<Mutex<Vec<Progress>>>,
}

impl Task {
    fn idle() -> Self {
        Self {
            running: false,
            status: String::new(),
            slot: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Drains progress updates into the status line. Returns true when the
    /// task finished (successfully or not) this frame.
    fn poll(&mut self) -> bool {
        if !self.running {
            return false;
        }
        let updates: Vec<Progress> = self
            .slot
            .lock()
            .map(|mut q| std::mem::take(&mut *q))
            .unwrap_or_default();
        let mut finished = false;
        for update in updates {
            match update {
                Progress::Step(text) => self.status = text,
                Progress::Fraction(fraction) => {
                    self.status = format!("Downloading… {}%", (fraction * 100.0).round() as u32);
                }
                Progress::Done => {
                    self.status = "Done.".to_string();
                    self.running = false;
                    finished = true;
                }
                Progress::Failed(err) => {
                    self.status = err;
                    self.running = false;
                    finished = true;
                }
            }
        }
        finished
    }

    /// Starts `work` on a worker thread, reporting through the slot. The
    /// worker pings the UI so progress shows up without polling.
    fn start<F>(&mut self, ctx: &egui::Context, work: F)
    where
        F: FnOnce(&runtime::ProgressSink) -> Result<(), String> + Send + 'static,
    {
        self.running = true;
        self.status = "Starting…".to_string();
        let slot = Arc::clone(&self.slot);
        let ctx = ctx.clone();
        std::thread::Builder::new()
            .name("settings-task".to_string())
            .spawn(move || {
                let report_slot = Arc::clone(&slot);
                let report_ctx = ctx.clone();
                let sink: runtime::ProgressSink = Box::new(move |update| {
                    if let Ok(mut queue) = report_slot.lock() {
                        queue.push(update);
                    }
                    report_ctx.request_repaint();
                });
                let result = work(&sink);
                if let Ok(mut queue) = slot.lock() {
                    match result {
                        Ok(()) => queue.push(Progress::Done),
                        Err(err) => queue.push(Progress::Failed(err)),
                    }
                }
                ctx.request_repaint();
            })
            .ok();
    }
}

/// A hotkey recording in flight.
struct Recorder {
    captured: Arc<Mutex<Option<HotkeyBinding>>>,
    failed: Arc<Mutex<Option<String>>>,
    deadline: Instant,
}

pub struct SettingsUi {
    pub tab: Tab,
    commands: Sender<UiCommand>,

    devices: Vec<String>,
    recorder: Option<Recorder>,
    recorder_status: String,

    // Buffered text fields, synced from the store on refresh.
    language: String,
    base_url: String,
    openai_model: String,
    key_entry: String,
    key_status: String,
    correction_from: String,
    correction_to: String,

    downloads: HashMap<String, Task>,
    runtime_task: Task,
    whisper_task: Task,

    history: Option<Vec<TranscriptEntry>>,
    checks: Option<Vec<Check>>,
    logo: Option<egui::TextureHandle>,
}

impl SettingsUi {
    pub fn new(commands: Sender<UiCommand>, store: &SettingsStore) -> Self {
        let mut ui = Self {
            tab: Tab::General,
            commands,
            devices: Vec::new(),
            recorder: None,
            recorder_status: String::new(),
            language: String::new(),
            base_url: String::new(),
            openai_model: String::new(),
            key_entry: String::new(),
            key_status: String::new(),
            correction_from: String::new(),
            correction_to: String::new(),
            downloads: HashMap::new(),
            runtime_task: Task::idle(),
            whisper_task: Task::idle(),
            history: None,
            checks: None,
            logo: None,
        };
        ui.refresh(store);
        ui
    }

    /// Re-reads everything the window caches. Called when it is (re)opened.
    pub fn refresh(&mut self, store: &SettingsStore) {
        let settings = store.get();
        self.devices = crate::platform::audio::list_input_devices();
        self.language = settings.provider.language.clone();
        self.base_url = settings.provider.openai.base_url.clone();
        self.openai_model = settings.provider.openai.model.clone();
        self.history = None;
        self.checks = None;
    }

    fn notify(&self, command: UiCommand) {
        if self.commands.send(command).is_err() {
            tracing::warn!("settings change not applied; the app is shutting down");
        }
    }

    /// Renders the whole window into the root viewport.
    pub fn show(&mut self, ctx: &egui::Context, store: &SettingsStore) {
        self.poll_recorder(store, ctx);

        let selected_tab = self.tab;
        egui::SidePanel::left("ws-sidebar")
            .exact_width(tokens::size::SIDEBAR_WIDTH)
            .resizable(false)
            .frame(
                egui::Frame::new()
                    .fill(tokens::SIDEBAR)
                    .stroke(egui::Stroke::new(1.0_f32, tokens::border())),
            )
            .show(ctx, |ui| {
                self.brand_row(ui, ctx);
                for tab in Tab::all() {
                    if nav_item(ui, tab, tab == selected_tab) {
                        self.tab = tab;
                        // Cached pages reload when revisited.
                        self.history = None;
                    }
                }
                ui.with_layout(egui::Layout::bottom_up(egui::Align::LEFT), |ui| {
                    ui.add_space(tokens::spacing::SM);
                    egui::Frame::new()
                        .fill(tokens::CHROME)
                        .stroke(egui::Stroke::new(1.0_f32, tokens::border()))
                        .inner_margin(egui::Margin::symmetric(10, 5))
                        .show(ui, |ui| {
                            ui.label(
                                RichText::new(format!(
                                    "Windows native · v{}",
                                    env!("CARGO_PKG_VERSION")
                                ))
                                .color(tokens::MUTED)
                                .size(11.0),
                            );
                        });
                });
            });

        egui::CentralPanel::default()
            .frame(egui::Frame::new().fill(tokens::BG))
            .show(ctx, |ui| {
                egui::ScrollArea::vertical()
                    .auto_shrink([false; 2])
                    .show(ui, |ui| {
                        egui::Frame::new()
                            .inner_margin(egui::Margin {
                                left: tokens::spacing::XXXL as i8,
                                right: tokens::spacing::XXXL as i8,
                                top: tokens::spacing::XXL as i8,
                                bottom: tokens::spacing::XXXL as i8,
                            })
                            .show(ui, |ui| {
                                ui.label(
                                    RichText::new(self.tab.label())
                                        .color(tokens::TEXT)
                                        .size(30.0)
                                        .strong(),
                                );
                                ui.label(
                                    RichText::new(self.tab.lede())
                                        .color(tokens::MUTED)
                                        .size(13.0),
                                );
                                ui.add_space(tokens::spacing::XL);

                                match self.tab {
                                    Tab::General => self.general_page(ui, store),
                                    Tab::Hotkey => self.hotkey_page(ui, store),
                                    Tab::Dictionary => self.dictionary_page(ui, store),
                                    Tab::Provider => self.provider_page(ui, store),
                                    Tab::History => self.history_page(ui, store),
                                    Tab::Setup => self.setup_page(ui, store),
                                }
                            });
                    });
            });
    }

    /// Logo, product name, and "Preferences", matching the macOS sidebar
    /// header. The logo is the same PNG every build ships.
    fn brand_row(&mut self, ui: &mut Ui, ctx: &egui::Context) {
        ui.add_space(tokens::spacing::LG);
        ui.horizontal(|ui| {
            ui.add_space(tokens::spacing::MD);
            if self.logo.is_none() {
                self.logo = load_logo(ctx);
            }
            if let Some(logo) = &self.logo {
                ui.add(egui::Image::new(logo).fit_to_exact_size(egui::vec2(40.0, 40.0)));
            }
            ui.vertical(|ui| {
                ui.label(
                    RichText::new("Whisper Smart")
                        .color(tokens::TEXT)
                        .size(15.0)
                        .strong(),
                );
                ui.label(RichText::new("Preferences").color(tokens::MUTED).size(11.0));
            });
        });
        ui.add_space(tokens::spacing::LG);
        widgets::separator(ui);
    }

    // -----------------------------------------------------------------------
    // General
    // -----------------------------------------------------------------------

    fn general_page(&mut self, ui: &mut Ui, store: &SettingsStore) {
        let settings = store.get();

        widgets::card(ui, "🎙", "Microphone", |ui| {
            let mut devices = vec!["System default".to_string()];
            devices.extend(self.devices.clone());
            let selected = devices
                .iter()
                .position(|d| *d == settings.general.input_device)
                .unwrap_or(0);
            widgets::row(
                ui,
                "Input device",
                Some("Which microphone to record from."),
                |ui| {
                    if let Some(index) = widgets::dropdown(ui, "input-device", &devices, selected) {
                        // Index 0 is the synthetic "System default", stored as "".
                        let name = if index == 0 {
                            String::new()
                        } else {
                            devices[index].clone()
                        };
                        store.update(|s| s.general.input_device = name);
                        self.notify(UiCommand::PreferencesChanged);
                    }
                },
            );
            widgets::separator(ui);

            widgets::row(
                ui,
                "Silence timeout",
                Some(
                    "How long a hands-free recording waits in silence before it stops. \
                     Does not apply while the hotkey is held.",
                ),
                |ui| {
                    let mut value = settings.general.silence_timeout_seconds;
                    if ui
                        .add(
                            egui::DragValue::new(&mut value)
                                .range(0.5..=30.0)
                                .speed(0.1)
                                .suffix(" s"),
                        )
                        .changed()
                    {
                        store.update(|s| s.general.silence_timeout_seconds = value);
                        self.notify(UiCommand::PreferencesChanged);
                    }
                },
            );
        });
        ui.add_space(tokens::spacing::LG);

        widgets::card(ui, "🖥", "Overlay", |ui| {
            let styles = [
                OverlayStyle::Bubble,
                OverlayStyle::TopBar,
                OverlayStyle::None,
            ];
            let labels: Vec<String> = styles
                .iter()
                .map(|s| s.display_name().to_string())
                .collect();
            let index = styles
                .iter()
                .position(|s| *s == settings.overlay.style)
                .unwrap_or(0);
            widgets::row(ui, "Style", Some("Shown while recording."), |ui| {
                if let Some(index) = widgets::dropdown(ui, "overlay-style", &labels, index) {
                    store.update(|s| s.overlay.style = styles[index]);
                    self.notify(UiCommand::PreferencesChanged);
                }
            });
            widgets::separator(ui);

            widgets::row(
                ui,
                "Show transcript",
                Some("Preview the text in the overlay."),
                |ui| {
                    let mut on = settings.overlay.show_transcript;
                    if widgets::toggle(ui, &mut on).changed() {
                        store.update(|s| s.overlay.show_transcript = on);
                        self.notify(UiCommand::PreferencesChanged);
                    }
                },
            );
        });
        ui.add_space(tokens::spacing::LG);

        widgets::card(ui, "📋", "Text insertion", |ui| {
            let modes = [
                InjectionMode::Smart,
                InjectionMode::TypeOnly,
                InjectionMode::PasteOnly,
            ];
            let labels: Vec<String> = modes.iter().map(|m| m.display_name().to_string()).collect();
            let index = modes
                .iter()
                .position(|m| *m == settings.injection.mode)
                .unwrap_or(0);
            widgets::row(
                ui,
                "Mode",
                Some(
                    "Smart types the text as keystrokes, then falls back to a clipboard \
                     paste when typing is unsafe (multi-line text).",
                ),
                |ui| {
                    if let Some(index) = widgets::dropdown(ui, "injection-mode", &labels, index) {
                        store.update(|s| s.injection.mode = modes[index]);
                        self.notify(UiCommand::PreferencesChanged);
                    }
                },
            );
            widgets::separator(ui);

            widgets::row(
                ui,
                "Restore clipboard",
                Some("Put your previous clipboard contents back after a paste-based insertion."),
                |ui| {
                    let mut on = settings.injection.restore_clipboard;
                    if widgets::toggle(ui, &mut on).changed() {
                        store.update(|s| s.injection.restore_clipboard = on);
                        self.notify(UiCommand::PreferencesChanged);
                    }
                },
            );
        });
        ui.add_space(tokens::spacing::LG);

        widgets::card(ui, "🔔", "Feedback", |ui| {
            widgets::row(
                ui,
                "Notify on failure",
                Some("Show a notification when a dictation fails."),
                |ui| {
                    let mut on = settings.general.notify_on_error;
                    if widgets::toggle(ui, &mut on).changed() {
                        store.update(|s| s.general.notify_on_error = on);
                        self.notify(UiCommand::PreferencesChanged);
                    }
                },
            );
        });
    }

    // -----------------------------------------------------------------------
    // Hotkey
    // -----------------------------------------------------------------------

    fn hotkey_page(&mut self, ui: &mut Ui, store: &SettingsStore) {
        let settings = store.get();

        widgets::card(ui, "⌨", "Dictation hotkey", |ui| {
            widgets::note(
                ui,
                "Hold the key to dictate and release to insert. Press it twice quickly to \
                 start a hands-free recording that keeps going until you press it again or \
                 stop speaking. Press Esc during a recording to discard it.",
            );

            let presets = HotkeyBinding::presets();
            let mut labels: Vec<String> =
                presets.iter().map(HotkeyBinding::display_string).collect();
            // A custom recorded binding is shown as an extra entry so the
            // dropdown never silently misrepresents what is actually bound.
            let selected = match presets.iter().position(|p| *p == settings.hotkey) {
                Some(index) => index,
                None => {
                    labels.push(format!("{} (custom)", settings.hotkey.display_string()));
                    labels.len() - 1
                }
            };
            widgets::row(ui, "Binding", None, |ui| {
                if let Some(index) = widgets::dropdown(ui, "hotkey-binding", &labels, selected) {
                    if let Some(binding) = presets.get(index).cloned() {
                        store.update(|s| s.hotkey = binding);
                        self.notify(UiCommand::HotkeyChanged);
                    }
                }
            });

            if !settings.hotkey.is_modifier_only() {
                widgets::note(
                    ui,
                    "This binding includes a regular key, so holding it will autorepeat that \
                     key into whatever has focus. A bare modifier avoids that.",
                );
            }
            ui.add_space(tokens::spacing::SM);

            let recording = self.recorder.is_some();
            ui.horizontal(|ui| {
                let label = if recording {
                    "Press a key…"
                } else {
                    "Record a new hotkey"
                };
                if ui
                    .add_enabled(!recording, egui::Button::new(label).corner_radius(0.0))
                    .clicked()
                {
                    let captured: Arc<Mutex<Option<HotkeyBinding>>> = Arc::new(Mutex::new(None));
                    let failed: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
                    crate::platform::hotkey::record_next_binding(
                        Arc::clone(&captured),
                        Arc::clone(&failed),
                    );
                    self.recorder = Some(Recorder {
                        captured,
                        failed,
                        deadline: Instant::now() + std::time::Duration::from_secs(10),
                    });
                    self.recorder_status =
                        "Press and hold the key you want to use for dictation.".to_string();
                }
            });
            widgets::status_line(ui, &self.recorder_status.clone());
        });
        ui.add_space(tokens::spacing::LG);

        widgets::card(ui, "💡", "Choosing a key", |ui| {
            widgets::note(
                ui,
                "A modifier key that is not otherwise used works best, because holding it \
                 alone does nothing in other applications. Right Ctrl is a good choice on \
                 most keyboards. Avoid the Win key, which the shell owns, and note that \
                 Right Alt is AltGr on many international layouts.",
            );
        });
    }

    /// Polls a hotkey recording in flight; runs even while other tabs show.
    fn poll_recorder(&mut self, store: &SettingsStore, ctx: &egui::Context) {
        let Some(recorder) = &self.recorder else {
            return;
        };

        if let Some(error) = recorder.failed.lock().ok().and_then(|mut f| f.take()) {
            self.recorder_status = error;
            self.recorder = None;
            return;
        }
        if let Some(binding) = recorder.captured.lock().ok().and_then(|mut c| c.take()) {
            self.recorder_status = format!("Bound to {}.", binding.display_string());
            store.update(|s| s.hotkey = binding);
            self.notify(UiCommand::HotkeyChanged);
            self.recorder = None;
            return;
        }
        if Instant::now() > recorder.deadline {
            self.recorder_status = "No key was pressed; the hotkey is unchanged.".to_string();
            self.recorder = None;
            return;
        }
        // Still waiting: keep frames coming so the capture lands promptly.
        ctx.request_repaint_after(std::time::Duration::from_millis(100));
    }

    // -----------------------------------------------------------------------
    // Dictionary & Style
    // -----------------------------------------------------------------------

    fn dictionary_page(&mut self, ui: &mut Ui, store: &SettingsStore) {
        let settings = store.get();

        widgets::card(ui, "✏", "Clean-up", |ui| {
            let styles = [
                WritingStyle::Neutral,
                WritingStyle::Formal,
                WritingStyle::Casual,
                WritingStyle::Concise,
                WritingStyle::Developer,
            ];
            let labels: Vec<String> = styles
                .iter()
                .map(|s| s.display_name().to_string())
                .collect();
            let index = styles
                .iter()
                .position(|s| *s == settings.text.writing_style)
                .unwrap_or(0);
            widgets::row(ui, "Writing style", None, |ui| {
                if let Some(index) = widgets::dropdown(ui, "writing-style", &labels, index) {
                    store.update(|s| s.text.writing_style = styles[index]);
                    self.notify(UiCommand::PreferencesChanged);
                }
            });

            // (label, help text, how to apply it, current value)
            type Toggle = (&'static str, &'static str, fn(&mut Settings, bool), bool);
            let toggles: [Toggle; 3] = [
                (
                    "Trim filler words",
                    "Remove a leading \"um\" or \"uh\" from the finished transcript.",
                    |s, v| s.text.trim_filler_words = v,
                    settings.text.trim_filler_words,
                ),
                (
                    "Normalise spacing",
                    "Collapse double spaces and fix spacing around punctuation.",
                    |s, v| s.text.normalize_spacing = v,
                    settings.text.normalize_spacing,
                ),
                (
                    "Spoken punctuation",
                    "Turn \"comma\", \"period\", and \"new line\" into the characters they name.",
                    |s, v| s.text.voice_command_formatting = v,
                    settings.text.voice_command_formatting,
                ),
            ];
            for (label, help, apply, initial) in toggles {
                widgets::separator(ui);
                widgets::row(ui, label, Some(help), |ui| {
                    let mut on = initial;
                    if widgets::toggle(ui, &mut on).changed() {
                        store.update(|s| apply(s, on));
                        self.notify(UiCommand::PreferencesChanged);
                    }
                });
            }
        });
        ui.add_space(tokens::spacing::LG);

        widgets::card(ui, "🔁", "Corrections", |ui| {
            widgets::note(
                ui,
                "Replace words the engine reliably mishears. Matching ignores case and only \
                 applies to whole words.",
            );
            ui.add_space(tokens::spacing::SM);

            let mut remove: Option<usize> = None;
            for (index, correction) in settings.text.corrections.iter().enumerate() {
                ui.horizontal(|ui| {
                    ui.label(
                        RichText::new(format!("{} → {}", correction.from, correction.to))
                            .color(tokens::TEXT)
                            .size(12.0),
                    );
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if widgets::ghost_button(ui, "Remove").clicked() {
                            remove = Some(index);
                        }
                    });
                });
            }
            if let Some(index) = remove {
                store.update(|s| {
                    if index < s.text.corrections.len() {
                        s.text.corrections.remove(index);
                    }
                });
                self.notify(UiCommand::PreferencesChanged);
            }

            ui.add_space(tokens::spacing::SM);
            ui.horizontal(|ui| {
                ui.add(
                    egui::TextEdit::singleline(&mut self.correction_from)
                        .hint_text("heard as")
                        .desired_width(180.0),
                );
                ui.add(
                    egui::TextEdit::singleline(&mut self.correction_to)
                        .hint_text("replace with")
                        .desired_width(180.0),
                );
                if widgets::button(ui, "Add").clicked() {
                    let from = self.correction_from.trim().to_string();
                    let to = self.correction_to.clone();
                    if !from.is_empty() {
                        store.update(|s| s.text.corrections.push(Correction { from, to }));
                        self.correction_from.clear();
                        self.correction_to.clear();
                        self.notify(UiCommand::PreferencesChanged);
                    }
                }
            });
        });
    }

    // -----------------------------------------------------------------------
    // Provider
    // -----------------------------------------------------------------------

    fn provider_page(&mut self, ui: &mut Ui, store: &SettingsStore) {
        self.tier_card(ui, store);
        ui.add_space(tokens::spacing::LG);
        self.whisper_cpp_card(ui, store);
        ui.add_space(tokens::spacing::LG);
        self.cloud_card(ui, store);
        ui.add_space(tokens::spacing::LG);
        self.advanced_card(ui, store);
    }

    /// The tier picker: one card, four rows, no engine jargon.
    fn tier_card(&mut self, ui: &mut Ui, store: &SettingsStore) {
        let settings = store.get();
        let ctx = ui.ctx().clone();

        widgets::card(ui, "🔊", "Model", |ui| {
            widgets::note(
                ui,
                "Pick a model and Whisper Smart downloads it on request. Nothing is installed \
                 until you ask, and nothing leaves your machine unless you choose Cloud.",
            );
            ui.add_space(tokens::spacing::SM);

            for tier in Tier::all() {
                let selected = tier.matches(&settings);

                // Everything the row shows is resolved up front, and what the
                // user clicked is collected into flags acted on after the
                // frame — the closure then borrows nothing it can fight over.
                let model = tier.model();
                let (task_running, task_status) = match &model {
                    Some(model) => {
                        let task = self
                            .downloads
                            .entry(model.id.to_string())
                            .or_insert_with(Task::idle);
                        if task.poll() {
                            self.notify(UiCommand::ProviderChanged);
                        }
                        let task = self.downloads.get(model.id).expect("just inserted");
                        (task.running, task.status.clone())
                    }
                    None => (false, String::new()),
                };
                let status = match &model {
                    Some(model) if task_running => task_status,
                    Some(model) if diagnostics::is_model_installed(model) => {
                        format!("Downloaded · {}", model.approx_size_label)
                    }
                    Some(model) => format!("Not downloaded · {}", model.approx_size_label),
                    None if credentials::has_openai_key() => "API key saved".to_string(),
                    None => "Needs an API key — add one below".to_string(),
                };
                let offer_download = model
                    .as_ref()
                    .is_some_and(|m| !task_running && !diagnostics::is_model_installed(m));

                let mut clicked_select = false;
                let mut clicked_download = false;

                egui::Frame::new()
                    .fill(if selected {
                        tokens::active()
                    } else {
                        tokens::PANEL2
                    })
                    .stroke(egui::Stroke::new(
                        1.0_f32,
                        if selected {
                            tokens::ACCENT
                        } else {
                            tokens::border()
                        },
                    ))
                    .inner_margin(egui::Margin::symmetric(16, 14))
                    .show(ui, |ui| {
                        ui.set_width(ui.available_width());
                        // The right edge is claimed first so the text column
                        // wraps inside what remains instead of pushing the
                        // selection control off-screen.
                        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                            if selected {
                                ui.label(RichText::new("●").color(tokens::ACCENT).size(14.0));
                            } else if widgets::ghost_button(ui, "Select").clicked() {
                                clicked_select = true;
                            }
                            ui.add_space(tokens::spacing::SM);

                            ui.with_layout(egui::Layout::top_down(egui::Align::LEFT), |ui| {
                                ui.horizontal(|ui| {
                                    widgets::badge(ui, tier.badge(), selected);
                                    ui.add_space(tokens::spacing::SM);
                                    ui.vertical(|ui| {
                                        ui.label(
                                            RichText::new(tier.title())
                                                .color(tokens::TEXT)
                                                .size(13.0)
                                                .strong(),
                                        );
                                        ui.add(
                                            egui::Label::new(
                                                RichText::new(tier.description())
                                                    .color(tokens::MUTED)
                                                    .size(12.0),
                                            )
                                            .wrap(),
                                        );
                                    });
                                });
                                widgets::status_line(ui, &status);
                                if offer_download && widgets::button(ui, "Download").clicked() {
                                    clicked_download = true;
                                }
                            });
                        });
                    });
                ui.add_space(tokens::spacing::XS);

                if clicked_select {
                    store.update(|s| {
                        s.provider.kind = tier.kind();
                        if let Some(model) = &model {
                            s.provider.whisper_cpp_model = model.id.to_string();
                        }
                    });
                    self.notify(UiCommand::ProviderChanged);
                }
                if clicked_download {
                    if let Some(model) = model.clone() {
                        if let Some(task) = self.downloads.get_mut(model.id) {
                            let worker_model = model.clone();
                            task.start(&ctx, move |sink| {
                                runtime::download_model(&worker_model, sink)
                            });
                        }
                    }
                }
            }

            // Being honest when Advanced has taken the settings somewhere the
            // tiers cannot represent beats showing an arbitrary row as chosen.
            if !Tier::all().iter().any(|t| t.matches(&settings)) {
                widgets::note(
                    ui,
                    "Your current setup does not match any preset — see Advanced below.",
                );
            }
        });
    }

    /// The whisper.cpp binary install — Windows' stand-in for the distro
    /// package the Linux build leans on.
    fn whisper_cpp_card(&mut self, ui: &mut Ui, store: &SettingsStore) {
        let ctx = ui.ctx().clone();
        let mut refresh_provider = false;

        widgets::card(ui, "📦", "whisper.cpp engine", |ui| {
            widgets::note(
                ui,
                "The local Whisper tiers above run on whisper.cpp. Whisper Smart installs the \
                 official prebuilt whisper-cli.exe into its own data directory — nothing \
                 system-wide, checksum-verified, removed with one click.",
            );
            ui.add_space(tokens::spacing::SM);

            if self.whisper_task.poll() {
                refresh_provider = true;
            }
            if self.whisper_task.running {
                widgets::status_line(ui, &self.whisper_task.status.clone());
                return;
            }

            let installed = runtime::is_whisper_cpp_installed();
            let external = diagnostics::whisper_cli_path();
            if installed {
                widgets::status_line(
                    ui,
                    &format!("Installed at {}", paths::whisper_cpp_dir().display()),
                );
            } else if let Some(path) = &external {
                widgets::status_line(
                    ui,
                    &format!("Using the whisper-cli found at {}", path.display()),
                );
            } else {
                widgets::status_line(ui, "Not installed.");
            }
            widgets::status_line(ui, &self.whisper_task.status.clone());

            ui.horizontal(|ui| {
                let label = if installed {
                    "Reinstall whisper.cpp"
                } else {
                    "Install whisper.cpp"
                };
                if widgets::button(ui, label).clicked() {
                    self.whisper_task.start(&ctx, runtime::install_whisper_cpp);
                }
                if installed && widgets::ghost_button(ui, "Remove").clicked() {
                    match runtime::uninstall_whisper_cpp() {
                        Ok(()) => self.whisper_task.status = "Removed.".to_string(),
                        Err(err) => self.whisper_task.status = err,
                    }
                    refresh_provider = true;
                }
            });
        });

        if refresh_provider {
            let _ = store; // provider rebuild reads the store itself
            self.notify(UiCommand::ProviderChanged);
        }
    }

    fn cloud_card(&mut self, ui: &mut Ui, store: &SettingsStore) {
        let settings = store.get();

        widgets::card(ui, "☁", "OpenAI API", |ui| {
            widgets::row(ui, "API key", None, |ui| {
                ui.add(
                    egui::TextEdit::singleline(&mut self.key_entry)
                        .password(true)
                        .hint_text(if credentials::has_openai_key() {
                            "A key is saved"
                        } else {
                            "sk-…"
                        })
                        .desired_width(260.0),
                );
            });
            ui.horizontal(|ui| {
                if widgets::button(ui, "Save key").clicked() {
                    if self.key_entry.trim().is_empty() {
                        self.key_status = "Enter a key first.".to_string();
                    } else {
                        match credentials::write_openai_key(&self.key_entry) {
                            Ok(()) => {
                                self.key_entry.clear();
                                self.key_status = "Key saved.".to_string();
                                self.notify(UiCommand::ProviderChanged);
                            }
                            Err(err) => {
                                self.key_status = format!("Could not save the key: {err}");
                            }
                        }
                    }
                }
                if widgets::ghost_button(ui, "Remove key").clicked() {
                    match credentials::delete_openai_key() {
                        Ok(()) => self.key_status = "Key removed.".to_string(),
                        Err(err) => self.key_status = format!("Could not remove the key: {err}"),
                    }
                    self.notify(UiCommand::ProviderChanged);
                }
            });
            widgets::status_line(ui, &self.key_status.clone());
            widgets::note(
                ui,
                &format!(
                    "The key is stored in your user profile at {}. It is never written to \
                     config.toml.",
                    paths::credentials_file().display()
                ),
            );
            widgets::separator(ui);

            widgets::row(
                ui,
                "Base URL",
                Some("Change this to use any OpenAI-compatible transcription endpoint."),
                |ui| {
                    if ui
                        .add(egui::TextEdit::singleline(&mut self.base_url).desired_width(260.0))
                        .changed()
                    {
                        let value = self.base_url.clone();
                        store.update(|s| s.provider.openai.base_url = value);
                        self.notify(UiCommand::ProviderChanged);
                    }
                },
            );
            widgets::separator(ui);

            widgets::row(ui, "Model", None, |ui| {
                if ui
                    .add(egui::TextEdit::singleline(&mut self.openai_model).desired_width(160.0))
                    .changed()
                {
                    let value = self.openai_model.clone();
                    store.update(|s| s.provider.openai.model = value);
                    self.notify(UiCommand::ProviderChanged);
                }
            });
            widgets::separator(ui);

            widgets::row(
                ui,
                "Cloud fallback",
                Some(
                    "If the local engine cannot start, use the OpenAI API instead. Off by \
                     default: with this off, a broken local setup fails loudly rather than \
                     quietly uploading your microphone.",
                ),
                |ui| {
                    let mut on = settings.provider.cloud_fallback_enabled;
                    if widgets::toggle(ui, &mut on).changed() {
                        store.update(|s| s.provider.cloud_fallback_enabled = on);
                        self.notify(UiCommand::ProviderChanged);
                    }
                },
            );
        });
    }

    /// Everything the tiers deliberately hide: engines, per-engine models,
    /// compute, language, and the managed Python runtime.
    fn advanced_card(&mut self, ui: &mut Ui, store: &SettingsStore) {
        let settings = store.get();
        let ctx = ui.ctx().clone();

        widgets::card(ui, "🛠", "Advanced", |ui| {
            egui::CollapsingHeader::new(
                RichText::new("Engines, compute, and the local runtime")
                    .color(tokens::MUTED)
                    .size(12.0),
            )
            .default_open(false)
            .show(ui, |ui| {
                // -- Engine --------------------------------------------------
                let kinds = ProviderKind::all();
                let labels: Vec<String> =
                    kinds.iter().map(|k| k.display_name().to_string()).collect();
                let index = kinds
                    .iter()
                    .position(|k| *k == settings.provider.kind)
                    .unwrap_or(0);
                widgets::row(ui, "Engine", None, |ui| {
                    if let Some(index) = widgets::dropdown(ui, "engine", &labels, index) {
                        store.update(|s| s.provider.kind = kinds[index]);
                        self.notify(UiCommand::ProviderChanged);
                    }
                });
                widgets::note(ui, settings.provider.kind.summary());

                // -- Per-engine model choice ---------------------------------
                for engine in [
                    ModelEngine::WhisperCpp,
                    ModelEngine::FasterWhisper,
                    ModelEngine::ParakeetOnnx,
                ] {
                    widgets::separator(ui);
                    self.engine_model_row(ui, store, &settings, engine, &ctx);
                }

                // -- Compute -------------------------------------------------
                widgets::separator(ui);
                let devices = [ComputeDevice::Auto, ComputeDevice::Cuda, ComputeDevice::Cpu];
                let labels: Vec<String> = devices
                    .iter()
                    .map(|d| d.display_name().to_string())
                    .collect();
                let index = devices
                    .iter()
                    .position(|d| *d == settings.provider.compute_device)
                    .unwrap_or(0);
                let cuda_note = if diagnostics::cuda_available() {
                    "An NVIDIA GPU was detected. If the engine cannot use it, inference falls \
                     back to the CPU."
                } else {
                    "No NVIDIA GPU was detected; inference runs on the CPU."
                };
                widgets::row(ui, "Compute device", Some(cuda_note), |ui| {
                    if let Some(index) = widgets::dropdown(ui, "compute", &labels, index) {
                        store.update(|s| s.provider.compute_device = devices[index]);
                        self.notify(UiCommand::ProviderChanged);
                    }
                });

                // -- Language ------------------------------------------------
                widgets::separator(ui);
                widgets::row(
                    ui,
                    "Language",
                    Some("An ISO code such as en or de. Blank detects automatically."),
                    |ui| {
                        if ui
                            .add(
                                egui::TextEdit::singleline(&mut self.language)
                                    .hint_text("auto")
                                    .desired_width(80.0),
                            )
                            .changed()
                        {
                            let value = self.language.clone();
                            store.update(|s| s.provider.language = value);
                            self.notify(UiCommand::ProviderChanged);
                        }
                    },
                );

                // -- Runtime -------------------------------------------------
                widgets::separator(ui);
                self.runtime_section(ui, store, &settings, &ctx);
            });
        });
    }

    /// One engine's model dropdown, with download and remove.
    fn engine_model_row(
        &mut self,
        ui: &mut Ui,
        store: &SettingsStore,
        settings: &Settings,
        engine: ModelEngine,
        ctx: &egui::Context,
    ) {
        let models = model_catalog::models_for(engine);
        let labels: Vec<String> = models
            .iter()
            .map(|m| format!("{} · {}", m.display_name, m.approx_size_label))
            .collect();
        let selected_id = settings.selected_model_id(engine).to_string();
        let index = models.iter().position(|m| m.id == selected_id).unwrap_or(0);

        widgets::row(ui, engine.display_name(), None, |ui| {
            if let Some(index) = widgets::dropdown(ui, &format!("model-{engine:?}"), &labels, index)
            {
                let id = models[index].id.to_string();
                store.update(|s| s.set_selected_model_id(engine, id));
                self.notify(UiCommand::ProviderChanged);
            }
        });

        let model = models[index.min(models.len() - 1)].clone();
        let task = self
            .downloads
            .entry(model.id.to_string())
            .or_insert_with(Task::idle);
        if task.poll() {
            self.notify(UiCommand::ProviderChanged);
        }
        let installed = diagnostics::is_model_installed(&model);
        let (running, status) = {
            let task = self.downloads.get(model.id).expect("just inserted");
            (task.running, task.status.clone())
        };
        if running {
            widgets::status_line(ui, &status);
        } else {
            widgets::status_line(
                ui,
                if installed {
                    "Downloaded."
                } else {
                    "Not downloaded."
                },
            );
        }

        let mut start_download = false;
        let mut remove_result: Option<Result<(), String>> = None;
        ui.horizontal(|ui| {
            if !installed && !running && widgets::button(ui, "Download").clicked() {
                start_download = true;
            }
            if installed && widgets::ghost_button(ui, "Remove").clicked() {
                remove_result = Some(runtime::remove_model(&model));
            }
        });

        if start_download {
            let worker_model = model.clone();
            if let Some(task) = self.downloads.get_mut(model.id) {
                task.start(ctx, move |sink| {
                    runtime::download_model(&worker_model, sink)
                });
            }
        }
        if let Some(result) = remove_result {
            if let Some(task) = self.downloads.get_mut(model.id) {
                task.status = match result {
                    Ok(()) => "Removed.".to_string(),
                    Err(err) => err,
                };
            }
            self.notify(UiCommand::ProviderChanged);
        }
    }

    fn runtime_section(
        &mut self,
        ui: &mut Ui,
        store: &SettingsStore,
        settings: &Settings,
        ctx: &egui::Context,
    ) {
        widgets::note(
            ui,
            "faster-whisper and Parakeet run inside a Python environment that Whisper Smart \
             manages for you. It lives in the app's data directory and never touches any \
             system Python. whisper.cpp does not need it at all.",
        );

        if self.runtime_task.poll() {
            self.notify(UiCommand::ProviderChanged);
        }
        if self.runtime_task.running {
            widgets::status_line(ui, &self.runtime_task.status.clone());
            return;
        }

        if runtime::is_installed() {
            widgets::status_line(
                ui,
                &format!("Installed at {}", paths::python_runtime_dir().display()),
            );
        } else {
            widgets::status_line(
                ui,
                &format!(
                    "Not installed. {}",
                    runtime::select_base_python().describe()
                ),
            );
        }
        widgets::status_line(ui, &self.runtime_task.status.clone());

        let engine = settings
            .provider
            .kind
            .engine()
            .filter(|engine| engine.needs_python_runtime())
            // Selecting whisper.cpp and pressing Install should still do
            // something useful rather than erroring out.
            .unwrap_or(ModelEngine::FasterWhisper);
        let device = settings.provider.compute_device;

        ui.horizontal(|ui| {
            let label = if runtime::is_installed() {
                "Reinstall runtime"
            } else {
                "Install runtime"
            };
            if widgets::button(ui, label).clicked() {
                self.runtime_task
                    .start(ctx, move |sink| runtime::install(engine, device, sink));
            }
            if runtime::is_installed() && widgets::ghost_button(ui, "Remove runtime").clicked() {
                match runtime::uninstall() {
                    Ok(()) => self.runtime_task.status = "Runtime removed.".to_string(),
                    Err(err) => self.runtime_task.status = err,
                }
            }
        });
        let _ = store;
    }

    // -----------------------------------------------------------------------
    // History
    // -----------------------------------------------------------------------

    fn history_page(&mut self, ui: &mut Ui, store: &SettingsStore) {
        let settings = store.get();
        let log = TranscriptLog::new(paths::transcript_log_file(), settings.history.max_entries);

        if self.history.is_none() {
            self.history = Some(log.read().unwrap_or_default());
        }

        widgets::card(ui, "☰", "Recent transcripts", |ui| {
            widgets::row(
                ui,
                "Keep history",
                Some("Transcripts are stored on this machine only, and never uploaded."),
                |ui| {
                    let mut on = settings.history.enabled;
                    if widgets::toggle(ui, &mut on).changed() {
                        store.update(|s| s.history.enabled = on);
                        self.notify(UiCommand::PreferencesChanged);
                    }
                },
            );
            widgets::separator(ui);
            ui.add_space(tokens::spacing::SM);

            let entries = self.history.clone().unwrap_or_default();
            if entries.is_empty() {
                widgets::note(ui, "Nothing dictated yet.");
            }
            for entry in &entries {
                ui.horizontal_top(|ui| {
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::TOP), |ui| {
                        if widgets::ghost_button(ui, "Insert").clicked() {
                            self.notify(UiCommand::Reinject(entry.text.clone()));
                        }
                        ui.vertical(|ui| {
                            ui.with_layout(egui::Layout::top_down(egui::Align::LEFT), |ui| {
                                ui.label(RichText::new(&entry.text).color(tokens::TEXT).size(12.0));
                                ui.label(
                                    RichText::new(&entry.provider)
                                        .color(tokens::MUTED)
                                        .size(10.0),
                                );
                            });
                        });
                    });
                });
                widgets::separator(ui);
            }

            ui.add_space(tokens::spacing::SM);
            if widgets::ghost_button(ui, "Clear history").clicked()
                && TranscriptLog::new(paths::transcript_log_file(), 1)
                    .clear()
                    .is_ok()
            {
                self.history = Some(Vec::new());
            }
            widgets::note(ui, &format!("Stored at {}", log.path().display()));
        });
    }

    // -----------------------------------------------------------------------
    // Setup
    // -----------------------------------------------------------------------

    fn setup_page(&mut self, ui: &mut Ui, store: &SettingsStore) {
        if self.checks.is_none() {
            self.checks = Some(diagnostics::run_checks(&store.get()));
        }

        widgets::card(ui, "🔧", "Readiness", |ui| {
            widgets::note(
                ui,
                "Whisper Smart needs a few things from the system. Anything not ready is \
                 listed here with the way to fix it.",
            );
            ui.add_space(tokens::spacing::SM);

            for check in self.checks.clone().unwrap_or_default() {
                ui.horizontal(|ui| {
                    ui.label(
                        RichText::new(&check.title)
                            .color(tokens::TEXT)
                            .size(13.0)
                            .strong(),
                    );
                    let (label, color) = match check.status {
                        CheckStatus::Ok => ("Ready", tokens::SUCCESS),
                        CheckStatus::Warning => ("Degraded", tokens::WARNING),
                        CheckStatus::Blocked => ("Blocked", tokens::ERROR),
                    };
                    ui.label(RichText::new(label).color(color).size(11.0).strong());
                });
                ui.label(RichText::new(&check.detail).color(tokens::MUTED).size(12.0));
                if let Some(remedy) = &check.remedy {
                    ui.label(
                        RichText::new(remedy)
                            .color(tokens::MUTED)
                            .size(11.0)
                            .monospace(),
                    );
                }
                ui.add_space(tokens::spacing::MD);
            }

            if widgets::ghost_button(ui, "Re-run checks").clicked() {
                self.checks = None;
            }
        });
        ui.add_space(tokens::spacing::LG);

        widgets::card(ui, "📁", "Files", |ui| {
            for (label, path) in [
                ("Settings", paths::config_file()),
                ("Models", paths::models_dir()),
                ("Runtime", paths::python_runtime_dir()),
                ("whisper.cpp", paths::whisper_cpp_dir()),
                ("History", paths::transcript_log_file()),
                ("Log", paths::log_file()),
            ] {
                widgets::row(ui, label, None, |ui| {
                    ui.label(
                        RichText::new(path.display().to_string())
                            .color(tokens::MUTED)
                            .size(11.0)
                            .monospace(),
                    );
                });
                widgets::separator(ui);
            }
        });
    }
}

/// One navigation entry: icon, title, subtitle, with the selected state's
/// accent treatment. Returns true when clicked.
fn nav_item(ui: &mut Ui, tab: Tab, selected: bool) -> bool {
    let width = ui.available_width();
    let (rect, response) = ui.allocate_exact_size(egui::vec2(width, 54.0), egui::Sense::click());

    if ui.is_rect_visible(rect) {
        let painter = ui.painter();
        if selected {
            painter.rect_filled(rect, 0.0, tokens::active());
            painter.rect_filled(
                egui::Rect::from_min_size(rect.min, egui::vec2(3.0, rect.height())),
                0.0,
                tokens::ACCENT,
            );
        } else if response.hovered() {
            painter.rect_filled(rect, 0.0, tokens::TEXT.gamma_multiply(0.05));
        }

        let text_color = if selected {
            tokens::ACCENT
        } else {
            tokens::TEXT
        };
        let sub_color = if selected {
            tokens::ACCENT
        } else {
            tokens::MUTED
        };

        painter.text(
            egui::pos2(rect.min.x + 16.0, rect.min.y + 12.0),
            egui::Align2::LEFT_TOP,
            tab.icon(),
            egui::FontId::proportional(14.0),
            tokens::ACCENT,
        );
        painter.text(
            egui::pos2(rect.min.x + 42.0, rect.min.y + 10.0),
            egui::Align2::LEFT_TOP,
            tab.label(),
            egui::FontId::proportional(13.0),
            text_color,
        );
        painter.text(
            egui::pos2(rect.min.x + 42.0, rect.min.y + 28.0),
            egui::Align2::LEFT_TOP,
            tab.subtitle(),
            egui::FontId::proportional(11.0),
            sub_color.gamma_multiply(0.9),
        );
    }

    response.clicked()
}

/// The product logo, decoded from the same PNG the other builds ship.
fn load_logo(ctx: &egui::Context) -> Option<egui::TextureHandle> {
    const LOGO: &[u8] = include_bytes!("../../resources/whisper-smart-logo.png");
    let decoded = image::load_from_memory(LOGO).ok()?.to_rgba8();
    let size = [decoded.width() as usize, decoded.height() as usize];
    let image = egui::ColorImage::from_rgba_unmultiplied(size, decoded.as_raw());
    Some(ctx.load_texture("ws-logo", image, egui::TextureOptions::LINEAR))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_tier_resolves_to_a_consistent_provider_and_model() {
        for tier in Tier::all() {
            match tier.model() {
                Some(model) => {
                    assert_eq!(tier.kind(), ProviderKind::WhisperCpp);
                    assert_eq!(model.engine, ModelEngine::WhisperCpp);
                    assert!(model_catalog::model(model.id).is_some());
                }
                None => assert_eq!(tier.kind(), ProviderKind::OpenAiApi),
            }
        }
    }

    #[test]
    fn selecting_a_tier_is_detectable_from_the_settings() {
        let mut settings = Settings::default();
        settings.provider.kind = ProviderKind::WhisperCpp;
        settings.provider.whisper_cpp_model = model_catalog::CPP_SMALL.id.to_string();
        assert!(Tier::Balanced.matches(&settings));
        assert!(!Tier::Light.matches(&settings));

        settings.provider.kind = ProviderKind::OpenAiApi;
        assert!(Tier::Cloud.matches(&settings));
    }

    #[test]
    fn a_custom_engine_choice_matches_no_tier() {
        let mut settings = Settings::default();
        settings.provider.kind = ProviderKind::Parakeet;
        assert!(!Tier::all().iter().any(|t| t.matches(&settings)));
    }

    #[test]
    fn the_tabs_match_the_product_page_set() {
        let labels: Vec<&str> = Tab::all().iter().map(|t| t.label()).collect();
        assert_eq!(
            labels,
            vec![
                "General",
                "Hotkey",
                "Dictionary & Style",
                "Provider",
                "History",
                "Setup"
            ]
        );
    }

    #[test]
    fn a_finished_task_reports_done_exactly_once() {
        let mut task = Task::idle();
        task.running = true;
        task.slot.lock().unwrap().push(Progress::Fraction(0.5));
        task.slot.lock().unwrap().push(Progress::Done);
        assert!(task.poll(), "completion must be reported");
        assert!(!task.running);
        assert!(!task.poll(), "and only once");
    }

    #[test]
    fn a_failed_task_keeps_the_error_visible() {
        let mut task = Task::idle();
        task.running = true;
        task.slot
            .lock()
            .unwrap()
            .push(Progress::Failed("no network".into()));
        assert!(task.poll());
        assert_eq!(task.status, "no network");
    }
}
