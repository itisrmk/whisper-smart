//! Shared building blocks for the settings window.
//!
//! These are the Linux counterparts of the SwiftUI components in
//! `app/UI/SettingsView.swift` — the card with its icon header and 2px rule,
//! the label/description row with a trailing control, and the selectable choice
//! row used by the model picker. Keeping them here means every page is built
//! from the same pieces, which is what stops the two platforms drifting apart
//! visually one screen at a time.

use gtk::prelude::*;

use crate::ui::tokens;

/// A titled card: accent icon, title, and a 2px rule. Content is appended
/// straight onto the returned box, landing under the rule.
///
/// There is deliberately no inner "body" container. An empty one contributed
/// its own margins even when nothing had been added to it, which opened a
/// phantom gap between the rule and the first row.
pub fn card(icon_name: &str, title: &str) -> gtk::Box {
    let card = gtk::Box::new(gtk::Orientation::Vertical, 0);
    card.add_css_class("vf-card");

    let header = gtk::Box::new(gtk::Orientation::Horizontal, tokens::spacing::SM);
    header.set_margin_top(tokens::spacing::LG);
    header.set_margin_start(tokens::spacing::XL);
    header.set_margin_end(tokens::spacing::XL);
    header.set_margin_bottom(tokens::spacing::SM);

    let icon = gtk::Image::from_icon_name(icon_name);
    icon.set_pixel_size(16);
    icon.add_css_class("vf-card-icon");
    header.append(&icon);

    let label = gtk::Label::new(Some(title));
    label.add_css_class("vf-card-title");
    label.set_halign(gtk::Align::Start);
    header.append(&label);
    card.append(&header);

    // The heavy rule under every section header.
    let rule = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    rule.add_css_class("vf-rule");
    rule.set_margin_start(tokens::spacing::XL);
    rule.set_margin_end(tokens::spacing::XL);
    card.append(&rule);
    card
}

/// A settings row: flush-left title and description, control on the right.
pub fn row(title: &str, description: Option<&str>, control: &impl IsA<gtk::Widget>) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, tokens::spacing::LG);
    row.add_css_class("vf-row");
    row.set_margin_top(tokens::spacing::MD);
    row.set_margin_bottom(tokens::spacing::MD);

    let text = gtk::Box::new(tokens::vertical(), 4);
    text.set_hexpand(true);
    text.set_valign(gtk::Align::Center);

    let title_label = gtk::Label::new(Some(title));
    title_label.add_css_class("vf-row-title");
    title_label.set_halign(gtk::Align::Start);
    title_label.set_xalign(0.0);
    text.append(&title_label);

    if let Some(description) = description {
        let desc = gtk::Label::new(Some(description));
        desc.add_css_class("vf-row-desc");
        desc.set_halign(gtk::Align::Start);
        desc.set_xalign(0.0);
        desc.set_wrap(true);
        desc.set_wrap_mode(gtk::pango::WrapMode::WordChar);
        // A width request of 0 lets the label shrink; without it GTK keeps the
        // full unwrapped width as the minimum and the row overflows.
        desc.set_width_chars(0);
        desc.set_max_width_chars(0);
        text.append(&desc);
    }

    row.append(&text);
    let control = control.as_ref();
    control.set_valign(gtk::Align::Center);
    control.set_halign(gtk::Align::End);
    row.append(control);
    row
}

/// A selectable option row: badge, title with an inline description, an
/// optional action button, and a radio on the right.
///
/// This is the macOS model picker's row, and it is the reason the Provider page
/// can stay one card instead of one card per engine: the tier is the choice a
/// user actually wants to make, and the machinery behind it belongs in
/// Advanced.
pub struct ChoiceRow {
    pub container: gtk::Box,
    pub radio: gtk::CheckButton,
    pub action: gtk::Button,
    pub status: gtk::Label,
}

