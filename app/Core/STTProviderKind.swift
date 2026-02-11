import Foundation
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "STTProviderKind")

// MARK: - Provider Kind

/// Identifies the available STT backend engines.
/// Persisted to UserDefaults so the user's choice survives restarts.
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
        case .parakeet:    return "NVIDIA Parakeet (local)"
        case .whisper:     return "Whisper (local)"
        case .openaiAPI:   return "OpenAI Whisper API"
        case .stub:        return "Stub (testing only)"
        }
    }

    /// Whether this provider requires a local model file to be downloaded.
    var requiresModelDownload: Bool {
        switch self {
        case .parakeet, .whisper: return true
        case .appleSpeech, .stub, .openaiAPI: return false
        }
    }

    /// The default model variant for this provider, if any.
    var defaultVariant: ModelVariant? {
        ModelVariant.variants(for: self).first
    }
}

// MARK: - Model Variant

/// A specific model file that can be downloaded for a local provider.
struct ModelVariant: Equatable, Codable, Identifiable {
    let id: String
    let displayName: String
    /// Expected file size in bytes (for progress UI / validation).
    let sizeBytes: Int64
    /// Minimum acceptable file size — files smaller than this are considered corrupt.
    let minimumValidBytes: Int64
    /// Relative path inside the app's Application Support directory.
    let relativePath: String

    /// Resolved path on disk. Returns `nil` if Application Support is unavailable.
    var localURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            logger.error("Application Support directory unavailable")
            return nil
        }
        return appSupport
            .appendingPathComponent("Visperflow", isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    /// Whether the model file is present on disk and passes basic size validation.
    var isDownloaded: Bool {
        guard let url = localURL else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // Validate the file is at least the minimum expected size.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int64 else {
            logger.warning("Cannot read attributes for model at \(url.path)")
            return false
        }
        if fileSize < minimumValidBytes {
            logger.warning("Model file too small (\(fileSize) bytes < \(self.minimumValidBytes) min), treating as incomplete")
            return false
        }
        return true
    }

    /// Human-readable validation status for UI diagnostics.
    var validationStatus: String {
        guard let url = localURL else { return "Path unavailable" }
        guard FileManager.default.fileExists(atPath: url.path) else { return "Not downloaded" }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int64 else {
            return "Cannot read file"
        }
        if fileSize < minimumValidBytes {
            return "Incomplete (\(fileSize / 1_000_000) MB / \(sizeBytes / 1_000_000) MB expected)"
        }
        return "Ready (\(fileSize / 1_000_000) MB)"
    }
}

// MARK: - Known Model Variants

extension ModelVariant {
    /// NVIDIA Parakeet CTC 0.6B — compact, fast, English-only.
    static let parakeetCTC06B = ModelVariant(
        id: "parakeet-ctc-0.6b",
        displayName: "Parakeet CTC 0.6B",
        sizeBytes: 640_000_000,
        minimumValidBytes: 1_000, // stub files are tiny; real ONNX will be much larger
        relativePath: "models/parakeet-ctc-0.6b.onnx"
    )

    /// All variants available for a given provider kind.
    static func variants(for kind: STTProviderKind) -> [ModelVariant] {
        switch kind {
        case .parakeet:  return [.parakeetCTC06B]
        case .whisper:   return [] // TODO: add Whisper model variants
        case .appleSpeech, .stub, .openaiAPI: return []
        }
    }
}

// MARK: - Persistence helpers

extension STTProviderKind {
    private static let defaultsKey = "selectedSTTProvider"

    /// Load the user's persisted provider choice, defaulting to `.appleSpeech`.
    static func loadSelection() -> STTProviderKind {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let kind = STTProviderKind(rawValue: raw) else {
            logger.info("No saved STT provider, defaulting to Apple Speech")
            return .appleSpeech
        }
        logger.info("Loaded STT provider selection: \(kind.rawValue)")
        return kind
    }

    /// Persist the user's provider choice.
    func saveSelection() {
        UserDefaults.standard.set(rawValue, forKey: STTProviderKind.defaultsKey)
        logger.info("Saved STT provider selection: \(self.rawValue)")
    }
}
