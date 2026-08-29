//! Global hotkey binding model.
//!
//! The macOS build persists Carbon virtual key codes plus a `CGEventFlags`
//! bitmask, and has to reach for device-dependent flags
//! (`NX_DEVICELCMDKEYMASK`) to tell a left modifier from a right one.
//! Linux makes that distinction for free: the kernel input layer emits
//! `KEY_LEFTCTRL` (29) and `KEY_RIGHTCTRL` (97) as genuinely different codes,
//! so a binding is just "this key code, optionally with these modifiers held".
//!
//! Codes are the `linux/input-event-codes.h` values, which are ABI-stable, so
//! they persist safely to `config.toml`.

use serde::{Deserialize, Serialize};

// Key codes we care about, named to match `input-event-codes.h`.
pub const KEY_ESC: u16 = 1;
pub const KEY_LEFTCTRL: u16 = 29;
pub const KEY_LEFTSHIFT: u16 = 42;
pub const KEY_RIGHTSHIFT: u16 = 54;
pub const KEY_LEFTALT: u16 = 56;
pub const KEY_SPACE: u16 = 57;
pub const KEY_RIGHTCTRL: u16 = 97;
pub const KEY_RIGHTALT: u16 = 100;
pub const KEY_LEFTMETA: u16 = 125;
pub const KEY_RIGHTMETA: u16 = 126;
pub const KEY_F13: u16 = 183;

/// Modifier requirements for a combo binding. Each flag means "either the
/// left or the right variant of this modifier must be held".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Modifiers {
    #[serde(default)]
    pub ctrl: bool,
    #[serde(default)]
    pub alt: bool,
    #[serde(default)]
    pub shift: bool,
    #[serde(default)]
    pub meta: bool,
}

impl Modifiers {
    pub const NONE: Modifiers = Modifiers {
        ctrl: false,
        alt: false,
        shift: false,
        meta: false,
    };

    pub fn is_empty(&self) -> bool {
        !(self.ctrl || self.alt || self.shift || self.meta)
    }

    /// True when every modifier this binding requires is currently held.
    /// Extra modifiers are tolerated deliberately: requiring an exact match
    /// makes bindings feel flaky when a user rests a finger on Shift.
    pub fn satisfied_by(&self, held: &Modifiers) -> bool {
        (!self.ctrl || held.ctrl)
            && (!self.alt || held.alt)
            && (!self.shift || held.shift)
            && (!self.meta || held.meta)
    }

    /// Records a modifier key's press/release into the held-modifier set.
    /// Returns false if `code` is not a modifier key.
    pub fn apply(&mut self, code: u16, pressed: bool) -> bool {
        match code {
            KEY_LEFTCTRL | KEY_RIGHTCTRL => self.ctrl = pressed,
            KEY_LEFTALT | KEY_RIGHTALT => self.alt = pressed,
            KEY_LEFTSHIFT | KEY_RIGHTSHIFT => self.shift = pressed,
            KEY_LEFTMETA | KEY_RIGHTMETA => self.meta = pressed,
            _ => return false,
        }
        true
    }

    fn display_parts(&self) -> Vec<&'static str> {
        let mut parts = Vec::new();
        if self.ctrl {
            parts.push("Ctrl");
        }
        if self.alt {
            parts.push("Alt");
        }
        if self.shift {
            parts.push("Shift");
        }
        if self.meta {
            parts.push("Super");
        }
        parts
    }
}

/// A global hotkey: one key code plus optional required modifiers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HotkeyBinding {
    /// Linux input event code of the key that is held.
    pub key_code: u16,
    /// Modifiers that must already be held when `key_code` goes down.
    #[serde(default)]
    pub modifiers: Modifiers,
}

impl Default for HotkeyBinding {
    fn default() -> Self {
        Self::RIGHT_CTRL_HOLD
    }
}

impl HotkeyBinding {
    /// Default binding. The macOS build defaults to Right ⌘ Hold; Right Ctrl
    /// is the closest Linux equivalent that is not already spoken for by the
    /// compositor (Super is Hyprland's default modifier).
    pub const RIGHT_CTRL_HOLD: HotkeyBinding = HotkeyBinding {
        key_code: KEY_RIGHTCTRL,
        modifiers: Modifiers::NONE,
    };

    pub const RIGHT_ALT_HOLD: HotkeyBinding = HotkeyBinding {
        key_code: KEY_RIGHTALT,
        modifiers: Modifiers::NONE,
    };

    pub const LEFT_CTRL_HOLD: HotkeyBinding = HotkeyBinding {
        key_code: KEY_LEFTCTRL,
        modifiers: Modifiers::NONE,
    };

    pub const RIGHT_META_HOLD: HotkeyBinding = HotkeyBinding {
        key_code: KEY_RIGHTMETA,
        modifiers: Modifiers::NONE,
    };

    pub const F13_HOLD: HotkeyBinding = HotkeyBinding {
        key_code: KEY_F13,
        modifiers: Modifiers::NONE,
    };

    pub const CTRL_SPACE: HotkeyBinding = HotkeyBinding {
        key_code: KEY_SPACE,
        modifiers: Modifiers {
            ctrl: true,
            alt: false,
            shift: false,
            meta: false,
        },
    };

