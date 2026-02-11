import Foundation

// MARK: - Provider Kind

/// Identifies the available STT backend engines.
/// Persisted to UserDefaults so the user's choice survives restarts.
enum STTProviderKind: String, CaseIterable, Codable, Identifiable {
    case stub       = "stub"
    case whisper    = "whisper_local"
    case parakeet   = "nvidia_parakeet"
    case openaiAPI  = "openai_api"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stub:      return "Stub (no-op)"
        case .whisper:   return "Whisper (local)"
        case .parakeet:  return "NVIDIA Parakeet (local)"
        case .openaiAPI: return "OpenAI Whisper API"
        }
    }

    /// Whether this provider requires a local model file to be downloaded.
    var requiresModelDownload: Bool {
        switch self {
        case .parakeet, .whisper: return true
        case .stub, .openaiAPI:   return false
        }
    }
}

// MARK: - Model Variant

/// A specific model file that can be downloaded for a local provider.
struct ModelVariant: Equatable, Codable, Identifiable {
    let id: String
    let displayName: String
    /// Expected file size in bytes (for progress UI).
    let sizeBytes: Int64
    /// Relative path inside the app's Application Support directory.
    let relativePath: String

    /// Resolved path on disk.
    var localURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Visperflow", isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    /// Whether the model file is already present on disk.
    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }
}

// MARK: - Known Model Variants

extension ModelVariant {
    /// NVIDIA Parakeet CTC 0.6B — compact, fast, English-only.
    static let parakeetCTC06B = ModelVariant(
        id: "parakeet-ctc-0.6b",
        displayName: "Parakeet CTC 0.6B",
        sizeBytes: 640_000_000,
        relativePath: "models/parakeet-ctc-0.6b.onnx"
    )

    /// All variants available for a given provider kind.
    static func variants(for kind: STTProviderKind) -> [ModelVariant] {
        switch kind {
        case .parakeet:  return [.parakeetCTC06B]
        case .whisper:   return [] // TODO: add Whisper model variants
        case .stub, .openaiAPI: return []
        }
    }
}

// MARK: - Persistence helpers

extension STTProviderKind {
    private static let defaultsKey = "selectedSTTProvider"

    /// Load the user's persisted provider choice, defaulting to `.stub`.
    static func loadSelection() -> STTProviderKind {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let kind = STTProviderKind(rawValue: raw) else {
            return .stub
        }
        return kind
    }

    /// Persist the user's provider choice.
    func saveSelection() {
        UserDefaults.standard.set(rawValue, forKey: STTProviderKind.defaultsKey)
    }
}
