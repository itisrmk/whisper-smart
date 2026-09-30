//! Brand font installation.
//!
//! The macOS build registers `Archivo-Variable.ttf` at launch with
//! `CTFontManagerRegisterFontsForURL`; the Linux build has to write it into
//! the user's font directory for fontconfig. egui is the easy case: fonts are
//! loaded straight into the renderer from bytes, so the brand face ships
//! inside the binary and never touches the system at all.

use std::sync::Arc;

/// The font, compiled into the binary so every install looks the same.
const ARCHIVO: &[u8] = include_bytes!("../../resources/Archivo-Variable.ttf");

/// Installs Archivo as the primary proportional face, keeping egui's built-in
/// fonts behind it for glyph fallback (symbols, emoji, CJK).
pub fn install(ctx: &egui::Context) {
    let mut fonts = egui::FontDefinitions::default();
    fonts.font_data.insert(
        "Archivo".to_string(),
        Arc::new(egui::FontData::from_static(ARCHIVO)),
    );
    fonts
        .families
        .entry(egui::FontFamily::Proportional)
        .or_default()
        .insert(0, "Archivo".to_string());
    ctx.set_fonts(fonts);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_font_is_compiled_into_the_binary() {
        // A missing asset would silently drop the product's typeface.
        assert!(ARCHIVO.len() > 100_000, "the font asset looks truncated");
        // TrueType/OpenType magic.
        assert!(
            ARCHIVO.starts_with(&[0x00, 0x01, 0x00, 0x00]) || ARCHIVO.starts_with(b"OTTO"),
            "the font asset is not a TrueType file"
        );
    }
}
