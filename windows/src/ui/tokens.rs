//! Design tokens, ported from `app/UI/DesignTokens.swift`.
//!
//! The Windows build is a different implementation of the same product, so it
//! carries the same design language rather than an egui-flavoured
//! reinterpretation of it. The Swift file states that language in one line —
//! *"Archivo type, a single red accent, flush-left labels, 2px rules, zero
//! corner radius"* — and every value below is the Windows counterpart of a
//! `VF*` token, kept at the same name so the builds stay comparable when any
//! side changes.

use egui::Color32;

/// Spacing scale (`VFSpacing`), in points.
///
/// A design scale is deliberately complete rather than trimmed to current
/// usage, so a new view reaches for the right step instead of inventing one.
#[allow(dead_code)]
pub mod spacing {
    pub const XXS: f32 = 4.0;
    pub const XS: f32 = 8.0;
    pub const SM: f32 = 12.0;
    pub const MD: f32 = 16.0;
    pub const LG: f32 = 20.0;
    pub const XL: f32 = 24.0;
    pub const XXL: f32 = 28.0;
    pub const XXXL: f32 = 32.0;
}

/// Fixed sizes (`VFSize`).
pub mod size {
    /// Matches the macOS settings window exactly.
    pub const SETTINGS_WIDTH: f32 = 900.0;
    pub const SETTINGS_HEIGHT: f32 = 700.0;
    pub const SIDEBAR_WIDTH: f32 = 232.0;

    /// Waveform bar layout, matching `VFSize.waveform*`.
    pub const WAVEFORM_BARS: usize = 5;
    pub const WAVEFORM_BAR_WIDTH: f32 = 3.0;
    pub const WAVEFORM_BAR_SPACING: f32 = 2.5;
    pub const WAVEFORM_BAR_MIN_HEIGHT: f32 = 4.0;
    pub const WAVEFORM_BAR_MAX_HEIGHT: f32 = 22.0;

    /// Floating bubble overlay.
    pub const BUBBLE_WIDTH: f32 = 210.0;
    pub const BUBBLE_HEIGHT: f32 = 52.0;
    pub const BUBBLE_MARGIN: f32 = 96.0;

    /// Top waveform bar overlay.
    pub const TOP_BAR_WIDTH: f32 = 300.0;
    pub const TOP_BAR_HEIGHT: f32 = 32.0;
    pub const TOP_BAR_MARGIN: f32 = 6.0;
}

/// Animation timings (`VFAnimation`), in milliseconds.
pub mod animation {
    /// Waveform refresh; ~30 fps is smooth without burning a core.
    pub const WAVEFORM_FRAME_MS: u64 = 33;
    /// How quickly a waveform bar falls back toward silence. Rising is instant
    /// so speech feels responsive; falling is eased so bars do not flicker
    /// between syllables.
    pub const WAVEFORM_DECAY: f64 = 0.18;
}

// ---------------------------------------------------------------------------
// Palette: VFColor, dark
// ---------------------------------------------------------------------------

pub const BG: Color32 = Color32::from_rgb(0x1B, 0x1A, 0x19);
pub const SIDEBAR: Color32 = Color32::from_rgb(0x21, 0x1F, 0x1E);
pub const CHROME: Color32 = Color32::from_rgb(0x24, 0x21, 0x20);
pub const PANEL: Color32 = Color32::from_rgb(0x26, 0x23, 0x22);
pub const PANEL2: Color32 = Color32::from_rgb(0x2F, 0x2C, 0x2B);
pub const TEXT: Color32 = Color32::from_rgb(0xF4, 0xF3, 0xF2);
pub const MUTED: Color32 = Color32::from_rgb(0xA3, 0x9E, 0x9D);
pub const ACCENT: Color32 = Color32::from_rgb(0xFF, 0x56, 0x3C);
pub const ACCENT_DARK: Color32 = Color32::from_rgb(0xFF, 0x73, 0x58);
#[allow(dead_code)]
pub const ACCENT_STRONG: Color32 = Color32::from_rgb(0xFF, 0x97, 0x83);
pub const KNOB_OFF: Color32 = Color32::from_rgb(0x8A, 0x85, 0x84);
pub const SUCCESS: Color32 = Color32::from_rgb(0x69, 0xDB, 0x7C);
pub const ERROR: Color32 = Color32::from_rgb(0xFF, 0x6B, 0x6B);
pub const WARNING: Color32 = Color32::from_rgb(0xFF, 0xBD, 0x57);

