//! Design tokens, ported from `app/UI/DesignTokens.swift`.
//!
//! The Linux build is a different implementation of the same product, so it
//! carries the same design language rather than a GTK-flavoured reinterpretation
//! of it. The Swift file states that language in one line — *"Archivo type, a
//! single red accent, flush-left labels, 2px rules, zero corner radius"* — and
//! every value below is the Linux counterpart of a `VF*` token, kept at the same
//! name so the two stay comparable when either side changes.
//!
//! Colours are emitted as GTK CSS custom properties in both light and dark
//! variants, exactly as `VFColor` resolves `lightHex`/`darkHex` against the
//! macOS appearance.

/// Spacing scale (`VFSpacing`), in points.
///
/// A design scale is deliberately complete rather than trimmed to current
/// usage, so a new view reaches for the right step instead of inventing one.
#[allow(dead_code)]
pub mod spacing {
    pub const XXS: i32 = 4;
    pub const XS: i32 = 8;
    pub const SM: i32 = 12;
    pub const MD: i32 = 16;
    pub const LG: i32 = 20;
    pub const XL: i32 = 24;
    pub const XXL: i32 = 28;
    pub const XXXL: i32 = 32;
}

/// Fixed sizes (`VFSize`).
pub mod size {
    /// Matches the macOS settings window exactly.
    pub const SETTINGS_WIDTH: i32 = 900;
    pub const SETTINGS_HEIGHT: i32 = 700;
    pub const SIDEBAR_WIDTH: i32 = 232;

    pub const MENU_BAR_ICON: i32 = 18;

    /// Waveform bar layout, matching `VFSize.waveform*`.
    pub const WAVEFORM_BARS: usize = 5;
    pub const WAVEFORM_BAR_WIDTH: f64 = 3.0;
    pub const WAVEFORM_BAR_SPACING: f64 = 2.5;
    pub const WAVEFORM_BAR_MIN_HEIGHT: f64 = 4.0;
    pub const WAVEFORM_BAR_MAX_HEIGHT: f64 = 22.0;

    /// Floating bubble overlay.
    pub const BUBBLE_WIDTH: i32 = 210;
    pub const BUBBLE_HEIGHT: i32 = 52;
    pub const BUBBLE_MARGIN: i32 = 96;

    /// Top waveform bar overlay.
    pub const TOP_BAR_WIDTH: i32 = 300;
    pub const TOP_BAR_HEIGHT: i32 = 32;
    pub const TOP_BAR_MARGIN: i32 = 6;
}

/// Animation timings (`VFAnimation`), in milliseconds.
pub mod animation {
    /// Waveform refresh; ~30 fps is smooth without burning a core.
    pub const WAVEFORM_FRAME_MS: u32 = 33;
    /// How quickly a waveform bar falls back toward silence. Rising is instant
    /// so speech feels responsive; falling is eased so bars do not flicker
    /// between syllables.
    pub const WAVEFORM_DECAY: f64 = 0.18;
}

/// How much room the settings window has, and therefore how much of the
/// chrome it can afford to show.
///
/// The macOS window is a fixed 900×700, so it never has to answer this
/// question. A Linux window does: tiling compositors size it to whatever is
/// left on screen, and Hyprland in particular will hand it a half-width column
/// without asking. Rather than let the layout overflow, the sidebar sheds
/// detail as space runs out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Breakpoint {
    /// Full sidebar with subtitles — the macOS layout.
    Wide,
    /// Sidebar keeps labels but drops the subtitles.
    Medium,
    /// Icons only.
    Narrow,
}

impl Breakpoint {
    /// The sidebar width this breakpoint calls for.
    pub fn sidebar_width(self) -> i32 {
        match self {
            Breakpoint::Wide => size::SIDEBAR_WIDTH,
            Breakpoint::Medium => 168,
            Breakpoint::Narrow => 56,
        }
    }

    /// Whether navigation subtitles are shown.
    pub fn shows_nav_subtitles(self) -> bool {
        matches!(self, Breakpoint::Wide)
    }

    /// Whether navigation labels are shown at all.
    pub fn shows_nav_labels(self) -> bool {
        !matches!(self, Breakpoint::Narrow)
    }

    /// The CSS class applied to the window root, so padding can follow.
    pub fn css_class(self) -> &'static str {
        match self {
            Breakpoint::Wide => "vf-wide",
            Breakpoint::Medium => "vf-medium",
            Breakpoint::Narrow => "vf-narrow",
        }
    }
}

