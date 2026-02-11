import Foundation
import Carbon.HIToolbox
import CoreGraphics

/// Describes a global hotkey binding: a key code, optional modifier flags, and a
/// human-readable display string.  Codable so it can round-trip through UserDefaults.
struct HotkeyBinding: Equatable, Codable {

    /// Carbon virtual key code (e.g. `kVK_RightCommand`, `kVK_Space`).
    let keyCode: Int

    /// Raw value of `CGEventFlags` for required modifiers (0 for modifier-only bindings).
    let modifierFlagsRaw: UInt64

    /// Human-readable label shown in the UI (e.g. "⌘ Hold", "⌥ Space").
    let displayString: String

    /// Whether this binding uses only a modifier key (no regular key).
    /// Modifier-only bindings fire on `.flagsChanged`; combo bindings fire
    /// on `.keyDown` / `.keyUp` with a modifier check.
    let isModifierOnly: Bool

    /// Convenience accessor for the CGEventFlags value.
    var modifierFlags: CGEventFlags {
        CGEventFlags(rawValue: modifierFlagsRaw)
    }

    // MARK: - Factory

    init(keyCode: Int, modifierFlags: CGEventFlags, displayString: String, isModifierOnly: Bool) {
        self.keyCode = keyCode
        self.modifierFlagsRaw = modifierFlags.rawValue
        self.displayString = displayString
        self.isModifierOnly = isModifierOnly
    }

    // MARK: - Presets

    static let rightCommandHold = HotkeyBinding(
        keyCode: kVK_RightCommand,
        modifierFlags: [],
        displayString: "⌘ Hold",
        isModifierOnly: true
    )

    static let optionSpace = HotkeyBinding(
        keyCode: kVK_Space,
        modifierFlags: .maskAlternate,
        displayString: "⌥ Space",
        isModifierOnly: false
    )

    static let controlSpace = HotkeyBinding(
        keyCode: kVK_Space,
        modifierFlags: .maskControl,
        displayString: "⌃ Space",
        isModifierOnly: false
    )

    static let fnKey = HotkeyBinding(
        keyCode: kVK_Function,
        modifierFlags: [],
        displayString: "Fn Hold",
        isModifierOnly: true
    )

    /// Default binding used when nothing is persisted.
    static let defaultBinding = rightCommandHold

    /// All built-in presets offered in the Settings UI.
    static let presets: [HotkeyBinding] = [
        .rightCommandHold,
        .optionSpace,
        .controlSpace,
        .fnKey,
    ]

    // MARK: - UserDefaults persistence

    private static let defaultsKey = "hotkeyBinding"

    /// Persists the binding to UserDefaults as JSON data.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// Loads the persisted binding, falling back to `.defaultBinding`.
    static func load() -> HotkeyBinding {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let binding = try? JSONDecoder().decode(HotkeyBinding.self, from: data) else {
            return .defaultBinding
        }
        return binding
    }
}
