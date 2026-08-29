//! Recording overlay.
//!
//! Ports `BubblePanelController` / `FloatingBubbleView` and
//! `TopCenterOverlayPanelController` / `TopCenterWaveformOverlayView`.
//!
//! On macOS these are borderless `NSPanel`s with `.floating` window level,
//! which sit above everything and never take focus. Wayland has no window
//! levels and no way for a client to position itself — an ordinary toplevel
//! would be tiled by Hyprland and stealing focus mid-dictation would be
//! disastrous. `wlr-layer-shell` is the protocol that exists for exactly this
//! case, so the overlay is a layer surface on the overlay layer with keyboard
//! interactivity switched off.
//!
//! If the compositor lacks layer-shell the overlay is simply skipped: the tray
//! icon still reflects state, so dictation keeps working.

use std::cell::RefCell;
use std::rc::Rc;

use gtk::prelude::*;
use gtk::{cairo, glib};
use layer_shell::{Edge, KeyboardMode, Layer, LayerShell};

use crate::core::settings::OverlayStyle;
use crate::core::state_machine::State;
use crate::ui::tokens;

/// Live waveform levels, smoothed for display.
struct Waveform {
    /// Ring of recent levels, oldest first.
    bars: Vec<f64>,
    /// Most recent raw level from the capture thread.
    current: f64,
}

impl Waveform {
    fn new() -> Self {
        Self {
            bars: vec![0.0; tokens::size::WAVEFORM_BARS],
            current: 0.0,
        }
    }

    fn push_frame(&mut self) {
        self.bars.remove(0);
        self.bars.push(self.current);
        // Decay toward silence so the bars settle between syllables rather
        // than freezing at the last peak.
        self.current *= 1.0 - tokens::animation::WAVEFORM_DECAY;
    }

    fn set_level(&mut self, level: f64) {
        // Rise instantly, fall gradually: speech should look immediate.
        self.current = self.current.max(level.clamp(0.0, 1.0));
    }

    fn reset(&mut self) {
        self.bars.iter_mut().for_each(|b| *b = 0.0);
        self.current = 0.0;
    }
}

pub struct Overlay {
    window: gtk::ApplicationWindow,
    container: gtk::Box,
    label: gtk::Label,
    transcript: gtk::Label,
    drawing: gtk::DrawingArea,
    waveform: Rc<RefCell<Waveform>>,
    style: OverlayStyle,
    show_transcript: bool,
    /// Set when layer-shell is unavailable, so the overlay stays hidden
    /// instead of appearing as a stray floating window.
    disabled: bool,
    tick: Option<glib::SourceId>,
}

impl Overlay {
    /// Builds the overlay window. Returns an overlay that is never shown when
    /// the style is `None` or the compositor has no layer-shell support.
    pub fn new(app: &gtk::Application, style: OverlayStyle, show_transcript: bool) -> Self {
        let window = gtk::ApplicationWindow::builder()
            .application(app)
            .decorated(false)
            .resizable(false)
            .build();

        let supported = layer_shell::is_supported();
        if supported {
            window.init_layer_shell();
            window.set_namespace(Some("whisper-smart-overlay"));
            // Overlay layer draws above fullscreen windows, which is where a
            // dictation indicator belongs.
            window.set_layer(Layer::Overlay);
            // Never take keyboard focus: the user is typing into another app.
            window.set_keyboard_mode(KeyboardMode::None);
            // Zero exclusive zone so the overlay never reserves screen space
            // and shoves the user's tiled windows around.
            window.set_exclusive_zone(0);
        } else {
            tracing::warn!(
                "the compositor does not support wlr-layer-shell; the recording overlay is disabled"
            );
        }

        let container = gtk::Box::new(gtk::Orientation::Horizontal, tokens::spacing::SM);
        container.add_css_class("vf-overlay");

        let drawing = gtk::DrawingArea::new();
        drawing.set_content_width(
            (tokens::size::WAVEFORM_BARS as f64
                * (tokens::size::WAVEFORM_BAR_WIDTH + tokens::size::WAVEFORM_BAR_SPACING))
                as i32,
        );
        drawing.set_content_height(24);
        drawing.set_valign(gtk::Align::Center);

        let waveform = Rc::new(RefCell::new(Waveform::new()));
        let draw_waveform = Rc::clone(&waveform);
        drawing.set_draw_func(move |area, ctx, width, height| {
            draw_bars(area, ctx, width, height, &draw_waveform.borrow());
        });

        let label = gtk::Label::new(Some("Ready"));
        label.add_css_class("vf-overlay-label");
        label.set_valign(gtk::Align::Center);

        let transcript = gtk::Label::new(None);
        transcript.add_css_class("vf-overlay-transcript");
        transcript.set_ellipsize(gtk::pango::EllipsizeMode::End);
        transcript.set_max_width_chars(28);
        transcript.set_visible(false);

        let text_column = gtk::Box::new(gtk::Orientation::Vertical, 0);
        text_column.append(&label);
        text_column.append(&transcript);
        text_column.set_valign(gtk::Align::Center);

        container.append(&drawing);
        container.append(&text_column);
        window.set_child(Some(&container));

        let mut overlay = Self {
            window,
            container,
            label,
            transcript,
            drawing,
            waveform,
            style,
            show_transcript,
            disabled: !supported,
            tick: None,
        };
        overlay.apply_style(style);
        overlay
    }