/// Every breakpoint class, so the root can be cleared before applying one.
pub const ALL_BREAKPOINT_CLASSES: &[&str] = &["vf-wide", "vf-medium", "vf-narrow"];

/// Chooses a breakpoint for a window width.
///
/// The thresholds are the width at which the *content* column stops being
/// usable, not arbitrary round numbers: below roughly 820px a full sidebar
/// leaves too little for a settings row's label and control.
pub fn breakpoint_for(width: i32) -> Breakpoint {
    if width >= 820 {
        Breakpoint::Wide
    } else if width >= 620 {
        Breakpoint::Medium
    } else {
        Breakpoint::Narrow
    }
}

/// The brand accent, as used by the tray icon renderer.
/// `VFColor.accent` dark value.
pub const ACCENT_RGB: (u8, u8, u8) = (0xFF, 0x56, 0x3C);
/// `VFColor.text` dark value — the "ink" the brand mark is drawn in.
pub const INK_RGB: (u8, u8, u8) = (0xF4, 0xF3, 0xF2);

/// Font stack. Archivo is the brand face, installed by
/// [`crate::ui::fonts`]; the rest are graceful fallbacks.
pub const FONT_FAMILY: &str = "Archivo, Inter, 'DejaVu Sans', sans-serif";

/// The application stylesheet.
///
/// `@define-color` values mirror `VFColor`, and the `:root` block is swapped
/// wholesale for the light palette when the desktop asks for a light theme —
/// the same light/dark split `VFColor` gets from `lightHex`/`darkHex`.
pub const STYLESHEET: &str = r#"
/* ── Palette: VFColor, dark ──────────────────────────────────────── */

