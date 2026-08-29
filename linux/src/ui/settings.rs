//! Settings window.
//!
//! Port of `SettingsView.swift`, tab for tab: General, Hotkey, Provider, Text,
//! History, plus a Setup tab that has no macOS counterpart — on macOS the
//! equivalent information is a TCC permission prompt, whereas on Linux the
//! things that can be missing (input-group membership, `wtype`, a Python
//! runtime, model weights) all need explaining and a command to fix them.
//!
//! The window owns no application state. Every change is written straight to
//! the [`SettingsStore`] and, when it needs the running app to react, sent as a
//! [`UiCommand`] so the reaction happens on the main loop's thread.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use crossbeam_channel::Sender;
use gtk::glib;
use gtk::prelude::*;

use crate::core::hotkey_binding::HotkeyBinding;
use crate::core::model_catalog::{self, ModelEngine};
use crate::core::provider::ProviderKind;
use crate::core::settings::{
    ComputeDevice, Correction, InjectionMode, OverlayStyle, SettingsStore, WritingStyle,
};
use crate::core::transcript_log::TranscriptLog;
use crate::core::{credentials, paths};
use crate::platform::diagnostics::{self, CheckStatus};
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

/// The pages, in sidebar order.
///
/// Mirrors `SettingsTab` in `app/UI/SettingsView.swift`, including the
/// subtitles and ledes, so the two builds read as the same product. `Setup` has
/// no macOS counterpart: the things that can be missing on Linux — input-group
/// membership, `wtype`, a ggml backend, model weights — all need explaining,
/// whereas macOS surfaces the equivalent as system permission prompts.
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
    fn all() -> Vec<Tab> {
        vec![
            Tab::General,
            Tab::Hotkey,
            Tab::Dictionary,
            Tab::Provider,
            Tab::History,
            Tab::Setup,
        ]
    }

    fn key(self) -> &'static str {
        match self {
            Tab::General => "general",
            Tab::Hotkey => "hotkey",
            Tab::Dictionary => "dictionary",
            Tab::Provider => "provider",
            Tab::History => "history",
            Tab::Setup => "setup",
        }
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
            Tab::Setup => "Permissions & dependencies",
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
            Tab::General => "preferences-system-symbolic",
            Tab::Hotkey => "preferences-desktop-keyboard-symbolic",
            Tab::Dictionary => "format-text-rich-symbolic",
            Tab::Provider => "weather-overcast-symbolic",
            Tab::History => "view-list-symbolic",
            Tab::Setup => "emblem-system-symbolic",
        }
    }
}

/// Builds and presents the settings window.
pub fn present(
    app: &gtk::Application,
    store: SettingsStore,
    commands: Sender<UiCommand>,
    initial_tab: Tab,
) -> gtk::ApplicationWindow {
    let window = gtk::ApplicationWindow::builder()
        .application(app)
        .title("Whisper Smart")
        .default_width(tokens::size::SETTINGS_WIDTH)
        .default_height(tokens::size::SETTINGS_HEIGHT)
        .build();
    window.add_css_class("vf-settings");

    let root = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    root.add_css_class("vf-root");

    let stack = gtk::Stack::new();
    stack.set_hexpand(true);
    stack.set_vexpand(true);
    stack.set_transition_type(gtk::StackTransitionType::None);

    for tab in Tab::all() {
        let content = match tab {
            Tab::General => general_page(&store, &commands),
            Tab::Hotkey => hotkey_page(&store, &commands),
            Tab::Dictionary => dictionary_page(&store, &commands),
            Tab::Provider => provider_page(&store, &commands),
            Tab::History => history_page(&store, &commands),
            Tab::Setup => setup_page(&store),
        };
        stack.add_named(&page_shell(tab, content), Some(tab.key()));
    }

    let rail = sidebar(&stack, initial_tab);
    root.append(&rail.container);
    root.append(&stack);

    stack.set_visible_child_name(initial_tab.key());
    window.set_child(Some(&root));

    install_responsive_layout(&root, rail);

    window.present();
    window
}

/// Keeps the layout within whatever width the compositor hands us.
///
/// GTK4 has no media queries and `GtkWindow` does not notify on allocation, so
/// the width is sampled from a frame-clock tick and acted on only when the
/// breakpoint actually changes. The work per frame is one integer comparison.
fn install_responsive_layout(root: &gtk::Box, rail: Rail) {
    let current: Rc<Cell<Option<tokens::Breakpoint>>> = Rc::new(Cell::new(None));
    let root_for_tick = root.clone();

    root.add_tick_callback(move |widget, _clock| {
        let width = widget.width();
        if width <= 0 {
            return glib::ControlFlow::Continue;
        }

        let breakpoint = tokens::breakpoint_for(width);
        if current.get() == Some(breakpoint) {
            return glib::ControlFlow::Continue;
        }
        current.set(Some(breakpoint));

        for class in tokens::ALL_BREAKPOINT_CLASSES {
            root_for_tick.remove_css_class(class);
        }
        root_for_tick.add_css_class(breakpoint.css_class());

        rail.container
            .set_size_request(breakpoint.sidebar_width(), -1);
        for item in &rail.nav_items {
            item.subtitle.set_visible(breakpoint.shows_nav_subtitles());
            item.labels.set_visible(breakpoint.shows_nav_labels());
        }
        // The wordmark and version pill have nowhere to go in an icons-only rail.
        rail.brand_text.set_visible(breakpoint.shows_nav_labels());
        rail.footer.set_visible(breakpoint.shows_nav_labels());

        glib::ControlFlow::Continue
    });
}

/// Wraps a page's cards in the title + lede header and a scroller.
fn page_shell(tab: Tab, content: gtk::Box) -> gtk::Widget {
    let page = gtk::Box::new(gtk::Orientation::Vertical, tokens::spacing::XXS);
    page.add_css_class("vf-content");
    // Padding lives in CSS so the breakpoint classes can tighten it.
    page.add_css_class("vf-page");

    let title = gtk::Label::new(Some(tab.label()));
    title.add_css_class("vf-page-title");
    title.set_halign(gtk::Align::Start);
    page.append(&title);

    let lede = gtk::Label::new(Some(tab.lede()));
    lede.add_css_class("vf-page-lede");
    lede.set_halign(gtk::Align::Start);
    lede.set_xalign(0.0);
    lede.set_wrap(true);
    page.append(&lede);

    // A clear gap between the page header and the first card.
    content.set_margin_top(tokens::spacing::XL);
    page.append(&content);

    let scroller = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&page)
        .build();
    scroller.upcast()
}

/// The left rail: brand, navigation, and footer.
/// The sidebar plus the handles the responsive layer needs.
struct Rail {
    container: gtk::Box,
    nav_items: Vec<NavItem>,
    footer: gtk::Box,
    /// The "Whisper Smart / Preferences" wordmark beside the logo.
    brand_text: gtk::Box,
}

