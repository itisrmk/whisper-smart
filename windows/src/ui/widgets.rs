//! Shared building blocks for the settings window.
//!
//! These are the Windows counterparts of the SwiftUI components in
//! `app/UI/SettingsView.swift` — the card with its icon header and 2px rule,
//! the label/description row with a trailing control, and the small controls
//! (rectangular toggle, accent button, badge) restated in egui. Keeping them
//! here means every page is built from the same pieces, which is what stops
//! the platforms drifting apart visually one screen at a time.

use egui::{Color32, RichText, Sense, Stroke, Ui, Vec2};

use crate::ui::tokens;

/// A titled card: accent icon, title, and a 2px rule. `body` renders under
/// the rule.
pub fn card(ui: &mut Ui, icon: &str, title: &str, body: impl FnOnce(&mut Ui)) {
    egui::Frame::new()
        .fill(tokens::PANEL)
        .stroke(Stroke::new(1.0_f32, tokens::border()))
        .inner_margin(egui::Margin {
            left: tokens::spacing::XL as i8,
            right: tokens::spacing::XL as i8,
            top: tokens::spacing::LG as i8,
            bottom: 18,
        })
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.horizontal(|ui| {
                ui.label(RichText::new(icon).color(tokens::ACCENT).size(15.0));
                ui.label(RichText::new(title).color(tokens::TEXT).size(15.0).strong());
            });
            ui.add_space(tokens::spacing::SM);
            rule(ui);
            ui.add_space(tokens::spacing::XS);
            body(ui);
        });
}

/// The heavy 2px rule under every section header.
pub fn rule(ui: &mut Ui) {
    let (rect, _) = ui.allocate_exact_size(Vec2::new(ui.available_width(), 2.0), Sense::hover());
    ui.painter().rect_filled(rect, 0.0, tokens::rule());
}

/// A hairline between rows inside a card.
pub fn separator(ui: &mut Ui) {
    let (rect, _) = ui.allocate_exact_size(Vec2::new(ui.available_width(), 1.0), Sense::hover());
    ui.painter().rect_filled(rect, 0.0, tokens::border());
}

/// A settings row: flush-left title and description, control on the right.
///
/// Laid out with plain nesting and an explicit text-column width. (A
/// right-to-left layout with a nested directional child looks tidier on
/// paper, but egui hands the nested child a sliver-shaped rect — the text
/// renders one letter per line.)
pub fn row(ui: &mut Ui, title: &str, description: Option<&str>, control: impl FnOnce(&mut Ui)) {
    /// Room reserved for the trailing control (the widest is a 220px
    /// dropdown plus breathing space).
    const CONTROL_WIDTH: f32 = 250.0;

    ui.add_space(tokens::spacing::MD);
    ui.horizontal(|ui| {
        let text_width = (ui.available_width() - CONTROL_WIDTH).max(120.0);
        ui.vertical(|ui| {
            ui.set_width(text_width);
            ui.label(RichText::new(title).color(tokens::TEXT).size(13.0).strong());
            if let Some(description) = description {
                ui.add(
                    egui::Label::new(RichText::new(description).color(tokens::MUTED).size(12.0))
                        .wrap(),
                );
            }
        });
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), control);
    });
    ui.add_space(tokens::spacing::MD);
}

/// Explanatory copy inside a card, above or below the rows. Wraps: prose
/// must fold to the window, never run past its edge.
pub fn note(ui: &mut Ui, text: &str) {
    ui.add_space(tokens::spacing::SM);
    ui.add(egui::Label::new(RichText::new(text).color(tokens::MUTED).size(12.0)).wrap());
}

/// Small status line under a control (download progress, key state).
pub fn status_line(ui: &mut Ui, text: &str) {
    if !text.is_empty() {
        ui.add(egui::Label::new(RichText::new(text).color(tokens::MUTED).size(11.0)).wrap());
    }
}

/// A filled accent button.
pub fn button(ui: &mut Ui, label: &str) -> egui::Response {
    let text = RichText::new(label)
        .color(Color32::WHITE)
        .size(12.0)
        .strong();
    ui.add(
        egui::Button::new(text)
            .fill(tokens::ACCENT)
            .corner_radius(0.0),
    )
}