    pub const ALT_SPACE: HotkeyBinding = HotkeyBinding {
        key_code: KEY_SPACE,
        modifiers: Modifiers {
            ctrl: false,
            alt: true,
            shift: false,
            meta: false,
        },
    };

    /// Presets offered in Settings → Hotkey.
    pub fn presets() -> Vec<HotkeyBinding> {
        vec![
            Self::RIGHT_CTRL_HOLD,
            Self::RIGHT_ALT_HOLD,
            Self::LEFT_CTRL_HOLD,
            Self::RIGHT_META_HOLD,
            Self::F13_HOLD,
            Self::CTRL_SPACE,
            Self::ALT_SPACE,
        ]
    }

    /// True when the binding is a bare modifier key (no separate trigger key).
    /// Modifier-only bindings are the press-and-hold sweet spot because they
    /// do not collide with application shortcuts while held alone.
    pub fn is_modifier_only(&self) -> bool {
        self.modifiers.is_empty() && is_modifier_key(self.key_code)
    }

    /// Human-readable label, e.g. "Right Ctrl Hold" or "Ctrl + Space".
    pub fn display_string(&self) -> String {
        let key = key_name(self.key_code);
        if self.modifiers.is_empty() {
            format!("{key} Hold")
        } else {
            let mut parts = self.modifiers.display_parts();
            parts.push(key);
            parts.join(" + ")
        }
    }
}

pub fn is_modifier_key(code: u16) -> bool {
    matches!(
        code,
        KEY_LEFTCTRL
            | KEY_RIGHTCTRL
            | KEY_LEFTALT
            | KEY_RIGHTALT
            | KEY_LEFTSHIFT
            | KEY_RIGHTSHIFT
            | KEY_LEFTMETA
            | KEY_RIGHTMETA
    )
}

/// Display name for a key code. Covers the keys a user is plausibly going to
/// bind; anything else falls back to the raw code so the UI never shows blank.
pub fn key_name(code: u16) -> &'static str {
    match code {
        KEY_ESC => "Esc",
        KEY_LEFTCTRL => "Left Ctrl",
        KEY_RIGHTCTRL => "Right Ctrl",
        KEY_LEFTALT => "Left Alt",
        KEY_RIGHTALT => "Right Alt",
        KEY_LEFTSHIFT => "Left Shift",
        KEY_RIGHTSHIFT => "Right Shift",
        KEY_LEFTMETA => "Left Super",
        KEY_RIGHTMETA => "Right Super",
        KEY_SPACE => "Space",
        KEY_F13 => "F13",
        59..=68 => match code {
            59 => "F1",
            60 => "F2",
            61 => "F3",
            62 => "F4",
            63 => "F5",
            64 => "F6",
            65 => "F7",
            66 => "F8",
            67 => "F9",
            _ => "F10",
        },
        87 => "F11",
        88 => "F12",
        184 => "F14",
        185 => "F15",
        _ => "Key",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_binding_is_right_ctrl_hold() {
        let b = HotkeyBinding::default();
        assert_eq!(b.key_code, KEY_RIGHTCTRL);
        assert!(b.is_modifier_only());
        assert_eq!(b.display_string(), "Right Ctrl Hold");
    }

    #[test]
    fn left_and_right_modifiers_are_distinct_bindings() {
        // The whole point of using raw evdev codes: binding Right Ctrl must
        // not fire when Left Ctrl is pressed.
        assert_ne!(
            HotkeyBinding::LEFT_CTRL_HOLD,
            HotkeyBinding::RIGHT_CTRL_HOLD
        );
        assert_ne!(KEY_LEFTCTRL, KEY_RIGHTCTRL);
    }

    #[test]
    fn combo_binding_reports_modifiers_in_label() {
        assert_eq!(HotkeyBinding::CTRL_SPACE.display_string(), "Ctrl + Space");
        assert!(!HotkeyBinding::CTRL_SPACE.is_modifier_only());
    }

    #[test]
    fn modifiers_tolerate_extra_keys_but_require_declared_ones() {
        let required = Modifiers {
            ctrl: true,
            ..Modifiers::NONE
        };
        let held_ctrl_shift = Modifiers {
            ctrl: true,
            shift: true,
            ..Modifiers::NONE
        };
        let held_shift = Modifiers {
            shift: true,
            ..Modifiers::NONE
        };
        assert!(required.satisfied_by(&held_ctrl_shift));
        assert!(!required.satisfied_by(&held_shift));
    }

    #[test]
    fn apply_tracks_either_side_of_a_modifier() {
        let mut held = Modifiers::default();
        assert!(held.apply(KEY_RIGHTALT, true));
        assert!(held.alt);
        assert!(held.apply(KEY_LEFTALT, false));
        assert!(!held.alt);
        assert!(!held.apply(KEY_SPACE, true), "space is not a modifier");
    }

    #[test]
    fn binding_round_trips_through_toml() {
        let binding = HotkeyBinding::ALT_SPACE;
        let text = toml::to_string(&binding).unwrap();
        let decoded: HotkeyBinding = toml::from_str(&text).unwrap();
        assert_eq!(binding, decoded);
    }
}
