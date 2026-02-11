import AppKit
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

    // MARK: - Build from NSEvent (for shortcut recorder)

    /// Creates a HotkeyBinding from a captured NSEvent key-down.
    /// Returns nil if the event has no usable key information.
    static func from(event: NSEvent) -> HotkeyBinding? {
        let keyCode = Int(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Build display string
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }

        let keyName = Self.keyName(for: keyCode) ?? event.charactersIgnoringModifiers?.uppercased()
        if let keyName {
            parts.append(keyName)
        }

        // Must have at least one modifier + a non-modifier key
        guard !parts.isEmpty, keyName != nil, !flags.isEmpty else { return nil }

        let display = parts.joined(separator: " ")

        // Convert NSEvent modifier flags to CGEventFlags
        var cgFlags: CGEventFlags = []
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.option)  { cgFlags.insert(.maskAlternate) }
        if flags.contains(.shift)   { cgFlags.insert(.maskShift) }
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }

        return HotkeyBinding(
            keyCode: keyCode,
            modifierFlags: cgFlags,
            displayString: display,
            isModifierOnly: false
        )
    }

    /// Human-readable name for common Carbon key codes.
    private static func keyName(for keyCode: Int) -> String? {
        switch keyCode {
        case kVK_Space:       return "Space"
        case kVK_Return:      return "Return"
        case kVK_Tab:         return "Tab"
        case kVK_Delete:      return "Delete"
        case kVK_ForwardDelete: return "Fwd Delete"
        case kVK_UpArrow:     return "↑"
        case kVK_DownArrow:   return "↓"
        case kVK_LeftArrow:   return "←"
        case kVK_RightArrow:  return "→"
        case kVK_Home:        return "Home"
        case kVK_End:         return "End"
        case kVK_PageUp:      return "Page Up"
        case kVK_PageDown:    return "Page Down"
        case kVK_F1:          return "F1"
        case kVK_F2:          return "F2"
        case kVK_F3:          return "F3"
        case kVK_F4:          return "F4"
        case kVK_F5:          return "F5"
        case kVK_F6:          return "F6"
        case kVK_F7:          return "F7"
        case kVK_F8:          return "F8"
        case kVK_F9:          return "F9"
        case kVK_F10:         return "F10"
        case kVK_F11:         return "F11"
        case kVK_F12:         return "F12"
        default:              return nil
        }
    }

    /// Returns the index in `presets` that matches this binding, or nil.
    var presetIndex: Int? {
        HotkeyBinding.presets.firstIndex(of: self)
    }
}