    /// Repositions and resizes for the chosen style.
    pub fn apply_style(&mut self, style: OverlayStyle) {
        self.style = style;
        if self.disabled || style == OverlayStyle::None {
            self.window.set_visible(false);
            return;
        }

        // Anchoring only to one edge lets the surface centre itself along the
        // other axis, which is what both macOS panels do.
        for edge in [Edge::Top, Edge::Bottom, Edge::Left, Edge::Right] {
            self.window.set_anchor(edge, false);
            self.window.set_margin(edge, 0);
        }

        match style {
            OverlayStyle::Bubble => {
                self.window.set_anchor(Edge::Bottom, true);
                self.window
                    .set_margin(Edge::Bottom, tokens::size::BUBBLE_MARGIN);
                self.window
                    .set_default_size(tokens::size::BUBBLE_WIDTH, tokens::size::BUBBLE_HEIGHT);
                self.drawing.set_visible(true);
            }
            OverlayStyle::TopBar => {
                self.window.set_anchor(Edge::Top, true);
                self.window
                    .set_margin(Edge::Top, tokens::size::TOP_BAR_MARGIN);
                self.window
                    .set_default_size(tokens::size::TOP_BAR_WIDTH, tokens::size::TOP_BAR_HEIGHT);
                self.drawing.set_visible(true);
            }
            OverlayStyle::None => {}
        }
    }

    pub fn set_show_transcript(&mut self, show: bool) {
        self.show_transcript = show;
        if !show {
            self.transcript.set_visible(false);
        }
    }

    /// Reflects a state change: shows, hides, and recolours the overlay.
    pub fn set_state(&mut self, state: &State) {
        self.label.set_text(&tokens::state_label(state));

        for class in tokens::ALL_STATE_CLASSES {
            self.container.remove_css_class(class);
        }
        self.container.add_css_class(tokens::state_css_class(state));

        match state {
            State::Recording => {
                self.transcript.set_text("");
                self.transcript.set_visible(false);
                self.show();
                self.start_animation();
            }
            State::Transcribing => {
                self.stop_animation();
                self.waveform.borrow_mut().reset();
                self.drawing.queue_draw();
                self.show();
            }
            State::Success | State::Error(_) => {
                self.stop_animation();
                self.show();
            }
            State::Idle => {
                self.stop_animation();
                self.waveform.borrow_mut().reset();
                self.hide();
            }
        }
    }

    pub fn set_level(&self, level: f32) {
        self.waveform.borrow_mut().set_level(level as f64);
    }

    pub fn set_transcript(&self, text: &str) {
        if !self.show_transcript {
            return;
        }
        let trimmed = text.trim();
        self.transcript.set_visible(!trimmed.is_empty());
        self.transcript.set_text(trimmed);
    }

    fn show(&self) {
        if self.disabled || self.style == OverlayStyle::None {
            return;
        }
        self.window.set_visible(true);
    }

    fn hide(&self) {
        self.window.set_visible(false);
    }

