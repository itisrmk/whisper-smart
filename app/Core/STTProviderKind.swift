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
        case .parakeet:    return "NVIDIA Parakeet (experimental, not recommended)"
        case .whisper:     return "Whisper (local)"
        case .openaiAPI:   return "OpenAI Whisper API"
        case .stub:        return "Stub (testing only)"
        }
    }

    /// Whether this provider uses built-in model download UX.
    var requiresModelDownload: Bool {
        switch self {
        case .parakeet: return true
        case .appleSpeech, .whisper, .stub, .openaiAPI: return false
        }
    }

    /// The default model variant for this provider, if any.
    var defaultVariant: ModelVariant? {
        ModelVariant.variants(for: self).first
    }
}

// MARK: - Model Variant

/// A specific model file that can be downloaded for a local provider.
struct ModelVariant: Equatable, Identifiable {
    let id: String
    let displayName: String
    /// Expected file size in bytes (for progress UI / validation).
    let sizeBytes: Int64
    /// Minimum acceptable file size — files smaller than this are considered corrupt.
    let minimumValidBytes: Int64
    /// Relative path inside the app's Application Support directory.
    let relativePath: String

    var configuredSource: ParakeetResolvedModelSource? {
        switch id {
        case ParakeetModelCatalog.ctc06BVariantID:
            return ParakeetModelSourceConfigurationStore.shared.resolvedSource(for: id)
        default:
            return nil
        }
    }

    /// Remote source for downloading this model, if configured.
    var remoteURL: URL? {
        configuredSource?.modelURL
    }

    var tokenizerRemoteURL: URL? {
        configuredSource?.tokenizerURL
    }

    var configuredSourceDisplayName: String {
        configuredSource?.selectedSourceName ?? "Unavailable"
    }

    var configuredSourceURLDisplay: String {
        configuredSource?.modelURLDisplay ?? "Unavailable"
    }

    var configuredTokenizerURLDisplay: String {
        configuredSource?.tokenizerURLDisplay ?? "Not configured"
    }

    var hasDownloadSource: Bool {
        guard let source = configuredSource else { return false }
        return source.modelURL != nil && source.error == nil
    }

    var downloadUnavailableReason: String? {
        guard let source = configuredSource else {
            return "Model source is unavailable for variant '\(id)'."
        }
        if let error = source.error {
            return "\(error) Open Settings -> Provider to choose a valid source."
        }
        if source.modelURL == nil {
            return "Model source URL is not configured. Open Settings -> Provider and choose a source."
        }
        return nil
    }

    /// Resolved path on disk. Returns `nil` if Application Support is unavailable.
    var localURL: URL? {
        guard let resolved = AppStoragePaths.resolvedModelURL(relativePath: relativePath) else {
            logger.error("Application Support directory unavailable")
            return nil
        }
        return resolved
    }

    /// Resolved tokenizer path on disk for the active source, when available.
    var tokenizerLocalURL: URL? {
        tokenizerLocalURL(using: configuredSource)
    }

    func tokenizerLocalURL(using source: ParakeetResolvedModelSource?) -> URL? {
        guard let modelURL = localURL else { return nil }
        let modelDirectory = modelURL.deletingLastPathComponent()

        if let filename = source?.tokenizerFilename,
           !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return modelDirectory.appendingPathComponent(filename)
        }

        for fallbackName in ["tokenizer.model", "tokenizer.json", "vocab.txt"] {
            let candidate = modelDirectory.appendingPathComponent(fallbackName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    /// Whether the model file is present on disk and passes basic size validation.
    var isDownloaded: Bool {
        guard let modelURL = localURL else { return false }
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return false }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: modelURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            logger.warning("Cannot read attributes for model at \(modelURL.path)")
            return false
        }

        let source = configuredSource
        let minimumModelBytes = minimumValidModelBytes(using: source)
        if fileSize < minimumModelBytes {
            logger.warning("Model file too small (\(fileSize) bytes < \(minimumModelBytes) min), treating as incomplete")
            return false
        }

        if let sidecarStatus = modelDataValidationStatus(using: source),
           sidecarStatus.isReady == false {
            logger.warning("Model sidecar not ready for \(self.id): \(sidecarStatus.detail)")
            return false
        }

        if let tokenizerStatus = tokenizerValidationStatus(using: source),
           tokenizerStatus.isReady == false {
            logger.warning("Tokenizer not ready for \(self.id): \(tokenizerStatus.detail)")
            return false
        }

        return true
    }

