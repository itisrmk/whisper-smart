import Foundation

enum DictationOverlayMode: String, CaseIterable, Identifiable {
    case off
    case floatingBubble
    case topCenterWaveform

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .floatingBubble:
            return "Floating bubble (legacy)"
        case .topCenterWaveform:
            return "Top-center waveform overlay"
        }
    }
}

enum DictationOverlaySettings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let overlayMode = "dictationOverlayMode"
        static let legacyShowBubble = "showBubble"
        static let recordingSoundsEnabled = "recordingSoundsEnabled"
    }

    static var overlayMode: DictationOverlayMode {
        get {
            if let raw = defaults.string(forKey: Key.overlayMode),
               let mode = DictationOverlayMode(rawValue: raw) {
                return mode
            }

            // Backward compatibility: map old `showBubble` to the new mode.
            // Product default now prefers the top-center waveform overlay.
            let shouldShowLegacyBubble = defaults.object(forKey: Key.legacyShowBubble) as? Bool ?? true
            let migratedMode: DictationOverlayMode = shouldShowLegacyBubble ? .topCenterWaveform : .off
            defaults.set(migratedMode.rawValue, forKey: Key.overlayMode)
            return migratedMode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.overlayMode)
            // Keep legacy key coherent for older code paths during rollout.
            defaults.set(newValue != .off, forKey: Key.legacyShowBubble)
        }
    }

    static var recordingSoundsEnabled: Bool {
        get {
            if defaults.object(forKey: Key.recordingSoundsEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Key.recordingSoundsEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.recordingSoundsEnabled)
        }
    }
}
