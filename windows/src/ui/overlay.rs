//! Recording overlay.
//!
//! Ports `BubblePanelController` / `FloatingBubbleView` and
//! `TopCenterOverlayPanelController` / `TopCenterWaveformOverlayView`.
//!
//! On macOS these are borderless `NSPanel`s with `.floating` window level.
//! The Windows analogue is an always-on-top, undecorated, transparent
//! viewport that never appears in the taskbar and never takes focus —
//! stealing focus mid-dictation would be disastrous, since the transcript is
//! about to be typed into whatever the user was working in.

use std::time::Instant;

use egui::{Color32, RichText, Stroke};

use crate::core::settings::OverlayStyle;
use crate::core::state_machine::State;
use crate::ui::tokens;

/// Live waveform levels, smoothed for display.
pub struct Waveform {
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
    style: OverlayStyle,
    show_transcript: bool,
    state: State,
    transcript: String,
    waveform: Waveform,
    /// Last time the waveform ring advanced, for frame pacing.
    last_frame: Instant,
    /// Whether the viewport was shown last frame, so hiding is explicit.
    visible: bool,
}

impl Overlay {
    pub fn new(style: OverlayStyle, show_transcript: bool) -> Self {
        Self {
            style,
            show_transcript,
            state: State::Idle,
            transcript: String::new(),
            waveform: Waveform::new(),
            last_frame: Instant::now(),
            visible: false,
        }
    }

    pub fn apply_style(&mut self, style: OverlayStyle) {
        self.style = style;
    }

    pub fn set_show_transcript(&mut self, show: bool) {
        self.show_transcript = show;
        if !show {
            self.transcript.clear();
        }
    }

    /// Reflects a state change.
    pub fn set_state(&mut self, state: &State) {
        match state {
            State::Recording => {
                self.transcript.clear();
                self.last_frame = Instant::now();
            }
            State::Transcribing => self.waveform.reset(),
            State::Idle => self.waveform.reset(),
            _ => {}
        }
        self.state = state.clone();
    }

    pub fn set_level(&mut self, level: f32) {
        self.waveform.set_level(level as f64);
    }

    pub fn set_transcript(&mut self, text: &str) {
        if !self.show_transcript {
            return;
        }
        self.transcript = text.trim().to_string();
    }

    fn should_show(&self) -> bool {
        self.style != OverlayStyle::None && self.state != State::Idle
    }

    /// Renders the overlay viewport. Called every frame from the app.
    pub fn show(&mut self, ctx: &egui::Context) {
        if !self.should_show() {
            self.visible = false;
            return;
        }

        // Advance the waveform on its own clock, decoupled from however often
        // egui repaints.
        if self.state == State::Recording {
            let frame = std::time::Duration::from_millis(tokens::animation::WAVEFORM_FRAME_MS);
            while self.last_frame.elapsed() >= frame {
                self.waveform.push_frame();
                self.last_frame += frame;
            }
            // Keep the animation running while recording.
            ctx.request_repaint_after(frame);
        }

        let (size, top_margin, bottom_margin) = match self.style {
            OverlayStyle::Bubble => (
                egui::vec2(tokens::size::BUBBLE_WIDTH, tokens::size::BUBBLE_HEIGHT),
                None,
                Some(tokens::size::BUBBLE_MARGIN),
            ),
            OverlayStyle::TopBar => (
                egui::vec2(tokens::size::TOP_BAR_WIDTH, tokens::size::TOP_BAR_HEIGHT),
                Some(tokens::size::TOP_BAR_MARGIN),
                None,
            ),
            OverlayStyle::None => return,
        };

        // Centre horizontally on the monitor; anchor to the chosen edge. The
        // work area is not exposed, so the bubble's 96px margin doubles as
        // taskbar clearance — the same figure the macOS panel uses.
        let monitor = ctx
            .input(|i| i.viewport().monitor_size)
            .unwrap_or(egui::vec2(1920.0, 1080.0));
        let x = ((monitor.x - size.x) / 2.0).max(0.0);
        let y = match (top_margin, bottom_margin) {
            (Some(top), _) => top,
            (_, Some(bottom)) => (monitor.y - size.y - bottom).max(0.0),
            _ => 0.0,
        };

        let builder = egui::ViewportBuilder::default()
            .with_title("Whisper Smart Overlay")
            .with_inner_size(size)
            .with_position(egui::pos2(x, y))
            .with_decorations(false)
            .with_resizable(false)
            .with_transparent(true)
            .with_always_on_top()
            .with_taskbar(false)
            .with_active(false);

        let state = self.state.clone();
        let transcript = self.transcript.clone();
        let bars: Vec<f64> = self.waveform.bars.clone();
        let show_waveform = true;

        ctx.show_viewport_immediate(
            egui::ViewportId::from_hash_of("whisper-smart-overlay"),
            builder,
            move |ctx, _class| {
                egui::CentralPanel::default()
                    .frame(egui::Frame::new().fill(Color32::TRANSPARENT))
                    .show(ctx, |ui| {
                        draw_pill(ui, &state, &transcript, &bars, show_waveform);
                    });
            },
        );
        self.visible = true;
    }
}