    fn start_animation(&mut self) {
        if self.tick.is_some() || self.disabled || self.style == OverlayStyle::None {
            return;
        }
        let waveform = Rc::clone(&self.waveform);
        let drawing = self.drawing.clone();
        let id = glib::timeout_add_local(
            std::time::Duration::from_millis(tokens::animation::WAVEFORM_FRAME_MS as u64),
            move || {
                waveform.borrow_mut().push_frame();
                drawing.queue_draw();
                glib::ControlFlow::Continue
            },
        );
        self.tick = Some(id);
    }

    fn stop_animation(&mut self) {
        if let Some(id) = self.tick.take() {
            id.remove();
        }
    }
}

impl Drop for Overlay {
    fn drop(&mut self) {
        self.stop_animation();
    }
}

/// Draws the level bars, oldest on the left.
fn draw_bars(
    area: &gtk::DrawingArea,
    ctx: &cairo::Context,
    width: i32,
    height: i32,
    waveform: &Waveform,
) {
    let color = area.color();
    ctx.set_source_rgba(
        color.red() as f64,
        color.green() as f64,
        color.blue() as f64,
        0.85,
    );

    let bar_w = tokens::size::WAVEFORM_BAR_WIDTH;
    let gap = tokens::size::WAVEFORM_BAR_SPACING;
    let total = waveform.bars.len() as f64 * (bar_w + gap) - gap;
    let mut x = (width as f64 - total).max(0.0) / 2.0;
    let mid = height as f64 / 2.0;

    for level in &waveform.bars {
        // Height ramps between the Mac's min and max bar heights rather than
        // filling the widget, so the HUD reads the same on both platforms.
        let span = tokens::size::WAVEFORM_BAR_MAX_HEIGHT - tokens::size::WAVEFORM_BAR_MIN_HEIGHT;
        let bar_h = tokens::size::WAVEFORM_BAR_MIN_HEIGHT + level * span;
        let y = mid - bar_h / 2.0;
        // Square caps: the design language is zero corner radius throughout.
        ctx.rectangle(x, y, bar_w, bar_h);
        let _ = ctx.fill();
        x += bar_w + gap;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_new_waveform_is_silent() {
        let waveform = Waveform::new();
        assert_eq!(waveform.bars.len(), tokens::size::WAVEFORM_BARS);
        assert!(waveform.bars.iter().all(|b| *b == 0.0));
    }

    #[test]
    fn levels_rise_instantly_and_fall_gradually() {
        let mut waveform = Waveform::new();
        waveform.set_level(0.9);
        assert_eq!(waveform.current, 0.9);

        // A quieter reading does not immediately pull the bar down.
        waveform.set_level(0.1);
        assert_eq!(waveform.current, 0.9);

        waveform.push_frame();
        assert!(
            waveform.current < 0.9,
            "the level should decay between frames"
        );
        assert!(waveform.current > 0.0);
    }

    #[test]
    fn frames_scroll_the_bars_leftwards() {
        let mut waveform = Waveform::new();
        waveform.set_level(1.0);
        waveform.push_frame();

        assert_eq!(
            *waveform.bars.last().unwrap(),
            1.0,
            "newest sample is on the right"
        );
        assert_eq!(waveform.bars[0], 0.0);
        assert_eq!(
            waveform.bars.len(),
            tokens::size::WAVEFORM_BARS,
            "the ring keeps its size"
        );
    }

    #[test]
    fn levels_are_clamped_to_the_drawable_range() {
        let mut waveform = Waveform::new();
        waveform.set_level(5.0);
        assert_eq!(waveform.current, 1.0);

        let mut waveform = Waveform::new();
        waveform.set_level(-2.0);
        assert_eq!(waveform.current, 0.0);
    }

    #[test]
    fn decay_converges_to_silence() {
        let mut waveform = Waveform::new();
        waveform.set_level(1.0);
        for _ in 0..500 {
            waveform.push_frame();
        }
        assert!(
            waveform.current < 0.001,
            "a stuck bar would look like the mic is still hot"
        );
    }

    #[test]
    fn reset_clears_every_bar() {
        let mut waveform = Waveform::new();
        waveform.set_level(1.0);
        for _ in 0..5 {
            waveform.push_frame();
        }
        waveform.reset();
        assert!(waveform.bars.iter().all(|b| *b == 0.0));
        assert_eq!(waveform.current, 0.0);
    }
}