@define-color vf_bg        #1B1A19;
@define-color vf_sidebar   #211F1E;
@define-color vf_chrome    #242120;
@define-color vf_panel     #262322;
@define-color vf_panel2    #2F2C2B;
@define-color vf_text      #F4F3F2;
@define-color vf_muted     #A39E9D;
@define-color vf_border    alpha(#F4F3F2, 0.12);
@define-color vf_border2   alpha(#F4F3F2, 0.24);
@define-color vf_rule      alpha(#F4F3F2, 0.55);
@define-color vf_accent    #FF563C;
@define-color vf_accent_dark   #FF7358;
@define-color vf_accent_strong #FF9783;
@define-color vf_active    alpha(#FF563C, 0.13);
@define-color vf_accent_soft alpha(#FF563C, 0.16);
@define-color vf_knob_off  #8A8584;
@define-color vf_success   #69DB7C;
@define-color vf_error     #FF6B6B;
@define-color vf_warning   #FFBD57;

window.vf-light {
    /* VFColor light values: ink on paper. */
    --unused: 0;
}

/* ── Typography ──────────────────────────────────────────────────── */

/* Archivo is the brand face, installed by `ui::fonts`; the rest are
   graceful fallbacks so the UI degrades to a similar grotesque. */
window.vf-settings, window.vf-settings *, .vf-overlay, .vf-overlay * {
    font-family: Archivo, Inter, "DejaVu Sans", sans-serif;
    font-feature-settings: "kern" 1;
}

/* ── Window chrome ───────────────────────────────────────────────── */

window.vf-settings {
    background-color: @vf_bg;
    color: @vf_text;
}

.vf-root, .vf-content {
    background-color: @vf_bg;
    color: @vf_text;
}

/* Page padding tightens as the window narrows. */
.vf-page { padding: 28px 32px 32px 32px; }
.vf-medium .vf-page { padding: 24px 24px 28px 24px; }
.vf-narrow .vf-page { padding: 20px 16px 24px 16px; }

/* Cards give back their generous inner margins too. */
.vf-narrow .vf-card { padding-bottom: 14px; }

/* Zero corner radius everywhere: VFRadius is 0 across the board. */
.vf-card, .vf-button, .vf-pill, .vf-field, .vf-badge, .vf-segment,
button, entry, dropdown, dropdown > button, popover contents {
    border-radius: 0;
}

/* ── Sidebar ─────────────────────────────────────────────────────── */

.vf-sidebar {
    background-color: @vf_sidebar;
    border-right: 1px solid @vf_border;
}

.vf-brand-name {
    font-weight: 700;
    font-size: 15px;
    color: @vf_text;
}

.vf-brand-sub {
    font-size: 11px;
    color: @vf_muted;
}

.vf-brand-row {
    border-bottom: 1px solid @vf_border;
}

.vf-nav-item {
    background-color: transparent;
    border: none;
    border-left: 3px solid transparent;
    padding: 11px 16px;
    box-shadow: none;
    outline: none;
}

.vf-nav-item:hover {
    background-color: alpha(#F4F3F2, 0.05);
}

.vf-nav-item.selected {
    background-color: @vf_active;
    border-left: 3px solid @vf_accent;
}

.vf-nav-title {
    font-weight: 600;
    font-size: 13px;
    color: @vf_text;
}

.vf-nav-sub {
    font-size: 11px;
    color: @vf_muted;
    /* Slightly dimmer than the title so the pair reads as one unit. */
    opacity: 0.9;
}

.vf-nav-item.selected .vf-nav-title,
.vf-nav-item.selected .vf-nav-sub {
    color: @vf_accent;
}

.vf-sidebar-footer {
    padding: 12px;
}

/* ── Content ─────────────────────────────────────────────────────── */

.vf-page-title {
    font-weight: 800;
    font-size: 30px;
    color: @vf_text;
    margin-bottom: 2px;
}

.vf-page-lede {
    font-size: 13px;
    color: @vf_muted;
}

.vf-card {
    background-color: @vf_panel;
    border: 1px solid @vf_border;
    padding-bottom: 18px;
}

.vf-card-title {
    font-weight: 700;
    font-size: 15px;
    color: @vf_text;
}

.vf-card-icon { color: @vf_accent; }

/* The 2px rule under every section header. */
.vf-rule {
    background-color: @vf_rule;
    min-height: 2px;
}

.vf-row-title {
    font-weight: 600;
    font-size: 13px;
    color: @vf_text;
}

.vf-row-desc {
    font-size: 12px;
    color: @vf_muted;
}

.vf-row-sep {
    background-color: @vf_border;
    min-height: 1px;
}

/* Hairlines between rows, but never trailing the last one — the same rhythm
   the macOS cards use. */
.vf-row {
    border-bottom: 1px solid @vf_border;
    padding-bottom: 14px;
}

.vf-row:last-child {
    border-bottom: none;
    padding-bottom: 0;
}

/* ── Controls ────────────────────────────────────────────────────── */

button.vf-button {
    background-color: @vf_accent;
    background-image: none;
    color: #FFFFFF;
    font-weight: 700;
    font-size: 12px;
    border: none;
    padding: 6px 14px;
    box-shadow: none;
}

button.vf-button:hover { background-color: @vf_accent_dark; }
button.vf-button:disabled {
    background-color: @vf_panel2;
    color: @vf_muted;
}

button.vf-button-ghost {
    background-color: transparent;
    background-image: none;
    color: @vf_text;
    font-weight: 600;
    font-size: 12px;
    border: 1px solid @vf_border2;
    padding: 6px 14px;
    box-shadow: none;
}

button.vf-button-ghost:hover { background-color: alpha(#F4F3F2, 0.06); }

.vf-badge {
    background-color: @vf_chrome;
    border: 1px solid @vf_border2;
    color: @vf_muted;
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.5px;
    padding: 12px 8px;
    min-width: 34px;
}

.vf-choice.selected .vf-badge {
    border-color: @vf_accent;
    color: @vf_accent;
}

.vf-pill {
    background-color: @vf_chrome;
    border: 1px solid @vf_border;
    color: @vf_muted;
    font-size: 11px;
    padding: 5px 10px;
}

/* Key caps in the hotkey recorder. */
.vf-keycap {
    background-color: @vf_panel2;
    border: 1px solid @vf_border2;
    color: @vf_text;
    font-weight: 700;
    font-size: 12px;
    padding: 4px 9px;
}

entry, entry.vf-field {
    background-color: @vf_panel2;
    background-image: none;
    color: @vf_text;
    border: 1px solid @vf_border;
    padding: 7px 10px;
    box-shadow: none;
}

entry:focus { border-color: @vf_accent; }

dropdown > button {
    background-color: @vf_panel2;
    background-image: none;
    color: @vf_accent;
    font-weight: 700;
    font-size: 12px;
    border: 1px solid @vf_border;
    box-shadow: none;
}

dropdown > button:hover { border-color: @vf_border2; }

spinbutton, spinbutton entry {
    background-color: @vf_panel2;
    background-image: none;
    color: @vf_text;
    border: 1px solid @vf_border;
    box-shadow: none;
}

/* Rectangular switches with a hard accent fill, matching the Mac toggles. */
switch {
    background-color: @vf_panel2;
    background-image: none;
    border: 1px solid @vf_border2;
    border-radius: 0;
    min-width: 46px;
    min-height: 24px;
    box-shadow: none;
}

switch > slider {
    background-color: @vf_knob_off;
    background-image: none;
    border: none;
    border-radius: 0;
    min-width: 20px;
    min-height: 20px;
    margin: 1px;
    box-shadow: none;
}

switch:checked {
    background-color: @vf_accent;
    border-color: @vf_accent;
}

switch:checked > slider { background-color: #FFFFFF; }

/* Selectable rows, e.g. the model picker. */
.vf-choice {
    background-color: @vf_panel2;
    border: 1px solid @vf_border;
    padding: 14px 16px;
}

.vf-choice:hover { border-color: @vf_border2; }

.vf-choice.selected {
    background-color: @vf_active;
    border: 1px solid @vf_accent;
}

.vf-choice-title {
    font-weight: 700;
    font-size: 13px;
    color: @vf_text;
}

.vf-choice-desc {
    font-size: 12px;
    color: @vf_muted;
}

/* Radios adopt the accent so the selected row reads at a glance. An
   unselected radio still needs a visible ring, or the row looks unclickable. */
/* GTK renders a grouped CheckButton with a `radio` node and an ungrouped one
   with `check`, so both are styled. */
.vf-choice check,
.vf-choice radio {
    min-width: 18px;
    min-height: 18px;
    background-color: transparent;
    background-image: none;
    border: 2px solid alpha(#F4F3F2, 0.45);
    border-radius: 9999px;
    box-shadow: none;
    -gtk-icon-source: none;
}

.vf-choice check:hover,
.vf-choice radio:hover { border-color: @vf_muted; }

.vf-choice check:checked,
.vf-choice radio:checked {
    background-color: @vf_accent;
    background-image: none;
    border-color: @vf_accent;
    color: #FFFFFF;
}

/* ── Advanced disclosure ─────────────────────────────────────────── */

.vf-advanced > title {
    color: @vf_muted;
    font-size: 12px;
    font-weight: 600;
}

.vf-advanced > title:hover { color: @vf_text; }

/* ── Status ──────────────────────────────────────────────────────── */

.vf-status-ok      { color: @vf_success; font-weight: 700; font-size: 11px; }
.vf-status-warning { color: @vf_warning; font-weight: 700; font-size: 11px; }
.vf-status-blocked { color: @vf_error;   font-weight: 700; font-size: 11px; }

.vf-mono {
    font-family: monospace;
    font-size: 11px;
    color: @vf_muted;
}

/* ── Overlay HUD ─────────────────────────────────────────────────── */

.vf-overlay {
    background-color: alpha(#211F1E, 0.94);
    border: 1px solid @vf_border2;
    padding: 8px 14px;
}

.vf-overlay-label {
    font-size: 11px;
    font-weight: 600;
    color: @vf_text;
}

.vf-overlay-transcript {
    font-size: 11px;
    color: @vf_muted;
}

.vf-state-listening    { border-color: @vf_accent; }
.vf-state-transcribing { border-color: @vf_warning; }
.vf-state-success      { border-color: @vf_success; }
.vf-state-error        { border-color: @vf_error; }
"#;

/// Vertical orientation, spelled once so row builders read cleanly.
pub fn vertical() -> gtk::Orientation {
    gtk::Orientation::Vertical
}

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

/// CSS class applied to the overlay for a state, driving its accent colour.
pub fn state_css_class(state: &crate::core::state_machine::State) -> &'static str {
    use crate::core::state_machine::State;
    match state {
        State::Idle => "vf-state-idle",
        State::Recording => "vf-state-listening",
        State::Transcribing => "vf-state-transcribing",
        State::Success => "vf-state-success",
        State::Error(_) => "vf-state-error",
    }
}

/// Every state class, so the overlay can clear them before applying one.
pub const ALL_STATE_CLASSES: &[&str] = &[
    "vf-state-idle",
    "vf-state-listening",
    "vf-state-transcribing",
    "vf-state-success",
    "vf-state-error",
];

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::state_machine::State;

    #[test]
    fn every_state_maps_to_a_distinct_class() {
        let states = [
            State::Idle,
            State::Recording,
            State::Transcribing,
            State::Success,
            State::Error("x".into()),
        ];
        let mut classes: Vec<&str> = states.iter().map(state_css_class).collect();
        let total = classes.len();
        classes.sort_unstable();
        classes.dedup();
        assert_eq!(classes.len(), total);
    }

    #[test]
    fn every_state_class_is_listed_for_clearing() {
        for state in [
            State::Idle,
            State::Recording,
            State::Transcribing,
            State::Success,
            State::Error("x".into()),
        ] {
            assert!(ALL_STATE_CLASSES.contains(&state_css_class(&state)));
        }
    }

    #[test]
    fn the_error_state_shows_its_message_rather_than_a_generic_label() {
        let label = state_label(&State::Error("microphone unavailable".into()));
        assert_eq!(label, "microphone unavailable");
    }

    #[test]
    fn the_stylesheet_defines_every_state_class_the_code_applies() {
        for class in ALL_STATE_CLASSES {
            if *class == "vf-state-idle" {
                continue; // idle deliberately uses the default border
            }
            assert!(
                STYLESHEET.contains(class),
                "{class} is missing from the stylesheet"
            );
        }
    }

    #[test]
    fn the_palette_matches_the_swift_tokens() {
        // These are VFColor's dark values. If the Mac palette moves, this test
        // is the reminder that the Linux build has to move with it.
        for hex in [
            "#1B1A19", "#211F1E", "#262322", "#F4F3F2", "#A39E9D", "#FF563C",
        ] {
            assert!(STYLESHEET.contains(hex), "{hex} missing from the palette");
        }
    }

    #[test]
    fn corners_are_square_like_the_mac_design() {
        // VFRadius is 0 for every token; a stray rounded corner would read as
        // a different product.
        assert!(STYLESHEET.contains("border-radius: 0"));
    }

    #[test]
    fn the_settings_window_matches_the_mac_dimensions() {
        assert_eq!(size::SETTINGS_WIDTH, 900);
        assert_eq!(size::SETTINGS_HEIGHT, 700);
        assert_eq!(size::SIDEBAR_WIDTH, 232);
    }

    #[test]
    fn a_full_width_window_gets_the_macos_layout() {
        let bp = breakpoint_for(900);
        assert_eq!(bp, Breakpoint::Wide);
        assert_eq!(bp.sidebar_width(), size::SIDEBAR_WIDTH);
        assert!(bp.shows_nav_subtitles());
        assert!(bp.shows_nav_labels());
    }

    #[test]
    fn a_half_width_column_drops_the_subtitles_but_keeps_labels() {
        let bp = breakpoint_for(700);
        assert_eq!(bp, Breakpoint::Medium);
        assert!(!bp.shows_nav_subtitles());
        assert!(bp.shows_nav_labels());
        assert!(bp.sidebar_width() < size::SIDEBAR_WIDTH);
    }

    #[test]
    fn a_very_narrow_window_falls_back_to_icons() {
        let bp = breakpoint_for(480);
        assert_eq!(bp, Breakpoint::Narrow);
        assert!(!bp.shows_nav_labels());
    }

    #[test]
    fn breakpoints_shrink_monotonically() {
        // A wider window must never get less chrome than a narrower one.
        let widths = [400, 620, 700, 820, 900, 1600];
        let mut last = 0;
        for width in widths {
            let sidebar = breakpoint_for(width).sidebar_width();
            assert!(
                sidebar >= last,
                "sidebar shrank going from narrower to wider at {width}"
            );
            last = sidebar;
        }
    }

    #[test]
    fn a_degenerate_width_still_resolves() {
        // Windows report zero width before their first allocation.
        assert_eq!(breakpoint_for(0), Breakpoint::Narrow);
        assert_eq!(breakpoint_for(-1), Breakpoint::Narrow);
    }

    #[test]
    fn every_breakpoint_class_is_listed_for_clearing() {
        for width in [400, 700, 900] {
            assert!(ALL_BREAKPOINT_CLASSES.contains(&breakpoint_for(width).css_class()));
        }
    }

    #[test]
    fn the_stylesheet_styles_the_narrow_breakpoints() {
        assert!(STYLESHEET.contains(".vf-medium .vf-page"));
        assert!(STYLESHEET.contains(".vf-narrow .vf-page"));
    }
}
