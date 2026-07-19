import Foundation

enum DictationOverlayMode: String, CaseIterable, Identifiable {
    case off
    case topCenterWaveform
    case notchDocked

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .topCenterWaveform:
            return "Top-center bar"
        case .notchDocked:
            return "Notch-docked"
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

    /// Raw value of the retired floating-bubble mode; migrated to top-center.
    private static let retiredFloatingBubbleRawValue = "floatingBubble"

    static var overlayMode: DictationOverlayMode {
        get {
            if let raw = defaults.string(forKey: Key.overlayMode) {
                if let mode = DictationOverlayMode(rawValue: raw) {
                    return mode
                }
                // The floating bubble was removed; carry those users over to
                // the top-center bar so an overlay still appears.
                if raw == retiredFloatingBubbleRawValue {
                    defaults.set(DictationOverlayMode.topCenterWaveform.rawValue, forKey: Key.overlayMode)
                    return .topCenterWaveform
                }
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