    /// Human-readable validation status for UI diagnostics.
    var validationStatus: String {
        if let sourceError = downloadUnavailableReason {
            return sourceError
        }

        guard let modelURL = localURL else { return "Path unavailable" }
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return "Not downloaded" }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: modelURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            return "Cannot read file"
        }

        let source = configuredSource
        let minimumModelBytes = minimumValidModelBytes(using: source)
        if fileSize < minimumModelBytes {
            return "Incomplete (\(fileSize / 1_000_000) MB / \(minimumModelBytes / 1_000_000) MB minimum expected)"
        }

        if let sidecarStatus = modelDataValidationStatus(using: source),
           sidecarStatus.isReady == false {
            return sidecarStatus.detail
        }

        if let tokenizerStatus = tokenizerValidationStatus(using: source),
           tokenizerStatus.isReady == false {
            return tokenizerStatus.detail
        }

        return "Ready (\(fileSize / 1_000_000) MB)"
    }

    func minimumValidModelBytes(using source: ParakeetResolvedModelSource?) -> Int64 {
        // Some ONNX exports store most tensor weights in a sidecar file
        // (e.g. model.onnx.data). In that case the model graph file itself
        // can be relatively small (~tens of MB).
        if source?.modelDataURL != nil {
            return 5_000_000
        }
        return minimumValidBytes
    }

    func modelDataValidationStatus(using source: ParakeetResolvedModelSource?) -> (isReady: Bool, detail: String)? {
        guard let source, source.modelDataURL != nil else { return nil }
        guard let modelURL = localURL else {
            return (false, "Model path unavailable while checking ONNX sidecar data file.")
        }

        let sidecarURL = modelURL.appendingPathExtension("data")
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            return (false, "ONNX sidecar data file is missing (model.onnx.data). Re-download model artifacts.")
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: sidecarURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            return (false, "ONNX sidecar data file cannot be read. Re-download model artifacts.")
        }

        guard fileSize >= 200_000_000 else {
            return (false, "ONNX sidecar data file appears incomplete (\(fileSize / 1_000_000) MB). Re-download model artifacts.")
        }

        return (true, "ONNX sidecar ready (\(sidecarURL.lastPathComponent), \(fileSize / 1_000_000) MB)")
    }

    func tokenizerValidationStatus(using source: ParakeetResolvedModelSource?) -> (isReady: Bool, detail: String)? {
        guard let source, source.tokenizerURL != nil else { return nil }
        guard let tokenizerURL = tokenizerLocalURL(using: source) else {
            return (
                false,
                "Tokenizer path unavailable. Download again to fetch tokenizer artifact."
            )
        }

        guard FileManager.default.fileExists(atPath: tokenizerURL.path) else {
            return (
                false,
                "Tokenizer file is missing. Re-download model from the selected source."
            )
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: tokenizerURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            return (
                false,
                "Tokenizer file cannot be read. Re-download model artifacts."
            )
        }

        if fileSize < 128 {
            return (
                false,
                "Tokenizer file appears incomplete (\(fileSize) bytes). Re-download model artifacts."
            )
        }

        return (
            true,
            "Tokenizer ready (\(tokenizerURL.lastPathComponent), \(fileSize / 1_000) KB)"
        )
    }
}

// MARK: - Known Model Variants

extension ModelVariant {
    /// NVIDIA Parakeet CTC 0.6B (INT8 ONNX) — compact, fast, English-focused.
    static let parakeetCTC06B = ModelVariant(
        id: ParakeetModelCatalog.ctc06BVariantID,
        displayName: "Parakeet CTC 0.6B (experimental, not recommended)",
        sizeBytes: 41_000_000,
        minimumValidBytes: 30_000_000,
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