fn sidebar(stack: &gtk::Stack, initial_tab: Tab) -> Rail {
    let sidebar = gtk::Box::new(gtk::Orientation::Vertical, 0);
    sidebar.add_css_class("vf-sidebar");
    sidebar.set_size_request(tokens::size::SIDEBAR_WIDTH, -1);
    // Fixed rail: content takes the remaining width, as on macOS.
    sidebar.set_hexpand(false);

    let (brand, brand_text) = brand_row();
    sidebar.append(&brand);

    let nav = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let buttons: Rc<RefCell<Vec<(Tab, gtk::Button)>>> = Rc::new(RefCell::new(Vec::new()));

    // The brand wordmark collapses with the nav labels, so it rides along as a
    // pseudo-item with no button of its own.
    let mut items: Vec<NavItem> = Vec::new();
    for tab in Tab::all() {
        let item = nav_item(tab);
        let button = item.button.clone();
        {
            let stack = stack.clone();
            let buttons = Rc::clone(&buttons);
            button.connect_clicked(move |_| {
                stack.set_visible_child_name(tab.key());
                // Selection is exclusive, so clear the rest.
                for (other, other_button) in buttons.borrow().iter() {
                    if *other == tab {
                        other_button.add_css_class("selected");
                    } else {
                        other_button.remove_css_class("selected");
                    }
                }
            });
        }
        if tab == initial_tab {
            button.add_css_class("selected");
        }
        nav.append(&button);
        buttons.borrow_mut().push((tab, button));
        items.push(item);
    }
    sidebar.append(&nav);

    let spacer = gtk::Box::new(gtk::Orientation::Vertical, 0);
    spacer.set_vexpand(true);
    sidebar.append(&spacer);

    let footer = sidebar_footer();
    sidebar.append(&footer);
    Rail {
        container: sidebar,
        nav_items: items,
        footer,
        brand_text,
    }
}

/// Logo, product name, and "Preferences", matching the macOS sidebar header.
fn brand_row() -> (gtk::Box, gtk::Box) {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, tokens::spacing::SM);
    row.add_css_class("vf-brand-row");
    row.set_margin_top(tokens::spacing::LG);
    row.set_margin_bottom(tokens::spacing::LG);
    row.set_margin_start(tokens::spacing::MD);
    row.set_margin_end(tokens::spacing::MD);
    row.set_margin_bottom(tokens::spacing::LG);

    if let Some(logo) = brand_logo(40) {
        row.append(&logo);
    }

    let text = gtk::Box::new(gtk::Orientation::Vertical, 1);
    text.set_valign(gtk::Align::Center);

    let name = gtk::Label::new(Some("Whisper Smart"));
    name.add_css_class("vf-brand-name");
    name.set_halign(gtk::Align::Start);
    text.append(&name);

    let sub = gtk::Label::new(Some("Preferences"));
    sub.add_css_class("vf-brand-sub");
    sub.set_halign(gtk::Align::Start);
    text.append(&sub);

    row.append(&text);
    (row, text)
}

/// The product logo, decoded from the same PNG the macOS build ships.
///
/// Deliberately a `gtk::Image` rather than a `gtk::Picture`: `Picture` reports
/// the texture's own size as its natural size, so the 512px asset stretched the
/// sidebar to fit it. `Image` honours `pixel_size` instead.
fn brand_logo(size: i32) -> Option<gtk::Image> {
    const LOGO: &[u8] = include_bytes!("../../resources/whisper-smart-logo.png");
    let bytes = gtk::glib::Bytes::from_static(LOGO);
    let texture = gtk::gdk::Texture::from_bytes(&bytes).ok()?;
    let image = gtk::Image::from_paintable(Some(&texture));
    image.set_pixel_size(size);
    image.set_valign(gtk::Align::Center);
    image.set_halign(gtk::Align::Start);
    Some(image)
}

/// The pieces of a nav entry the responsive layer hides as space runs out.
struct NavItem {
    button: gtk::Button,
    labels: gtk::Box,
    subtitle: gtk::Label,
}

/// One navigation entry: icon, title, subtitle.
fn nav_item(tab: Tab) -> NavItem {
    let content = gtk::Box::new(gtk::Orientation::Horizontal, tokens::spacing::SM);

    let icon = gtk::Image::from_icon_name(tab.icon());
    icon.set_pixel_size(16);
    icon.set_valign(gtk::Align::Center);
    content.append(&icon);

    let text = gtk::Box::new(gtk::Orientation::Vertical, 1);
    text.set_hexpand(true);
    let title = gtk::Label::new(Some(tab.label()));
    title.add_css_class("vf-nav-title");
    title.set_halign(gtk::Align::Start);
    title.set_ellipsize(gtk::pango::EllipsizeMode::End);
    text.append(&title);

    let subtitle = gtk::Label::new(Some(tab.subtitle()));
    subtitle.add_css_class("vf-nav-sub");
    subtitle.set_halign(gtk::Align::Start);
    subtitle.set_ellipsize(gtk::pango::EllipsizeMode::End);
    text.append(&subtitle);

    content.append(&text);

    let button = gtk::Button::builder().child(&content).build();
    button.add_css_class("vf-nav-item");
    button.set_tooltip_text(Some(tab.label()));
    NavItem {
        button,
        labels: text,
        subtitle,
    }
}

/// Footer: a link to the setup checks and the platform pill, standing in for
/// the macOS sidebar's "Onboarding" button and "macOS native" badge.
fn sidebar_footer() -> gtk::Box {
    let footer = gtk::Box::new(gtk::Orientation::Vertical, tokens::spacing::XS);
    footer.add_css_class("vf-sidebar-footer");

    let pill = gtk::Label::new(Some(&format!(
        "Linux native · v{}",
        env!("CARGO_PKG_VERSION")
    )));
    pill.add_css_class("vf-pill");
    pill.set_halign(gtk::Align::Start);
    footer.append(&pill);

    footer
}

// ---------------------------------------------------------------------------
// Layout helpers
// ---------------------------------------------------------------------------

/// A page body: a vertical stack of cards. Margins come from `page_shell`.
fn page() -> gtk::Box {
    gtk::Box::new(gtk::Orientation::Vertical, tokens::spacing::LG)
}

/// A titled card. Rows appended to the returned box land under the rule.
fn section(icon: &str, title: &str) -> gtk::Box {
    widgets::card(icon, title)
}

/// A settings row, inset from the card edges.
fn row(label: &str, help: Option<&str>, control: &impl IsA<gtk::Widget>) -> gtk::Box {
    let row = widgets::row(label, help, control);
    row.set_margin_start(tokens::spacing::XL);
    row.set_margin_end(tokens::spacing::XL);
    row
}

fn dropdown(options: &[String], selected: usize) -> gtk::DropDown {
    widgets::dropdown(options, selected)
}

/// Explanatory copy inside a card.
fn help_label(text: &str) -> gtk::Label {
    let label = widgets::note(text);
    label.set_margin_start(tokens::spacing::XL);
    label.set_margin_end(tokens::spacing::XL);
    label
}

fn notify(commands: &Sender<UiCommand>, command: UiCommand) {
    if commands.send(command).is_err() {
        tracing::warn!("settings change not applied; the app is shutting down");
    }
}

// ---------------------------------------------------------------------------
// General
// ---------------------------------------------------------------------------