pub fn choice_row(
    badge_text: &str,
    title: &str,
    description: &str,
    group: Option<&gtk::CheckButton>,
) -> ChoiceRow {
    let container = gtk::Box::new(gtk::Orientation::Horizontal, tokens::spacing::MD);
    container.add_css_class("vf-choice");

    let badge = badge(badge_text);
    container.append(&badge);

    let text = gtk::Box::new(gtk::Orientation::Vertical, tokens::spacing::XS);
    text.set_hexpand(true);
    text.set_valign(gtk::Align::Center);

    // Title and description share a line, as on macOS.
    let heading = gtk::Box::new(gtk::Orientation::Horizontal, tokens::spacing::XS);
    let title_label = gtk::Label::new(Some(title));
    title_label.add_css_class("vf-choice-title");
    heading.append(&title_label);

    let desc = gtk::Label::new(Some(description));
    desc.add_css_class("vf-choice-desc");
    desc.set_xalign(0.0);
    desc.set_ellipsize(gtk::pango::EllipsizeMode::End);
    desc.set_hexpand(true);
    heading.append(&desc);
    text.append(&heading);

    let status = gtk::Label::new(None);
    status.add_css_class("vf-choice-desc");
    status.set_halign(gtk::Align::Start);
    status.set_xalign(0.0);
    status.set_visible(false);
    text.append(&status);

    let action = button("Download");
    action.set_halign(gtk::Align::Start);
    action.set_visible(false);
    text.append(&action);

    container.append(&text);

    let radio = gtk::CheckButton::new();
    radio.set_valign(gtk::Align::Center);
    if let Some(group) = group {
        radio.set_group(Some(group));
    }
    container.append(&radio);

    ChoiceRow {
        container,
        radio,
        action,
        status,
    }
}

/// A collapsed disclosure holding the controls most people never touch.
pub fn advanced(title: &str, body: &impl IsA<gtk::Widget>) -> gtk::Expander {
    let expander = gtk::Expander::new(Some(title));
    expander.add_css_class("vf-advanced");
    expander.set_child(Some(body.as_ref()));
    expander.set_expanded(false);
    expander
}

/// A hairline between rows inside a card.
pub fn separator() -> gtk::Box {
    let sep = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    sep.add_css_class("vf-row-sep");
    sep
}

/// Appends `rows` to a container with separators between them.
pub fn fill(body: &gtk::Box, rows: Vec<gtk::Box>) {
    let last = rows.len().saturating_sub(1);
    for (index, row) in rows.into_iter().enumerate() {
        body.append(&row);
        if index != last {
            body.append(&separator());
        }
    }
}

/// Explanatory copy inside a card, above or below the rows.
pub fn note(text: &str) -> gtk::Label {
    let label = gtk::Label::new(Some(text));
    label.add_css_class("vf-row-desc");
    label.set_halign(gtk::Align::Start);
    label.set_xalign(0.0);
    label.set_wrap(true);
    label.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    label.set_width_chars(0);
    label.set_max_width_chars(0);
    label.set_margin_top(tokens::spacing::SM);
    label
}

/// A dropdown over a fixed list of labels.
pub fn dropdown(options: &[String], selected: usize) -> gtk::DropDown {
    let strings: Vec<&str> = options.iter().map(String::as_str).collect();
    let model = gtk::StringList::new(&strings);
    let dropdown = gtk::DropDown::new(Some(model), gtk::Expression::NONE);
    dropdown.set_selected(selected as u32);
    dropdown
}

/// A filled accent button.
pub fn button(label: &str) -> gtk::Button {
    let button = gtk::Button::with_label(label);
    button.add_css_class("vf-button");
    button
}

/// An outlined secondary button.
pub fn ghost_button(label: &str) -> gtk::Button {
    let button = gtk::Button::with_label(label);
    button.add_css_class("vf-button-ghost");
    button
}

/// The small uppercase tag on the left of a choice row, e.g. `LGT`.
pub fn badge(text: &str) -> gtk::Label {
    let label = gtk::Label::new(Some(text));
    label.add_css_class("vf-badge");
    label.set_valign(gtk::Align::Center);
    label.set_width_chars(4);
    label
}

/// A key cap, as used by the hotkey display.
pub fn keycap(text: &str) -> gtk::Label {
    let label = gtk::Label::new(Some(text));
    label.add_css_class("vf-keycap");
    label
}

#[cfg(test)]
mod tests {
    // These widgets need a GTK display to instantiate, which a headless test
    // run does not have. The layout they produce is verified by the visual
    // check in `scripts/` and by the settings window's own construction, so
    // the useful thing to assert here is the styling contract they depend on.
    use crate::ui::tokens;

    #[test]
    fn every_class_these_widgets_apply_exists_in_the_stylesheet() {
        for class in [
            "vf-card",
            "vf-card-title",
            "vf-rule",
            "vf-row",
            "vf-row-title",
            "vf-row-desc",
            "vf-row-sep",
            "vf-button",
            "vf-button-ghost",
            "vf-badge",
            "vf-keycap",
            "vf-choice",
            "vf-choice-title",
            "vf-choice-desc",
        ] {
            assert!(
                tokens::STYLESHEET.contains(class),
                "{class} is applied by a widget but never styled"
            );
        }
    }
}
