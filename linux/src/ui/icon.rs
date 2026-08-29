//! Tray icon rendering.
//!
//! Draws the Whisper Smart brand mark — the three waveform bars and four
//! transcript lines from `app/Resources/Icons/MenuBarIcon.png` — so the Linux
//! tray shows the same logo as the macOS menu bar.
//!
//! The geometry is measured from that PNG and expressed as fractions of the
//! icon box, so it rasterises crisply at any panel height instead of being
//! resampled from a fixed bitmap. Drawing rather than decoding also avoids a
//! PNG dependency and lets the mark be recoloured, which matters because the
//! macOS icon is a *template* image that the menu bar tints to suit itself;
//! a Linux tray does no such thing, so the tint has to be applied here.
//!
//! macOS swaps the whole icon per state (`MenuBarController.updateIcon`):
//! the logo when idle, then SF Symbols for listening, transcribing, success and
//! error. The same swap happens here with drawn equivalents.

use crate::core::state_machine::State;
use crate::ui::tokens;

/// Sizes offered to the host, which picks whichever suits the panel. The
/// larger covers HiDPI bars without the host upscaling a small bitmap.
const SIZES: [i32; 2] = [22, 44];

/// Straight RGB.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rgb(pub u8, pub u8, pub u8);

/// `VFColor.accent` — the red of the brand mark's tall bar.
const ACCENT: Rgb = Rgb(
    tokens::ACCENT_RGB.0,
    tokens::ACCENT_RGB.1,
    tokens::ACCENT_RGB.2,
);
/// `VFColor.text` — the "ink" the rest of the mark is drawn in. Panels are
/// usually dark, and a dark halo keeps it readable when they are not.
const INK: Rgb = Rgb(tokens::INK_RGB.0, tokens::INK_RGB.1, tokens::INK_RGB.2);
const WARNING: Rgb = Rgb(0xFF, 0xBD, 0x57);
const SUCCESS: Rgb = Rgb(0x69, 0xDB, 0x7C);
const ERROR: Rgb = Rgb(0xFF, 0x6B, 0x6B);

/// A filled rectangle in normalised (0..1) icon coordinates.
#[derive(Debug, Clone, Copy)]
struct Rect {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    accent: bool,
}

const fn r(x: f32, y: f32, w: f32, h: f32) -> Rect {
    Rect {
        x,
        y,
        w,
        h,
        accent: false,
    }
}

const fn accent(x: f32, y: f32, w: f32, h: f32) -> Rect {
    Rect {
        x,
        y,
        w,
        h,
        accent: true,
    }
}

/// The brand mark, measured from `MenuBarIcon.png` on its 288×288 canvas and
/// divided through by 288.
const BRAND: &[Rect] = &[
    // Three waveform bars; the tall middle one is the accent.
    r(0.0833, 0.3507, 0.0833, 0.2986),
    accent(0.2153, 0.1493, 0.0833, 0.7014),
    r(0.3507, 0.2674, 0.0833, 0.4653),
    // Four transcript lines, of alternating length.
    r(0.5347, 0.1493, 0.3819, 0.0833),
    r(0.5347, 0.3507, 0.2639, 0.0833),
    r(0.5347, 0.5486, 0.3819, 0.0833),
    r(0.5347, 0.7500, 0.1979, 0.0833),
];

/// Listening: the waveform bars alone, all in the state colour.
const LISTENING: &[Rect] = &[
    accent(0.1500, 0.3200, 0.1000, 0.3600),
    accent(0.3200, 0.1200, 0.1000, 0.7600),
    accent(0.4900, 0.2600, 0.1000, 0.4800),
    accent(0.6600, 0.3800, 0.1000, 0.2400),
];

/// Transcribing: a text caret between two line fragments.
const TRANSCRIBING: &[Rect] = &[
    accent(0.1200, 0.2200, 0.7600, 0.1000),
    accent(0.1200, 0.4500, 0.4800, 0.1000),
    accent(0.4300, 0.6600, 0.1400, 0.1800),
    accent(0.1200, 0.6800, 0.2200, 0.1000),
];

/// Success: a tick, drawn as two bars.
const SUCCESS_MARK: &[Rect] = &[
    accent(0.1800, 0.5000, 0.1400, 0.3000),
    accent(0.3200, 0.6200, 0.1400, 0.1800),
    accent(0.4600, 0.4200, 0.1400, 0.2400),
    accent(0.6000, 0.2200, 0.1400, 0.2400),
];

