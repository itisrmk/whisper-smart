import Foundation

/// User-facing workflow controls for dictation behavior.
enum DictationWorkflowSettings {
    private static let defaults = UserDefaults.standard

    enum InsertionMode: String, CaseIterable, Identifiable {
        case smart = "smart"
        case accessibilityOnly = "accessibility_only"
        case pasteboardOnly = "pasteboard_only"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .smart: return "Smart (AX then Paste)"
            case .accessibilityOnly: return "Accessibility Only"
            case .pasteboardOnly: return "Pasteboard Only"
            }
        }
    }

    private enum Key {
        static let silenceTimeoutSeconds = "workflow.silenceTimeoutSeconds"
        static let insertionMode = "workflow.insertionMode"
        static let perAppDefaultsJSON = "workflow.perAppDefaultsJSON"
        static let snippetsJSON = "workflow.snippetsJSON"
        static let correctionDictionaryJSON = "workflow.correctionDictionaryJSON"
        static let customAIInstructions = "workflow.customAIInstructions"
        static let developerModeEnabled = "workflow.developerModeEnabled"
        static let voiceCommandFormattingEnabled = "workflow.voiceCommandFormattingEnabled"
        static let selectedInputDeviceUID = "workflow.selectedInputDeviceUID"
    }

    /// One-shot mode auto-stop when no speech is detected for this many seconds.
    static var silenceTimeoutSeconds: Double {
        get {
            let stored = defaults.double(forKey: Key.silenceTimeoutSeconds)
            if stored == 0 { return 1.0 }
            return min(max(stored, 0.35), 8.0)
        }
        set {
            defaults.set(min(max(newValue, 0.4), 8.0), forKey: Key.silenceTimeoutSeconds)
        }
    }

    static var insertionMode: InsertionMode {
        get {
            guard let raw = defaults.string(forKey: Key.insertionMode),
                  let mode = InsertionMode(rawValue: raw) else {
                return .smart
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.insertionMode)
        }
    }

    /// Per-app profile settings (style/prompt/prefix/suffix) keyed by bundle identifier.
    static var perAppDefaultsJSON: String {
        get {
            let stored = defaults.string(forKey: Key.perAppDefaultsJSON)
            if let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return stored
            }
            return """
            {
              "com.apple.mail": { "style": "formal", "prefix": "", "suffix": "" },
              "com.tinyspeck.slackmacgap": { "style": "casual" },
              "com.microsoft.VSCode": { "style": "developer" }
            }
            """
        }
        set {
            defaults.set(newValue, forKey: Key.perAppDefaultsJSON)
        }
    }

    /// Voice snippets map. Saying the key phrase expands to the value.
    static var snippetsJSON: String {
        get {
            let stored = defaults.string(forKey: Key.snippetsJSON)
            if let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return stored
            }
            return """
            {
              "my calendar link": "https://calendar.google.com",
              "my signature": "Best,\nRahul"
            }
            """
        }
        set {
            defaults.set(newValue, forKey: Key.snippetsJSON)
        }
    }

    /// Word/phrase correction memory map. Keys are replaced with values.
    static var correctionDictionaryJSON: String {
        get {
            let stored = defaults.string(forKey: Key.correctionDictionaryJSON)
            if let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return stored
            }
            return """
            {
              "open ai": "OpenAI",
              "whisper smart": "Whisper Smart"
            }
            """
        }
        set {
            defaults.set(newValue, forKey: Key.correctionDictionaryJSON)
        }
    }

    /// Applied as guidance prompt to cloud transcription where supported.
    static var customAIInstructions: String {
        get {
            defaults.string(forKey: Key.customAIInstructions) ?? ""
        }
        set {
            defaults.set(newValue, forKey: Key.customAIInstructions)
        }
    }

    static var developerModeEnabled: Bool {
        get {
            defaults.bool(forKey: Key.developerModeEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.developerModeEnabled)
        }
    }

    static var voiceCommandFormattingEnabled: Bool {
        get {
            if defaults.object(forKey: Key.voiceCommandFormattingEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Key.voiceCommandFormattingEnabled)
        }
        set {
            defaults.set(newValue, forKey: Key.voiceCommandFormattingEnabled)
        }
    }

    /// Selected audio input device UID. Empty means use system default.
    static var selectedInputDeviceUID: String {
        get {
            defaults.string(forKey: Key.selectedInputDeviceUID) ?? ""
        }
        set {
            defaults.set(newValue, forKey: Key.selectedInputDeviceUID)
        }
    }
}

/// Provider policy toggles that intentionally require explicit user opt-in.
enum DictationProviderPolicy {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let cloudFallbackEnabled = "provider.cloudFallbackEnabled"
        static let openAIAPIKey = "provider.openAI.apiKey"
        static let whisperCLIPath = "provider.whisper.cliPath"
        static let whisperModelPath = "provider.whisper.modelPath"
        static let whisperModelTier = "provider.whisper.modelTier"
    }

    static var cloudFallbackEnabled: Bool {
        get { defaults.bool(forKey: Key.cloudFallbackEnabled) }
        set { defaults.set(newValue, forKey: Key.cloudFallbackEnabled) }
    }

    static var openAIAPIKey: String {
        get {
            let stored = normalizedOpenAIAPIKey(defaults.string(forKey: Key.openAIAPIKey) ?? "")
            if !stored.isEmpty {
                return stored
            }
            return normalizedOpenAIAPIKey(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "")
        }
        set {
            let normalized = normalizedOpenAIAPIKey(newValue)
            if normalized.isEmpty {
                defaults.removeObject(forKey: Key.openAIAPIKey)
            } else {
                defaults.set(normalized, forKey: Key.openAIAPIKey)
            }
        }
    }

    static func normalizedOpenAIAPIKey(_ raw: String) -> String {
        var key = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if key.hasPrefix("Bearer ") || key.hasPrefix("bearer ") {
            key = String(key.dropFirst("Bearer ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if (key.hasPrefix("\"") && key.hasSuffix("\""))
            || (key.hasPrefix("'") && key.hasSuffix("'"))
            || (key.hasPrefix("`") && key.hasSuffix("`")) {
            key = String(key.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // OpenAI keys do not contain spaces/newlines; remove paste artifacts.
        key = key.components(separatedBy: .whitespacesAndNewlines).joined()
        return key
    }

    static var whisperCLIPath: String {
        get {
            let stored = defaults.string(forKey: Key.whisperCLIPath)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty { return stored }
            return ProcessInfo.processInfo.environment["VISPERFLOW_WHISPER_CLI"] ?? ""
        }
        set { defaults.set(newValue, forKey: Key.whisperCLIPath) }
    }

    static var whisperModelPath: String {
        get {
            let stored = defaults.string(forKey: Key.whisperModelPath)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty { return stored }
            return ProcessInfo.processInfo.environment["VISPERFLOW_WHISPER_MODEL"] ?? ""
        }
        set { defaults.set(newValue, forKey: Key.whisperModelPath) }
    }

    static var whisperModelTier: String {
        get {
            let stored = defaults.string(forKey: Key.whisperModelTier)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty { return stored }
            return "base_en"
        }
        set { defaults.set(newValue, forKey: Key.whisperModelTier) }
    }
}