fn general_page(store: &SettingsStore, commands: &Sender<UiCommand>) -> gtk::Box {
    let page = page();
    let settings = store.get();

    // -- Microphone ------------------------------------------------------
    let audio = section("audio-input-microphone-symbolic", "Microphone");

    let mut devices = vec!["System default".to_string()];
    devices.extend(crate::platform::audio::list_input_devices());
    let selected = devices
        .iter()
        .position(|d| *d == settings.general.input_device)
        .unwrap_or(0);
    let device_picker = dropdown(&devices, selected);
    {
        let store = store.clone();
        let devices = devices.clone();
        let commands = commands.clone();
        device_picker.connect_selected_notify(move |picker| {
            let index = picker.selected() as usize;
            // Index 0 is the synthetic "System default" entry, stored as "".
            let name = if index == 0 {
                String::new()
            } else {
                devices[index].clone()
            };
            store.update(|s| s.general.input_device = name);
            notify(&commands, UiCommand::PreferencesChanged);
        });
    }
    audio.append(&row(
        "Input device",
        Some("Which microphone to record from."),
        &device_picker,
    ));

    let silence = gtk::SpinButton::with_range(0.5, 30.0, 0.5);
    silence.set_value(settings.general.silence_timeout_seconds);
    {
        let store = store.clone();
        let commands = commands.clone();
        silence.connect_value_changed(move |spin| {
            let value = spin.value();
            store.update(|s| s.general.silence_timeout_seconds = value);
            notify(&commands, UiCommand::PreferencesChanged);
        });
    }
    audio.append(&row(
        "Silence timeout",
        Some("How long a hands-free recording waits in silence before it stops. Does not apply while the hotkey is held."),
        &silence,
    ));
    page.append(&audio);

    // -- Overlay ---------------------------------------------------------
    let overlay = section("video-display-symbolic", "Overlay");
    let styles = [
        OverlayStyle::Bubble,
        OverlayStyle::TopBar,
        OverlayStyle::None,
    ];
    let style_labels: Vec<String> = styles
        .iter()
        .map(|s| s.display_name().to_string())
        .collect();
    let style_index = styles
        .iter()
        .position(|s| *s == settings.overlay.style)
        .unwrap_or(0);
    let style_picker = dropdown(&style_labels, style_index);
    {
        let store = store.clone();
        let commands = commands.clone();
        style_picker.connect_selected_notify(move |picker| {
            let style = styles[picker.selected() as usize];
            store.update(|s| s.overlay.style = style);
            notify(&commands, UiCommand::PreferencesChanged);
        });
    }
    overlay.append(&row("Style", Some("Shown while recording."), &style_picker));

    let show_transcript = gtk::Switch::new();
    show_transcript.set_active(settings.overlay.show_transcript);
    {
        let store = store.clone();
        let commands = commands.clone();
        show_transcript.connect_state_set(move |_, active| {
            store.update(|s| s.overlay.show_transcript = active);
            notify(&commands, UiCommand::PreferencesChanged);
            glib::Propagation::Proceed
        });
    }
    overlay.append(&row(
        "Show transcript",
        Some("Preview the text in the overlay."),
        &show_transcript,
    ));
    page.append(&overlay);

    // -- Insertion -------------------------------------------------------
    let insertion = section("insert-text-symbolic", "Text insertion");
    let modes = [
        InjectionMode::Smart,
        InjectionMode::TypeOnly,
        InjectionMode::PasteOnly,
    ];
    let mode_labels: Vec<String> = modes.iter().map(|m| m.display_name().to_string()).collect();
    let mode_index = modes
        .iter()
        .position(|m| *m == settings.injection.mode)
        .unwrap_or(0);
    let mode_picker = dropdown(&mode_labels, mode_index);
    {
        let store = store.clone();
        let commands = commands.clone();
        mode_picker.connect_selected_notify(move |picker| {
            let mode = modes[picker.selected() as usize];
            store.update(|s| s.injection.mode = mode);
            notify(&commands, UiCommand::PreferencesChanged);
        });
    }
    insertion.append(&row(
        "Mode",
        Some("Smart types the text with wtype, then falls back to a clipboard paste if that is unavailable."),
        &mode_picker,
    ));

    let restore = gtk::Switch::new();
    restore.set_active(settings.injection.restore_clipboard);
    {
        let store = store.clone();
        let commands = commands.clone();
        restore.connect_state_set(move |_, active| {
            store.update(|s| s.injection.restore_clipboard = active);
            notify(&commands, UiCommand::PreferencesChanged);
            glib::Propagation::Proceed
        });
    }
    insertion.append(&row(
        "Restore clipboard",
        Some("Put your previous clipboard contents back after a paste-based insertion."),
        &restore,
    ));
    page.append(&insertion);

    // -- Notifications ---------------------------------------------------
    let feedback = section("preferences-system-notifications-symbolic", "Feedback");
    let notify_errors = gtk::Switch::new();
    notify_errors.set_active(settings.general.notify_on_error);
    {
        let store = store.clone();
        let commands = commands.clone();
        notify_errors.connect_state_set(move |_, active| {
            store.update(|s| s.general.notify_on_error = active);
            notify(&commands, UiCommand::PreferencesChanged);
            glib::Propagation::Proceed
        });
    }
    feedback.append(&row(
        "Notify on failure",
        Some("Show a desktop notification when a dictation fails."),
        &notify_errors,
    ));
    page.append(&feedback);

    page
}

// ---------------------------------------------------------------------------
// Hotkey
// ---------------------------------------------------------------------------