/// Error: an exclamation mark.
const ERROR_MARK: &[Rect] = &[
    accent(0.4200, 0.1400, 0.1600, 0.4600),
    accent(0.4200, 0.6800, 0.1600, 0.1600),
];

/// The shapes and colour for a dictation state.
fn glyph(state: &State) -> (&'static [Rect], Rgb, Rgb) {
    match state {
        // Idle shows the logo: ink bars with the accent bar in brand red.
        State::Idle => (BRAND, INK, ACCENT),
        State::Recording => (LISTENING, ACCENT, ACCENT),
        State::Transcribing => (TRANSCRIBING, WARNING, WARNING),
        State::Success => (SUCCESS_MARK, SUCCESS, SUCCESS),
        State::Error(_) => (ERROR_MARK, ERROR, ERROR),
    }
}

/// One rendered pixmap: dimensions plus ARGB32 bytes in network byte order.
pub struct Pixmap {
    pub width: i32,
    pub height: i32,
    pub data: Vec<u8>,
}

/// Renders the icon for `state` at every offered size.
pub fn render_all(state: &State) -> Vec<Pixmap> {
    SIZES.iter().map(|size| render(*size, state)).collect()
}

/// Renders the icon at `size` × `size`.
pub fn render(size: i32, state: &State) -> Pixmap {
    let (shapes, ink, accent_color) = glyph(state);
    let s = size as f32;
    let mut data = vec![0u8; (size * size * 4) as usize];

    for shape in shapes {
        let color = if shape.accent { accent_color } else { ink };
        // Inset by a pixel so the mark never touches the panel edge.
        let pad = s * 0.06;
        let inner = s - pad * 2.0;
        let x0 = pad + shape.x * inner;
        let y0 = pad + shape.y * inner;
        let x1 = x0 + shape.w * inner;
        let y1 = y0 + shape.h * inner;
        fill_rect(&mut data, size, x0, y0, x1, y1, color);
    }

    Pixmap {
        width: size,
        height: size,
        data,
    }
}