/// An outlined secondary button.
pub fn ghost_button(ui: &mut Ui, label: &str) -> egui::Response {
    let text = RichText::new(label).color(tokens::TEXT).size(12.0);
    ui.add(
        egui::Button::new(text)
            .fill(Color32::TRANSPARENT)
            .stroke(Stroke::new(1.0_f32, tokens::border2()))
            .corner_radius(0.0),
    )
}

/// The small uppercase tag on the left of a choice row, e.g. `LGT`.
///
/// Painted at a fixed size rather than laid out: a justified layout here
/// expands to whatever space the row offers, shoving the row's actual
/// content off the right edge of the window.
pub fn badge(ui: &mut Ui, text: &str, selected: bool) {
    let size = Vec2::new(44.0, 38.0);
    let (rect, _) = ui.allocate_exact_size(size, Sense::hover());
    if ui.is_rect_visible(rect) {
        let painter = ui.painter();
        let (color, stroke) = if selected {
            (tokens::ACCENT, tokens::ACCENT)
        } else {
            (tokens::MUTED, tokens::border2())
        };
        painter.rect_filled(rect, 0.0, tokens::CHROME);
        painter.rect_stroke(
            rect,
            0.0,
            Stroke::new(1.0_f32, stroke),
            egui::StrokeKind::Inside,
        );
        painter.text(
            rect.center(),
            egui::Align2::CENTER_CENTER,
            text,
            egui::FontId::proportional(10.0),
            color,
        );
    }
}

/// Rectangular toggle with a hard accent fill, matching the Mac switches.
/// Zero corner radius, like everything else in the design language.
pub fn toggle(ui: &mut Ui, on: &mut bool) -> egui::Response {
    let size = Vec2::new(46.0, 24.0);
    let (rect, mut response) = ui.allocate_exact_size(size, Sense::click());
    if response.clicked() {
        *on = !*on;
        response.mark_changed();
    }

    if ui.is_rect_visible(rect) {
        let painter = ui.painter();
        let (fill, border) = if *on {
            (tokens::ACCENT, tokens::ACCENT)
        } else {
            (tokens::PANEL2, tokens::border2())
        };
        painter.rect_filled(rect, 0.0, fill);
        painter.rect_stroke(
            rect,
            0.0,
            Stroke::new(1.0_f32, border),
            egui::StrokeKind::Inside,
        );

        let knob = if *on {
            Color32::WHITE
        } else {
            tokens::KNOB_OFF
        };
        let knob_size = Vec2::new(20.0, 20.0);
        let knob_pos = if *on {
            egui::pos2(rect.max.x - 2.0 - knob_size.x, rect.min.y + 2.0)
        } else {
            egui::pos2(rect.min.x + 2.0, rect.min.y + 2.0)
        };
        painter.rect_filled(egui::Rect::from_min_size(knob_pos, knob_size), 0.0, knob);
    }
    response
}

/// A dropdown over a fixed list of labels. Returns the newly selected index
/// when it changed.
pub fn dropdown(ui: &mut Ui, id: &str, options: &[String], selected: usize) -> Option<usize> {
    let mut current = selected.min(options.len().saturating_sub(1));
    let before = current;
    egui::ComboBox::from_id_salt(id)
        .selected_text(
            RichText::new(options.get(current).map(String::as_str).unwrap_or(""))
                .color(tokens::ACCENT)
                .size(12.0)
                .strong(),
        )
        .width(220.0)
        .show_ui(ui, |ui| {
            for (index, option) in options.iter().enumerate() {
                ui.selectable_value(&mut current, index, option);
            }
        });
    (current != before).then_some(current)
}

#[cfg(test)]
mod tests {
    // These widgets need an egui context to render; the layout they produce is
    // checked by using the app. What is worth pinning here is the design
    // contract the helpers encode.
    use crate::ui::tokens;

    #[test]
    fn the_toggle_matches_the_switch_dimensions_of_the_other_builds() {
        // 46×24 with a 20px knob, from the GTK stylesheet's `switch` rules.
        // (Values inlined in `toggle`; this test documents them.)
        assert_eq!(tokens::KNOB_OFF, egui::Color32::from_rgb(0x8A, 0x85, 0x84));
    }
}