fn hotkey_page(store: &SettingsStore, commands: &Sender<UiCommand>) -> gtk::Box {
    let page = page();
    let settings = store.get();

    let binding_section = section("preferences-desktop-keyboard-symbolic", "Dictation hotkey");
    binding_section.append(&help_label(
        "Hold the key to dictate and release to insert. Press it twice quickly to start a \
         hands-free recording that keeps going until you press it again or stop speaking. \
         Press Esc during a recording to discard it.",
    ));

    let presets = HotkeyBinding::presets();
    let labels: Vec<String> = presets.iter().map(HotkeyBinding::display_string).collect();
    let current_index = presets.iter().position(|p| *p == settings.hotkey);

    // A custom recorded binding is shown as an extra entry so the dropdown
    // never silently misrepresents what is actually bound.
    let mut all_labels = labels.clone();
    let selected_index = match current_index {
        Some(index) => index,
        None => {
            all_labels.push(format!("{} (custom)", settings.hotkey.display_string()));
            all_labels.len() - 1
        }
    };

    let picker = dropdown(&all_labels, selected_index);
    {
        let store = store.clone();
        let commands = commands.clone();
        let presets = presets.clone();
        picker.connect_selected_notify(move |picker| {
            let index = picker.selected() as usize;
            let Some(binding) = presets.get(index).cloned() else {
                return; // the trailing "custom" entry
            };
            store.update(|s| s.hotkey = binding.clone());
            notify(&commands, UiCommand::HotkeyChanged);
        });
    }
    binding_section.append(&row("Binding", None, &picker));

    // -- Recorder --------------------------------------------------------
    let current_label = gtk::Label::new(Some(&settings.hotkey.display_string()));
    current_label.add_css_class("ws-hotkey-recorder");

    let record_button = gtk::Button::with_label("Record a new hotkey");
    let status = help_label("");
    status.set_visible(false);

    {
        let store = store.clone();
        let commands = commands.clone();
        let current_label = current_label.clone();
        let status = status.clone();
        let picker = picker.clone();
        record_button.connect_clicked(move |button| {
            button.set_sensitive(false);
            button.set_label("Press a key…");
            status.set_visible(true);
            status.set_text("Press and hold the key you want to use for dictation.");

            let captured: Arc<Mutex<Option<HotkeyBinding>>> = Arc::new(Mutex::new(None));
            let failed: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
            crate::platform::hotkey::record_next_binding(
                Arc::clone(&captured),
                Arc::clone(&failed),
            );

            let store = store.clone();
            let commands = commands.clone();
            let button = button.clone();
            let current_label = current_label.clone();
            let status = status.clone();
            let picker = picker.clone();
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);

            // Poll rather than block: the capture happens on an input-reading
            // thread and the main loop must stay responsive.
            glib::timeout_add_local(std::time::Duration::from_millis(50), move || {
                if let Some(error) = failed.lock().ok().and_then(|mut f| f.take()) {
                    status.set_text(&error);
                    button.set_sensitive(true);
                    button.set_label("Record a new hotkey");
                    return glib::ControlFlow::Break;
                }

                if let Some(binding) = captured.lock().ok().and_then(|mut c| c.take()) {
                    let label = binding.display_string();
                    current_label.set_text(&label);
                    status.set_text(&format!("Bound to {label}."));
                    store.update(|s| s.hotkey = binding.clone());
                    notify(&commands, UiCommand::HotkeyChanged);

                    // Keep the dropdown honest about what is bound.
                    if let Some(index) = HotkeyBinding::presets().iter().position(|p| *p == binding)
                    {
                        picker.set_selected(index as u32);
                    }

                    button.set_sensitive(true);
                    button.set_label("Record a new hotkey");
                    return glib::ControlFlow::Break;
                }

                if std::time::Instant::now() > deadline {
                    status.set_text("No key was pressed; the hotkey is unchanged.");
                    button.set_sensitive(true);
                    button.set_label("Record a new hotkey");
                    return glib::ControlFlow::Break;
                }

                glib::ControlFlow::Continue
            });
        });
    }

    let binding_advice = help_label("");
    let update_advice = {
        let binding_advice = binding_advice.clone();
        move |binding: &HotkeyBinding| {
            if binding.is_modifier_only() {
                binding_advice.set_text("");
                binding_advice.set_visible(false);
            } else {
                binding_advice.set_text(
                    "This binding includes a regular key, so holding it will autorepeat that key \
                     into whatever has focus. A bare modifier avoids that.",
                );
                binding_advice.set_visible(true);
            }
        }
    };
    update_advice(&settings.hotkey);

    binding_section.append(&row("Current", None, &current_label));
    binding_section.append(&binding_advice);
    binding_section.append(&record_button);
    binding_section.append(&status);
    page.append(&binding_section);

    let advice = section("dialog-information-symbolic", "Choosing a key");
    advice.append(&help_label(
        "A modifier key that is not otherwise used works best, because holding it alone does \
         nothing in other applications. Right Ctrl and Right Alt are good choices on most \
         keyboards. Avoid Super, which Hyprland uses as its own modifier.",
    ));
    page.append(&advice);

    page
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// A one-click preset: what most people actually want to choose between.
///
/// The macOS Provider page offers Light / Balanced / Best / Cloud rather than
/// an engine matrix, and that framing carries over. Every local tier is
/// whisper.cpp, which is the path that needs no Python runtime and no CUDA
/// wheel matching — the engines that do are still available under Advanced.
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
    fn model(self) -> Option<crate::core::model_catalog::LocalModel> {
        match self {
            Tier::Light => Some(model_catalog::CPP_BASE),
            Tier::Balanced => Some(model_catalog::CPP_SMALL),
            Tier::Best => Some(model_catalog::CPP_LARGE_V3_TURBO),
            Tier::Cloud => None,
        }
    }

    /// Whether the current settings are exactly this tier.
    fn matches(self, settings: &crate::core::settings::Settings) -> bool {
        if settings.provider.kind != self.kind() {
            return false;
        }
        match self.model() {
            Some(model) => settings.provider.whisper_cpp_model == model.id,
            None => true,
        }
    }
}

fn provider_page(store: &SettingsStore, commands: &Sender<UiCommand>) -> gtk::Box {
    let page = page();

    page.append(&tier_card(store, commands));
    page.append(&cloud_section(store, commands));
    page.append(&advanced_card(store, commands));

    page
}

/// The tier picker: one card, four rows, no engine jargon.
fn tier_card(store: &SettingsStore, commands: &Sender<UiCommand>) -> gtk::Box {
    let card = section("audio-speakers-symbolic", "Model");
    card.append(&help_label(
        "Pick a model and Whisper Smart downloads it on request. Nothing is installed until you \
         ask, and nothing leaves your machine unless you choose Cloud.",
    ));

    let list = gtk::Box::new(gtk::Orientation::Vertical, tokens::spacing::XS);
    list.set_margin_start(tokens::spacing::XL);
    list.set_margin_end(tokens::spacing::XL);
    list.set_margin_top(tokens::spacing::MD);

    let settings = store.get();
    let mut group: Option<gtk::CheckButton> = None;

    for tier in Tier::all() {
        let row = widgets::choice_row(
            tier.badge(),
            tier.title(),
            tier.description(),
            group.as_ref(),
        );
        if group.is_none() {
            group = Some(row.radio.clone());
        }

        let selected = tier.matches(&settings);
        row.radio.set_active(selected);
        if selected {
            row.container.add_css_class("selected");
        }

        refresh_tier_row(&row, tier);

        // Selecting a tier writes both the provider and its model, so the two
        // can never drift out of step.
        {
            let store = store.clone();
            let commands = commands.clone();
            let container = row.container.clone();
            row.radio.connect_toggled(move |radio| {
                if !radio.is_active() {
                    container.remove_css_class("selected");
                    return;
                }
                container.add_css_class("selected");
                store.update(|s| {
                    s.provider.kind = tier.kind();
                    if let Some(model) = tier.model() {
                        s.provider.whisper_cpp_model = model.id.to_string();
                    }
                });
                notify(&commands, UiCommand::ProviderChanged);
            });
        }

        // The action button downloads the tier's model, or jumps to the key
        // field for Cloud.
        {
            let commands = commands.clone();
            let row_status = row.status.clone();
            let row_action = row.action.clone();
            row.action.connect_clicked(move |button| {
                let Some(model) = tier.model() else { return };
                button.set_sensitive(false);
                row_status.set_visible(true);
                row_status.set_text(&format!("Downloading {}…", model.display_name));

                let slot: Arc<Mutex<Vec<Progress>>> = Arc::new(Mutex::new(Vec::new()));
                let worker_slot = Arc::clone(&slot);
                std::thread::Builder::new()
                    .name("model-download".to_string())
                    .spawn(move || {
                        let sink: runtime::ProgressSink = Box::new(move |update| {
                            if let Ok(mut queue) = worker_slot.lock() {
                                queue.push(update);
                            }
                        });
                        if let Err(err) = runtime::download_model(&model, &sink) {
                            tracing::error!("model download failed: {err}");
                        }
                    })
                    .ok();

                let status = row_status.clone();
                let action = row_action.clone();
                let commands = commands.clone();
                glib::timeout_add_local(std::time::Duration::from_millis(120), move || {
                    let updates: Vec<Progress> = slot
                        .lock()
                        .map(|mut q| std::mem::take(&mut *q))
                        .unwrap_or_default();
                    for update in updates {
                        match update {
                            Progress::Step(text) => status.set_text(&text),
                            Progress::Fraction(fraction) => {
                                status.set_text(&format!(
                                    "Downloading… {}%",
                                    (fraction * 100.0).round() as u32
                                ));
                            }
                            Progress::Done => {
                                status.set_text("Downloaded.");
                                action.set_visible(false);
                                action.set_sensitive(true);
                                notify(&commands, UiCommand::ProviderChanged);
                                return glib::ControlFlow::Break;
                            }
                            Progress::Failed(err) => {
                                status.set_text(&err);
                                action.set_sensitive(true);
                                return glib::ControlFlow::Break;
                            }
                        }
                    }
                    glib::ControlFlow::Continue
                });
            });
        }

        list.append(&row.container);
    }

    card.append(&list);

    // Being honest when Advanced has taken the settings somewhere the tiers
    // cannot represent beats showing an arbitrary row as selected.
    if !Tier::all().iter().any(|t| t.matches(&settings)) {
        card.append(&help_label(
            "Your current setup does not match any preset — see Advanced below.",
        ));
    }

    card
}