/// `alpha(#F4F3F2, 0.12)` — hairline borders.
pub fn border() -> Color32 {
    TEXT.gamma_multiply(0.12)
}

/// `alpha(#F4F3F2, 0.24)` — stronger outlines (ghost buttons, badges).
pub fn border2() -> Color32 {
    TEXT.gamma_multiply(0.24)
}

/// `alpha(#F4F3F2, 0.55)` — the heavy 2px rule under section headers.
pub fn rule() -> Color32 {
    TEXT.gamma_multiply(0.55)
}

/// `alpha(#FF563C, 0.13)` — the selected-navigation background.
pub fn active() -> Color32 {
    ACCENT.gamma_multiply(0.13)
}

/// `alpha(#FF563C, 0.16)` — soft accent hover fills.
pub fn accent_soft() -> Color32 {
    ACCENT.gamma_multiply(0.16)
}

/// `alpha(#211F1E, 0.94)` — the overlay pill's fill.
pub fn overlay_fill() -> Color32 {
    SIDEBAR.gamma_multiply(0.94)
}

/// The brand accent, as used by the tray icon renderer.
/// `VFColor.accent` dark value.
pub const ACCENT_RGB: (u8, u8, u8) = (0xFF, 0x56, 0x3C);
/// `VFColor.text` dark value — the "ink" the brand mark is drawn in.
pub const INK_RGB: (u8, u8, u8) = (0xF4, 0xF3, 0xF2);

// ---------------------------------------------------------------------------
// Global style
// ---------------------------------------------------------------------------

/// Applies the design language to an egui context: the dark palette, zero
/// corner radius everywhere (`VFRadius` is 0 across the board), and quiet
/// selection colours.
pub fn apply_style(ctx: &egui::Context) {
    let mut style = (*ctx.style()).clone();

    let zero = egui::CornerRadius::ZERO;
    let visuals = &mut style.visuals;
    visuals.dark_mode = true;
    visuals.override_text_color = Some(TEXT);
    visuals.panel_fill = BG;
    visuals.window_fill = BG;
    visuals.extreme_bg_color = PANEL2;
    visuals.faint_bg_color = PANEL;
    visuals.selection.bg_fill = accent_soft();
    visuals.selection.stroke = egui::Stroke::new(1.0_f32, ACCENT);
    visuals.hyperlink_color = ACCENT;
    visuals.window_corner_radius = zero;
    visuals.menu_corner_radius = zero;
    visuals.window_stroke = egui::Stroke::new(1.0_f32, border());

    for widget in [
        &mut visuals.widgets.noninteractive,
        &mut visuals.widgets.inactive,
        &mut visuals.widgets.hovered,
        &mut visuals.widgets.active,
        &mut visuals.widgets.open,
    ] {
        widget.corner_radius = zero;
    }
    visuals.widgets.noninteractive.bg_stroke = egui::Stroke::new(1.0_f32, border());
    visuals.widgets.noninteractive.fg_stroke = egui::Stroke::new(1.0_f32, TEXT);
    visuals.widgets.inactive.bg_fill = PANEL2;
    visuals.widgets.inactive.weak_bg_fill = PANEL2;
    visuals.widgets.inactive.bg_stroke = egui::Stroke::new(1.0_f32, border());
    visuals.widgets.inactive.fg_stroke = egui::Stroke::new(1.0_f32, TEXT);
    visuals.widgets.hovered.bg_fill = PANEL2;
    visuals.widgets.hovered.weak_bg_fill = PANEL2;
    visuals.widgets.hovered.bg_stroke = egui::Stroke::new(1.0_f32, border2());
    visuals.widgets.hovered.fg_stroke = egui::Stroke::new(1.0_f32, TEXT);
    visuals.widgets.active.bg_fill = accent_soft();
    visuals.widgets.active.weak_bg_fill = accent_soft();
    visuals.widgets.active.bg_stroke = egui::Stroke::new(1.0_f32, ACCENT);
    visuals.widgets.active.fg_stroke = egui::Stroke::new(1.0_f32, TEXT);
    visuals.widgets.open.bg_fill = PANEL2;
    visuals.widgets.open.bg_stroke = egui::Stroke::new(1.0_f32, border2());

    style.spacing.item_spacing = egui::vec2(spacing::XS, spacing::XS);
    style.spacing.button_padding = egui::vec2(14.0, 6.0);

    ctx.set_style(style);
}

