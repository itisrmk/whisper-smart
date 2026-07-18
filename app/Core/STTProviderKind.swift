import Foundation
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "STTProviderKind")

// MARK: - Provider Kind

/// Identifies the available STT backend engines.
/// Persisted to UserDefaults so the user's choice survives restarts.
/// Raw values are kept stable across backend changes (`nvidia_parakeet` and
/// `whisper_local` are now MLX-backed) so existing selections migrate cleanly.
enum STTProviderKind: String, CaseIterable, Codable, Identifiable {
    case appleSpeech = "apple_speech"
    case parakeet    = "nvidia_parakeet"
    case whisper     = "whisper_local"
    case openaiAPI   = "openai_api"
    case stub        = "stub"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech (on-device)"
        case .parakeet:    return "Parakeet (MLX, local)"
        case .whisper:     return "Whisper (MLX, local)"
        case .openaiAPI:   return "OpenAI Whisper API"
        case .stub:        return "Stub (testing only)"
        }
    }

    /// Whether this provider needs an MLX model installed before use.
    var requiresModelDownload: Bool {
        switch self {
        case .parakeet, .whisper: return true
        case .appleSpeech, .stub, .openaiAPI: return false
        }
    }
}

// MARK: - Persistence helpers

extension STTProviderKind {
    private static let defaultsKey = "selectedSTTProvider"

    /// Load the user's persisted provider choice.
    /// Fresh installs default to Apple Speech so local model setup stays
    /// explicit/user-initiated during onboarding.
    static func loadSelection() -> STTProviderKind {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let kind = STTProviderKind(rawValue: raw) else {
            logger.info("No saved STT provider, defaulting to Apple Speech")
            return .appleSpeech
        }
        logger.info("Loaded STT provider selection: \(kind.rawValue)")
        return kind
    }

    static func hasPersistedSelection() -> Bool {
        UserDefaults.standard.string(forKey: defaultsKey) != nil
    }

    /// Persist the user's provider choice.
    func saveSelection() {
        UserDefaults.standard.set(rawValue, forKey: STTProviderKind.defaultsKey)
        logger.info("Saved STT provider selection: \(self.rawValue)")
    }
}