/// Fills in a tier row's status line and action button.
fn refresh_tier_row(row: &widgets::ChoiceRow, tier: Tier) {
    match tier.model() {
        Some(model) => {
            if diagnostics::is_model_installed(&model) {
                row.status.set_visible(true);
                row.status
                    .set_text(&format!("Downloaded · {}", model.approx_size_label));
                row.action.set_visible(false);
            } else {
                row.status.set_visible(true);
                row.status
                    .set_text(&format!("Not downloaded · {}", model.approx_size_label));
                row.action.set_label("Download");
                row.action.set_visible(true);
            }
        }
        None => {
            let has_key = credentials::has_openai_key();
            row.status.set_visible(true);
            row.status.set_text(if has_key {
                "API key saved"
            } else {
                "Needs an API key — add one below"
            });
            row.action.set_visible(false);
        }
    }
}

/// Everything the tiers deliberately hide: engines, per-engine models, compute,
/// language, and the managed Python runtime.
fn advanced_card(store: &SettingsStore, commands: &Sender<UiCommand>) -> gtk::Box {
    let body = gtk::Box::new(gtk::Orientation::Vertical, tokens::spacing::MD);
    body.set_margin_top(tokens::spacing::MD);

    let settings = store.get();

    // -- Engine ----------------------------------------------------------
    let kinds = ProviderKind::all();
    let kind_labels: Vec<String> = kinds.iter().map(|k| k.display_name().to_string()).collect();
    let kind_index = kinds
        .iter()
        .position(|k| *k == settings.provider.kind)
        .unwrap_or(0);
    let summary = widgets::note(settings.provider.kind.summary());
    let kind_picker = widgets::dropdown(&kind_labels, kind_index);
    {
        let store = store.clone();
        let commands = commands.clone();
        let kinds = kinds.clone();
        let summary = summary.clone();
        kind_picker.connect_selected_notify(move |picker| {
            let kind = kinds[picker.selected() as usize];
            summary.set_text(kind.summary());
            store.update(|s| s.provider.kind = kind);
            notify(&commands, UiCommand::ProviderChanged);
        });
    }
    body.append(&widgets::row("Engine", None, &kind_picker));
    body.append(&summary);

    // -- Per-engine model choice -----------------------------------------
    for engine in [
        ModelEngine::WhisperCpp,
        ModelEngine::FasterWhisper,
        ModelEngine::ParakeetOnnx,
    ] {
        body.append(&widgets::separator());
        body.append(&engine_model_row(store, commands, engine));
    }

    // -- Compute ---------------------------------------------------------
    body.append(&widgets::separator());
    let devices = [ComputeDevice::Auto, ComputeDevice::Cuda, ComputeDevice::Cpu];
    let device_labels: Vec<String> = devices
        .iter()
        .map(|d| d.display_name().to_string())
        .collect();
    let device_index = devices
        .iter()
        .position(|d| *d == settings.provider.compute_device)
        .unwrap_or(0);
    let device_picker = widgets::dropdown(&device_labels, device_index);
    {
        let store = store.clone();
        let commands = commands.clone();
        device_picker.connect_selected_notify(move |picker| {
            let device = devices[picker.selected() as usize];
            store.update(|s| s.provider.compute_device = device);
            notify(&commands, UiCommand::ProviderChanged);
        });
    }
    body.append(&widgets::row(
        "Compute device",
        Some(if diagnostics::cuda_available() {
            "An NVIDIA GPU was detected. If the engine cannot use it, inference falls back to the CPU."
        } else {
            "No NVIDIA GPU was detected; inference runs on the CPU."
        }),
        &device_picker,
    ));

    // -- Language --------------------------------------------------------
    body.append(&widgets::separator());
    let language = gtk::Entry::new();
    language.set_text(&settings.provider.language);
    language.set_placeholder_text(Some("auto"));
    language.set_max_width_chars(10);
    {
        let store = store.clone();
        let commands = commands.clone();
        language.connect_changed(move |entry| {
            let value = entry.text().to_string();
            store.update(|s| s.provider.language = value);
            notify(&commands, UiCommand::ProviderChanged);
        });
    }
    body.append(&widgets::row(
        "Language",
        Some("An ISO code such as en or de. Blank detects automatically."),
        &language,
    ));

    // -- Runtime ---------------------------------------------------------
    body.append(&widgets::separator());
    body.append(&runtime_section(store));

    let card = section("emblem-system-symbolic", "Advanced");
    let expander = widgets::advanced("Engines, compute, and the local runtime", &body);
    expander.set_margin_start(tokens::spacing::XL);
    expander.set_margin_end(tokens::spacing::XL);
    expander.set_margin_top(tokens::spacing::SM);
    expander.set_margin_bottom(tokens::spacing::SM);
    card.append(&expander);
    card
}