// ---------------------------------------------------------------------------
// State presentation
// ---------------------------------------------------------------------------

/// Short label for a dictation state, shown in the overlay and the tooltip.
pub fn state_label(state: &crate::core::state_machine::State) -> String {
    use crate::core::state_machine::State;
    match state {
        State::Idle => "Ready".to_string(),
        State::Recording => "Listening…".to_string(),
        State::Transcribing => "Transcribing…".to_string(),
        State::Success => "Inserted".to_string(),
        State::Error(message) => message.clone(),
    }
}

/// Accent colour for a state, driving the overlay border and tray icon —
/// the counterpart of the Linux build's `vf-state-*` CSS classes.
pub fn state_color(state: &crate::core::state_machine::State) -> Color32 {
    use crate::core::state_machine::State;
    match state {
        State::Idle => border2(),
        State::Recording => ACCENT,
        State::Transcribing => WARNING,
        State::Success => SUCCESS,
        State::Error(_) => ERROR,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::state_machine::State;

    #[test]
    fn the_palette_matches_the_swift_tokens() {
        // These are VFColor's dark values. If the Mac palette moves, this test
        // is the reminder that the Windows build has to move with it.
        assert_eq!(BG, Color32::from_rgb(0x1B, 0x1A, 0x19));
        assert_eq!(SIDEBAR, Color32::from_rgb(0x21, 0x1F, 0x1E));
        assert_eq!(PANEL, Color32::from_rgb(0x26, 0x23, 0x22));
        assert_eq!(TEXT, Color32::from_rgb(0xF4, 0xF3, 0xF2));
        assert_eq!(MUTED, Color32::from_rgb(0xA3, 0x9E, 0x9D));
        assert_eq!(ACCENT, Color32::from_rgb(0xFF, 0x56, 0x3C));
    }

    #[test]
    fn the_settings_window_matches_the_mac_dimensions() {
        assert_eq!(size::SETTINGS_WIDTH, 900.0);
        assert_eq!(size::SETTINGS_HEIGHT, 700.0);
        assert_eq!(size::SIDEBAR_WIDTH, 232.0);
    }

    #[test]
    fn every_state_maps_to_a_distinct_colour() {
        let states = [
            State::Idle,
            State::Recording,
            State::Transcribing,
            State::Success,
            State::Error("x".into()),
        ];
        let mut colors: Vec<Color32> = states.iter().map(state_color).collect();
        let total = colors.len();
        colors.sort_by_key(|c| c.to_array());
        colors.dedup();
        assert_eq!(colors.len(), total);
    }

    #[test]
    fn the_error_state_shows_its_message_rather_than_a_generic_label() {
        let label = state_label(&State::Error("microphone unavailable".into()));
        assert_eq!(label, "microphone unavailable");
    }

    #[test]
    fn the_waveform_geometry_matches_the_other_builds() {
        assert_eq!(size::WAVEFORM_BARS, 5);
        assert_eq!(size::WAVEFORM_BAR_WIDTH, 3.0);
        assert_eq!(size::WAVEFORM_BAR_SPACING, 2.5);
        assert_eq!(size::WAVEFORM_BAR_MIN_HEIGHT, 4.0);
        assert_eq!(size::WAVEFORM_BAR_MAX_HEIGHT, 22.0);
    }
}