/// Fills an axis-aligned rectangle with analytic antialiasing on its edges, so
/// a 22px icon keeps clean bar widths instead of shimmering.
fn fill_rect(data: &mut [u8], size: i32, x0: f32, y0: f32, x1: f32, y1: f32, color: Rgb) {
    let px_start = x0.floor().max(0.0) as i32;
    let px_end = (x1.ceil() as i32).min(size);
    let py_start = y0.floor().max(0.0) as i32;
    let py_end = (y1.ceil() as i32).min(size);

    for y in py_start..py_end {
        for x in px_start..px_end {
            // Fractional overlap of this pixel with the rectangle.
            let cover_x = (x1.min(x as f32 + 1.0) - x0.max(x as f32)).clamp(0.0, 1.0);
            let cover_y = (y1.min(y as f32 + 1.0) - y0.max(y as f32)).clamp(0.0, 1.0);
            let cover = cover_x * cover_y;
            if cover <= 0.0 {
                continue;
            }

            let i = ((y * size + x) * 4) as usize;
            let dst_a = data[i] as f32 / 255.0;
            let out_a = cover + dst_a * (1.0 - cover);
            if out_a <= 0.0 {
                continue;
            }

            // Source-over compositing against whatever is already there.
            let blend = |dst: u8, src: u8| -> u8 {
                let d = dst as f32 / 255.0;
                let sc = src as f32 / 255.0;
                let out = (sc * cover + d * dst_a * (1.0 - cover)) / out_a;
                (out * 255.0).round().clamp(0.0, 255.0) as u8
            };

            data[i + 1] = blend(data[i + 1], color.0);
            data[i + 2] = blend(data[i + 2], color.1);
            data[i + 3] = blend(data[i + 3], color.2);
            data[i] = (out_a * 255.0).round().clamp(0.0, 255.0) as u8;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn alpha_at(pixmap: &Pixmap, x: i32, y: i32) -> u8 {
        pixmap.data[((y * pixmap.width + x) * 4) as usize]
    }

    fn rgb_at(pixmap: &Pixmap, x: i32, y: i32) -> (u8, u8, u8) {
        let i = ((y * pixmap.width + x) * 4) as usize;
        (pixmap.data[i + 1], pixmap.data[i + 2], pixmap.data[i + 3])
    }

    #[test]
    fn a_pixmap_has_four_bytes_per_pixel() {
        let pixmap = render(22, &State::Idle);
        assert_eq!(pixmap.width, 22);
        assert_eq!(pixmap.data.len(), 22 * 22 * 4);
    }

    #[test]
    fn the_brand_mark_is_actually_drawn() {
        // A blank pixmap would reproduce the bug this module exists to fix: a
        // tray item that occupies a slot and shows nothing.
        let pixmap = render(44, &State::Idle);
        let solid = pixmap.data.chunks_exact(4).filter(|px| px[0] > 128).count();
        assert!(
            solid > 200,
            "only {solid} solid pixels; the mark is missing"
        );
    }

    #[test]
    fn the_idle_icon_carries_the_brand_red_bar() {
        // The tall middle bar is the one piece of colour in the logo; losing it
        // would make the mark unrecognisable next to the Mac build.
        let pixmap = render(44, &State::Idle);
        let mut found_red = false;
        for y in 0..44 {
            for x in 0..44 {
                if alpha_at(&pixmap, x, y) < 200 {
                    continue;
                }
                let (r, g, b) = rgb_at(&pixmap, x, y);
                if r > 200 && g < 120 && b < 110 {
                    found_red = true;
                }
            }
        }
        assert!(found_red, "the accent bar is missing from the brand mark");
    }

    #[test]
    fn the_idle_icon_also_carries_ink_bars() {
        let pixmap = render(44, &State::Idle);
        let mut found_ink = false;
        for y in 0..44 {
            for x in 0..44 {
                if alpha_at(&pixmap, x, y) < 200 {
                    continue;
                }
                let (r, g, b) = rgb_at(&pixmap, x, y);
                if r > 200 && g > 200 && b > 200 {
                    found_ink = true;
                }
            }
        }
        assert!(found_ink, "the ink bars are missing from the brand mark");
    }

    #[test]
    fn the_corners_stay_transparent() {
        let pixmap = render(22, &State::Idle);
        for (x, y) in [(0, 0), (21, 0), (0, 21), (21, 21)] {
            assert_eq!(
                alpha_at(&pixmap, x, y),
                0,
                "corner ({x},{y}) should be clear"
            );
        }
    }

    #[test]
    fn every_state_draws_something_different() {
        // macOS swaps the whole icon per state; so does this.
        let states = [
            State::Idle,
            State::Recording,
            State::Transcribing,
            State::Success,
            State::Error("x".into()),
        ];
        let rendered: Vec<Vec<u8>> = states.iter().map(|s| render(44, s).data).collect();
        for i in 0..rendered.len() {
            for j in (i + 1)..rendered.len() {
                assert_ne!(
                    rendered[i], rendered[j],
                    "states {i} and {j} look identical"
                );
            }
        }
    }

    #[test]
    fn every_state_renders_a_visible_glyph() {
        for state in [
            State::Idle,
            State::Recording,
            State::Transcribing,
            State::Success,
            State::Error("x".into()),
        ] {
            let pixmap = render(22, &state);
            let solid = pixmap.data.chunks_exact(4).filter(|px| px[0] > 128).count();
            assert!(solid > 8, "{state:?} renders almost nothing ({solid} px)");
        }
    }

    #[test]
    fn both_offered_sizes_render() {
        let pixmaps = render_all(&State::Idle);
        assert_eq!(pixmaps.len(), SIZES.len());
        for (pixmap, expected) in pixmaps.iter().zip(SIZES) {
            assert_eq!(pixmap.width, expected);
            assert_eq!(pixmap.data.len(), (expected * expected * 4) as usize);
        }
    }

    #[test]
    fn the_mark_stays_inside_its_box() {
        // Every shape is expressed as a fraction of the icon, so none may spill
        // outside it at any size.
        for shape in BRAND {
            assert!(
                shape.x >= 0.0 && shape.x + shape.w <= 1.0,
                "{shape:?} overflows in x"
            );
            assert!(
                shape.y >= 0.0 && shape.y + shape.h <= 1.0,
                "{shape:?} overflows in y"
            );
        }
    }
}