/// One engine's model dropdown, with download and remove.
fn engine_model_row(
    store: &SettingsStore,
    commands: &Sender<UiCommand>,
    engine: ModelEngine,
) -> gtk::Box {
    let settings = store.get();
    let models = model_catalog::models_for(engine);
    let labels: Vec<String> = models
        .iter()
        .map(|m| format!("{} · {}", m.display_name, m.approx_size_label))
        .collect();
    let selected_id = settings.selected_model_id(engine).to_string();
    let index = models.iter().position(|m| m.id == selected_id).unwrap_or(0);

    let column = gtk::Box::new(gtk::Orientation::Vertical, tokens::spacing::XS);
    let picker = widgets::dropdown(&labels, index);
    column.append(&widgets::row(engine.display_name(), None, &picker));

    let status = widgets::note("");
    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, tokens::spacing::XS);
    let download = widgets::button("Download");
    let remove = widgets::ghost_button("Remove");
    buttons.append(&download);
    buttons.append(&remove);

    let refresh = {
        let status = status.clone();
        let download = download.clone();
        let remove = remove.clone();
        let models = models.clone();
        let picker = picker.clone();
        Rc::new(move || {
            let model = &models[picker.selected() as usize];
            let installed = diagnostics::is_model_installed(model);
            status.set_text(if installed {
                "Downloaded."
            } else {
                "Not downloaded."
            });
            download.set_sensitive(!installed);
            remove.set_sensitive(installed);
        })
    };
    refresh();

    {
        let store = store.clone();
        let commands = commands.clone();
        let models = models.clone();
        let refresh = Rc::clone(&refresh);
        picker.connect_selected_notify(move |picker| {
            let model = &models[picker.selected() as usize];
            store.update(|s| s.set_selected_model_id(engine, model.id.to_string()));
            refresh();
            notify(&commands, UiCommand::ProviderChanged);
        });
    }

    {
        let commands = commands.clone();
        let models = models.clone();
        let picker = picker.clone();
        let status = status.clone();
        let refresh = Rc::clone(&refresh);
        let download_button = download.clone();
        download.connect_clicked(move |button| {
            let model = models[picker.selected() as usize].clone();
            button.set_sensitive(false);
            status.set_text(&format!("Downloading {}…", model.display_name));

            let slot: Arc<Mutex<Vec<Progress>>> = Arc::new(Mutex::new(Vec::new()));
            let worker_slot = Arc::clone(&slot);
            std::thread::Builder::new()
                .name("model-download".to_string())
                .spawn(move || {
                    let sink: runtime::ProgressSink = Box::new(move |update| {
                        if let Ok(mut queue) = worker_slot.lock() {
                            queue.push(update);
                        }
                    });
                    if let Err(err) = runtime::download_model(&model, &sink) {
                        tracing::error!("model download failed: {err}");
                    }
                })
                .ok();

            let status = status.clone();
            let button = download_button.clone();
            let commands = commands.clone();
            let refresh = Rc::clone(&refresh);
            glib::timeout_add_local(std::time::Duration::from_millis(120), move || {
                let updates: Vec<Progress> = slot
                    .lock()
                    .map(|mut q| std::mem::take(&mut *q))
                    .unwrap_or_default();
                for update in updates {
                    match update {
                        Progress::Step(text) => status.set_text(&text),
                        Progress::Fraction(fraction) => status.set_text(&format!(
                            "Downloading… {}%",
                            (fraction * 100.0).round() as u32
                        )),
                        Progress::Done => {
                            status.set_text("Downloaded.");
                            button.set_sensitive(true);
                            refresh();
                            notify(&commands, UiCommand::ProviderChanged);
                            return glib::ControlFlow::Break;
                        }
                        Progress::Failed(err) => {
                            status.set_text(&err);
                            button.set_sensitive(true);
                            refresh();
                            return glib::ControlFlow::Break;
                        }
                    }
                }
                glib::ControlFlow::Continue
            });
        });
    }

    {
        let models = models.clone();
        let picker = picker.clone();
        let status = status.clone();
        let refresh = Rc::clone(&refresh);
        remove.connect_clicked(move |_| {
            let model = &models[picker.selected() as usize];
            match runtime::remove_model(model) {
                Ok(()) => status.set_text("Removed."),
                Err(err) => status.set_text(&err),
            }
            refresh();
        });
    }

    column.append(&status);
    column.append(&buttons);
    column
}

fn runtime_section(store: &SettingsStore) -> gtk::Box {
    let section = section("system-run-symbolic", "Local inference runtime");
    section.append(&help_label(
        "faster-whisper and Parakeet run inside a Python environment that Whisper Smart manages \
         for you. It is installed in your data directory and never touches your system Python. \
         whisper.cpp does not need it at all.",
    ));

    let status = help_label("");
    let progress = gtk::ProgressBar::new();
    progress.set_visible(false);
    let install = gtk::Button::with_label("Install runtime");
    let remove = gtk::Button::with_label("Remove runtime");

    let refresh = {
        let status = status.clone();
        let install = install.clone();
        let remove = remove.clone();
        Rc::new(move || {
            if runtime::is_installed() {
                status.set_text(&format!(
                    "Installed at {}",
                    paths::python_runtime_dir().display()
                ));
                install.set_label("Reinstall runtime");
                remove.set_sensitive(true);
            } else {
                status.set_text(&format!(
                    "Not installed. {}",
                    runtime::select_base_python().describe()
                ));
                install.set_label("Install runtime");
                remove.set_sensitive(false);
            }
        })
    };
    refresh();

    {
        let store = store.clone();
        let status = status.clone();
        let progress = progress.clone();
        let refresh = Rc::clone(&refresh);
        let install_button = install.clone();
        install.connect_clicked(move |button| {
            let settings = store.get();
            let engine = settings
                .provider
                .kind
                .engine()
                .filter(|engine| engine.needs_python_runtime())
                // Selecting whisper.cpp and pressing Install should still do
                // something useful rather than erroring out.
                .unwrap_or(ModelEngine::FasterWhisper);
            let device = settings.provider.compute_device;

            button.set_sensitive(false);
            progress.set_visible(true);
            progress.pulse();
            status.set_text("Installing…");

            let slot: Arc<Mutex<Vec<Progress>>> = Arc::new(Mutex::new(Vec::new()));
            let worker_slot = Arc::clone(&slot);
            std::thread::Builder::new()
                .name("runtime-install".to_string())
                .spawn(move || {
                    let sink: runtime::ProgressSink = Box::new(move |update| {
                        if let Ok(mut queue) = worker_slot.lock() {
                            queue.push(update);
                        }
                    });
                    match runtime::install(engine, device, &sink) {
                        Ok(()) => sink(Progress::Done),
                        Err(err) => sink(Progress::Failed(err)),
                    }
                })
                .ok();

            let progress = progress.clone();
            let status = status.clone();
            let button = install_button.clone();
            let refresh = Rc::clone(&refresh);
            glib::timeout_add_local(std::time::Duration::from_millis(200), move || {
                let updates: Vec<Progress> = slot
                    .lock()
                    .map(|mut q| std::mem::take(&mut *q))
                    .unwrap_or_default();

                // pip gives no usable percentage, so the bar pulses to show
                // the install is alive rather than lying about progress.
                progress.pulse();

                for update in updates {
                    match update {
                        Progress::Step(text) => status.set_text(&text),
                        Progress::Fraction(fraction) => progress.set_fraction(fraction as f64),
                        Progress::Done => {
                            progress.set_visible(false);
                            status.set_text("Runtime installed.");
                            button.set_sensitive(true);
                            refresh();
                            return glib::ControlFlow::Break;
                        }
                        Progress::Failed(err) => {
                            progress.set_visible(false);
                            status.set_text(&err);
                            button.set_sensitive(true);
                            refresh();
                            return glib::ControlFlow::Break;
                        }
                    }
                }
                glib::ControlFlow::Continue
            });
        });
    }

    {
        let status = status.clone();
        let refresh = Rc::clone(&refresh);
        remove.connect_clicked(move |_| {
            match runtime::uninstall() {
                Ok(()) => status.set_text("Runtime removed."),
                Err(err) => status.set_text(&err),
            }
            refresh();
        });
    }

    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, tokens::spacing::SM);
    buttons.append(&install);
    buttons.append(&remove);

    section.append(&status);
    section.append(&progress);
    section.append(&buttons);
    section
}