/// Draws the overlay pill: waveform bars on the left, the state label (and
/// live transcript, when enabled) beside them, bordered in the state colour.
fn draw_pill(ui: &mut egui::Ui, state: &State, transcript: &str, bars: &[f64], waveform: bool) {
    let border = tokens::state_color(state);
    egui::Frame::new()
        .fill(tokens::overlay_fill())
        .stroke(Stroke::new(1.0_f32, border))
        .inner_margin(egui::Margin::symmetric(14, 8))
        .show(ui, |ui| {
            ui.set_min_size(ui.available_size());
            ui.horizontal_centered(|ui| {
                if waveform {
                    draw_bars(ui, bars);
                    ui.add_space(tokens::spacing::SM);
                }
                ui.vertical(|ui| {
                    ui.label(
                        RichText::new(tokens::state_label(state))
                            .color(tokens::TEXT)
                            .size(11.0)
                            .strong(),
                    );
                    if !transcript.is_empty() {
                        let mut preview = transcript.to_string();
                        // Keep the pill one line tall; the ellipsis lives at
                        // the front so the newest words stay readable.
                        const MAX: usize = 34;
                        let count = preview.chars().count();
                        if count > MAX {
                            preview = format!(
                                "…{}",
                                preview
                                    .chars()
                                    .skip(count - MAX)
                                    .collect::<String>()
                                    .trim_start()
                            );
                        }
                        ui.label(RichText::new(preview).color(tokens::MUTED).size(11.0));
                    }
                });
            });
        });
}

/// Draws the level bars, oldest on the left. Square caps: the design language
/// is zero corner radius throughout.
fn draw_bars(ui: &mut egui::Ui, bars: &[f64]) {
    let bar_w = tokens::size::WAVEFORM_BAR_WIDTH;
    let gap = tokens::size::WAVEFORM_BAR_SPACING;
    let total_w = bars.len() as f32 * (bar_w + gap) - gap;
    let (rect, _) = ui.allocate_exact_size(egui::vec2(total_w, 24.0), egui::Sense::hover());

    let painter = ui.painter();
    let mid = rect.center().y;
    let mut x = rect.min.x;
    for level in bars {
        // Height ramps between the Mac's min and max bar heights rather than
        // filling the widget, so the HUD reads the same on every platform.
        let span = tokens::size::WAVEFORM_BAR_MAX_HEIGHT - tokens::size::WAVEFORM_BAR_MIN_HEIGHT;
        let bar_h = tokens::size::WAVEFORM_BAR_MIN_HEIGHT + (*level as f32) * span;
        let bar =
            egui::Rect::from_min_size(egui::pos2(x, mid - bar_h / 2.0), egui::vec2(bar_w, bar_h));
        painter.rect_filled(bar, 0.0, tokens::TEXT.gamma_multiply(0.85));
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

    #[test]
    fn the_overlay_only_shows_outside_idle_and_when_styled() {
        let mut overlay = Overlay::new(OverlayStyle::Bubble, true);
        assert!(!overlay.should_show(), "idle must not show a pill");

        overlay.set_state(&State::Recording);
        assert!(overlay.should_show());

        overlay.apply_style(OverlayStyle::None);
        assert!(!overlay.should_show(), "style None disables the overlay");
    }

    #[test]
    fn a_new_recording_clears_the_previous_transcript() {
        let mut overlay = Overlay::new(OverlayStyle::Bubble, true);
        overlay.set_transcript("previous words");
        overlay.set_state(&State::Recording);
        assert!(overlay.transcript.is_empty());
    }

    #[test]
    fn transcripts_are_ignored_when_the_preview_is_disabled() {
        let mut overlay = Overlay::new(OverlayStyle::Bubble, false);
        overlay.set_transcript("secret words");
        assert!(overlay.transcript.is_empty());
    }
}
