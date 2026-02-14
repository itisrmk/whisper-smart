import Foundation

/// Runtime-tunable feature flags for incremental dictation features.
enum DictationFeatureFlags {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let postProcessingPipelineEnabled = "postProcessingPipelineEnabled"
        static let commandModeScaffoldEnabled = "commandModeScaffoldEnabled"
        static let ttsPlaceholderEnabled = "ttsPlaceholderEnabled"
    }

    static var postProcessingPipelineEnabled: Bool {
        get {
            if defaults.object(forKey: Key.postProcessingPipelineEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Key.postProcessingPipelineEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.postProcessingPipelineEnabled)
        }
    }

    static var commandModeScaffoldEnabled: Bool {
        get {
            defaults.bool(forKey: Key.commandModeScaffoldEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.commandModeScaffoldEnabled)
        }
    }

    /// Placeholder gate for upcoming text-to-speech settings UI.
    /// Disabled by default so STT flow remains unchanged.
    static var ttsPlaceholderEnabled: Bool {
        get {
            defaults.bool(forKey: Key.ttsPlaceholderEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.ttsPlaceholderEnabled)
        }
    }
}