fn cloud_section(store: &SettingsStore, commands: &Sender<UiCommand>) -> gtk::Box {
    let settings = store.get();
    let section = section("weather-overcast-symbolic", "OpenAI API");

    let key_entry = gtk::PasswordEntry::new();
    key_entry.set_show_peek_icon(true);
    if credentials::has_openai_key() {
        // Never read the key back into the UI; only report that one exists.
        key_entry.set_placeholder_text(Some("A key is saved"));
    } else {
        key_entry.set_placeholder_text(Some("sk-…"));
    }

    let key_status = help_label(if credentials::has_openai_key() {
        "A key is saved."
    } else {
        "No key saved."
    });

    let save = gtk::Button::with_label("Save key");
    {
        let key_entry = key_entry.clone();
        let key_status = key_status.clone();
        let commands = commands.clone();
        save.connect_clicked(move |_| {
            let key = key_entry.text().to_string();
            if key.trim().is_empty() {
                key_status.set_text("Enter a key first.");
                return;
            }
            match credentials::write_openai_key(&key) {
                Ok(()) => {
                    key_entry.set_text("");
                    key_entry.set_placeholder_text(Some("A key is saved"));
                    key_status.set_text("Key saved.");
                    notify(&commands, UiCommand::ProviderChanged);
                }
                Err(err) => key_status.set_text(&format!("Could not save the key: {err}")),
            }
        });
    }

    let clear = gtk::Button::with_label("Remove key");
    {
        let key_status = key_status.clone();
        let commands = commands.clone();
        clear.connect_clicked(move |_| {
            match credentials::delete_openai_key() {
                Ok(()) => key_status.set_text("Key removed."),
                Err(err) => key_status.set_text(&format!("Could not remove the key: {err}")),
            }
            notify(&commands, UiCommand::ProviderChanged);
        });
    }

    section.append(&row("API key", None, &key_entry));
    section.append(&key_status);
    section.append(&help_label(&format!(
        "The key is stored with owner-only permissions in {}. It is never written to config.toml.",
        paths::credentials_file().display()
    )));

    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, tokens::spacing::SM);
    buttons.append(&save);
    buttons.append(&clear);
    section.append(&buttons);

    let base_url = gtk::Entry::new();
    base_url.set_text(&settings.provider.openai.base_url);
    {
        let store = store.clone();
        let commands = commands.clone();
        base_url.connect_changed(move |entry| {
            let value = entry.text().to_string();
            store.update(|s| s.provider.openai.base_url = value);
            notify(&commands, UiCommand::ProviderChanged);
        });
    }
    section.append(&row(
        "Base URL",
        Some("Change this to use any OpenAI-compatible transcription endpoint."),
        &base_url,
    ));

    let model = gtk::Entry::new();
    model.set_text(&settings.provider.openai.model);
    {
        let store = store.clone();
        let commands = commands.clone();
        model.connect_changed(move |entry| {
            let value = entry.text().to_string();
            store.update(|s| s.provider.openai.model = value);
            notify(&commands, UiCommand::ProviderChanged);
        });
    }
    section.append(&row("Model", None, &model));

    let fallback = gtk::Switch::new();
    fallback.set_active(settings.provider.cloud_fallback_enabled);
    {
        let store = store.clone();
        let commands = commands.clone();
        fallback.connect_state_set(move |_, active| {
            store.update(|s| s.provider.cloud_fallback_enabled = active);
            notify(&commands, UiCommand::ProviderChanged);
            glib::Propagation::Proceed
        });
    }
    section.append(&row(
        "Cloud fallback",
        Some("If the local engine cannot start, use the OpenAI API instead. Off by default: with this off, a broken local setup fails loudly rather than quietly uploading your microphone."),
        &fallback,
    ));

    section
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

fn dictionary_page(store: &SettingsStore, commands: &Sender<UiCommand>) -> gtk::Box {
    let page = page();
    let settings = store.get();

    let cleanup = section("format-text-rich-symbolic", "Clean-up");

    let styles = [
        WritingStyle::Neutral,
        WritingStyle::Formal,
        WritingStyle::Casual,
        WritingStyle::Concise,
        WritingStyle::Developer,
    ];
    let style_labels: Vec<String> = styles
        .iter()
        .map(|s| s.display_name().to_string())
        .collect();
    let style_index = styles
        .iter()
        .position(|s| *s == settings.text.writing_style)
        .unwrap_or(0);
    let style_picker = dropdown(&style_labels, style_index);
    {
        let store = store.clone();
        let commands = commands.clone();
        style_picker.connect_selected_notify(move |picker| {
            let style = styles[picker.selected() as usize];
            store.update(|s| s.text.writing_style = style);
            notify(&commands, UiCommand::PreferencesChanged);
        });
    }
    cleanup.append(&row("Writing style", None, &style_picker));

    // (label, help text, how to apply it, current value)
    type Toggle = (
        &'static str,
        &'static str,
        fn(&mut crate::core::settings::Settings, bool),
        bool,
    );
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
        let switch = gtk::Switch::new();
        switch.set_active(initial);
        let store = store.clone();
        let commands = commands.clone();
        switch.connect_state_set(move |_, active| {
            store.update(|s| apply(s, active));
            notify(&commands, UiCommand::PreferencesChanged);
            glib::Propagation::Proceed
        });
        cleanup.append(&row(label, Some(help), &switch));
    }
    page.append(&cleanup);

    // -- Corrections -----------------------------------------------------
    let corrections = section("edit-find-replace-symbolic", "Corrections");
    corrections.append(&help_label(
        "Replace words the engine reliably mishears. Matching ignores case and only applies to \
         whole words.",
    ));

    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::None);
    list.add_css_class("boxed-list");

    let rebuild = {
        let list = list.clone();
        let store = store.clone();
        let commands = commands.clone();
        let rebuild: Rc<dyn Fn()> = Rc::new(move || {
            while let Some(child) = list.first_child() {
                list.remove(&child);
            }
            for (index, correction) in store.get().text.corrections.iter().enumerate() {
                let row_box = gtk::Box::new(gtk::Orientation::Horizontal, tokens::spacing::SM);
                row_box.set_margin_top(tokens::spacing::XS);
                row_box.set_margin_bottom(tokens::spacing::XS);
                row_box.set_margin_start(tokens::spacing::SM);
                row_box.set_margin_end(tokens::spacing::SM);

                let text =
                    gtk::Label::new(Some(&format!("{} → {}", correction.from, correction.to)));
                text.set_halign(gtk::Align::Start);
                text.set_hexpand(true);
                row_box.append(&text);

                let delete = gtk::Button::from_icon_name("user-trash-symbolic");
                {
                    let store = store.clone();
                    let commands = commands.clone();
                    let list = list.clone();
                    delete.connect_clicked(move |button| {
                        store.update(|s| {
                            if index < s.text.corrections.len() {
                                s.text.corrections.remove(index);
                            }
                        });
                        notify(&commands, UiCommand::PreferencesChanged);
                        // Remove just this row rather than rebuilding, so the
                        // closure does not need to reference itself.
                        if let Some(row) = button.ancestor(gtk::ListBoxRow::static_type()) {
                            list.remove(&row);
                        }
                    });
                }
                row_box.append(&delete);
                list.append(&row_box);
            }
        });
        rebuild
    };
    rebuild();

    let from_entry = gtk::Entry::new();
    from_entry.set_placeholder_text(Some("heard as"));
    let to_entry = gtk::Entry::new();
    to_entry.set_placeholder_text(Some("replace with"));
    let add = gtk::Button::with_label("Add");
    {
        let store = store.clone();
        let commands = commands.clone();
        let from_entry = from_entry.clone();
        let to_entry = to_entry.clone();
        let rebuild = Rc::clone(&rebuild);
        add.connect_clicked(move |_| {
            let from = from_entry.text().trim().to_string();
            let to = to_entry.text().to_string();
            if from.is_empty() {
                return;
            }
            store.update(|s| {
                s.text.corrections.push(Correction {
                    from: from.clone(),
                    to: to.clone(),
                })
            });
            from_entry.set_text("");
            to_entry.set_text("");
            rebuild();
            notify(&commands, UiCommand::PreferencesChanged);
        });
    }

    let entry_row = gtk::Box::new(gtk::Orientation::Horizontal, tokens::spacing::SM);
    from_entry.set_hexpand(true);
    to_entry.set_hexpand(true);
    entry_row.append(&from_entry);
    entry_row.append(&to_entry);
    entry_row.append(&add);

    corrections.append(&list);
    corrections.append(&entry_row);
    page.append(&corrections);

    page
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

fn history_page(store: &SettingsStore, commands: &Sender<UiCommand>) -> gtk::Box {
    let page = page();
    let settings = store.get();

    let section = section("view-list-symbolic", "Recent transcripts");

    let enabled = gtk::Switch::new();
    enabled.set_active(settings.history.enabled);
    {
        let store = store.clone();
        let commands = commands.clone();
        enabled.connect_state_set(move |_, active| {
            store.update(|s| s.history.enabled = active);
            notify(&commands, UiCommand::PreferencesChanged);
            glib::Propagation::Proceed
        });
    }
    section.append(&row(
        "Keep history",
        Some("Transcripts are stored on this machine only, and never uploaded."),
        &enabled,
    ));

    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::None);
    list.add_css_class("boxed-list");

    let log = TranscriptLog::new(paths::transcript_log_file(), settings.history.max_entries);
    match log.read() {
        Ok(entries) if entries.is_empty() => {
            let empty = help_label("Nothing dictated yet.");
            empty.set_margin_top(tokens::spacing::MD);
            section.append(&empty);
        }
        Ok(entries) => {
            for entry in entries {
                let row_box = gtk::Box::new(gtk::Orientation::Horizontal, tokens::spacing::SM);
                row_box.set_margin_top(tokens::spacing::XS);
                row_box.set_margin_bottom(tokens::spacing::XS);
                row_box.set_margin_start(tokens::spacing::SM);
                row_box.set_margin_end(tokens::spacing::SM);

                let text = gtk::Label::new(Some(&entry.text));
                text.set_halign(gtk::Align::Start);
                text.set_xalign(0.0);
                text.set_wrap(true);
                text.set_hexpand(true);
                row_box.append(&text);

                let reinsert = gtk::Button::from_icon_name("insert-text-symbolic");
                reinsert.set_tooltip_text(Some("Insert again"));
                {
                    let commands = commands.clone();
                    let value = entry.text.clone();
                    reinsert.connect_clicked(move |_| {
                        notify(&commands, UiCommand::Reinject(value.clone()));
                    });
                }
                row_box.append(&reinsert);
                list.append(&row_box);
            }
            section.append(&list);
        }
        Err(err) => section.append(&help_label(&format!("Could not read the history: {err}"))),
    }

    let clear = gtk::Button::with_label("Clear history");
    {
        let list = list.clone();
        clear.connect_clicked(move |button| {
            let log = TranscriptLog::new(paths::transcript_log_file(), 1);
            if log.clear().is_ok() {
                while let Some(child) = list.first_child() {
                    list.remove(&child);
                }
                button.set_sensitive(false);
            }
        });
    }
    section.append(&clear);
    section.append(&help_label(&format!("Stored at {}", log.path().display())));

    page.append(&section);
    page
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

fn setup_page(store: &SettingsStore) -> gtk::Box {
    let page = page();
    let readiness = section("emblem-system-symbolic", "Readiness");
    readiness.append(&help_label(
        "Whisper Smart needs a few things from the system. Anything not ready is listed here \
         with the command that fixes it.",
    ));

    let list = gtk::Box::new(gtk::Orientation::Vertical, tokens::spacing::MD);
    let refresh_button = gtk::Button::with_label("Re-run checks");

    let render = {
        let list = list.clone();
        let store = store.clone();
        Rc::new(move || {
            while let Some(child) = list.first_child() {
                list.remove(&child);
            }
            for check in diagnostics::run_checks(&store.get()) {
                let item = gtk::Box::new(gtk::Orientation::Vertical, tokens::spacing::XS);

                let heading = gtk::Box::new(gtk::Orientation::Horizontal, tokens::spacing::SM);
                let title = gtk::Label::new(Some(&check.title));
                title.set_halign(gtk::Align::Start);
                title.add_css_class("ws-section-title");
                heading.append(&title);

                let badge = gtk::Label::new(Some(match check.status {
                    CheckStatus::Ok => "Ready",
                    CheckStatus::Warning => "Degraded",
                    CheckStatus::Blocked => "Blocked",
                }));
                badge.add_css_class(match check.status {
                    CheckStatus::Ok => "ws-status-ok",
                    CheckStatus::Warning => "ws-status-warning",
                    CheckStatus::Blocked => "ws-status-blocked",
                });
                heading.append(&badge);
                item.append(&heading);

                item.append(&help_label(&check.detail));

                if let Some(remedy) = &check.remedy {
                    let command = gtk::Label::new(Some(remedy));
                    command.add_css_class("ws-mono");
                    command.set_halign(gtk::Align::Start);
                    command.set_selectable(true);
                    command.set_wrap(true);
                    command.set_xalign(0.0);
                    item.append(&command);
                }

                list.append(&item);
            }
        })
    };
    render();

    {
        let render = Rc::clone(&render);
        refresh_button.connect_clicked(move |_| render());
    }

    readiness.append(&list);
    readiness.append(&refresh_button);
    page.append(&readiness);

    let paths_section = section("folder-symbolic", "Files");
    for (label, path) in [
        ("Settings", paths::config_file()),
        ("Models", paths::models_dir()),
        ("Runtime", paths::python_runtime_dir()),
        ("History", paths::transcript_log_file()),
        ("Log", paths::log_file()),
    ] {
        let value = gtk::Label::new(Some(&path.display().to_string()));
        value.add_css_class("ws-mono");
        value.set_selectable(true);
        value.set_halign(gtk::Align::End);
        paths_section.append(&row(label, None, &value));
    }
    page.append(&paths_section);

    page
}
