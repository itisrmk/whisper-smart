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
        case .parakeet:    return "NVIDIA Parakeet TDT 0.6B v3 (experimental)"
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

    private struct ValidationSnapshot {
        let isDownloaded: Bool
        let validationStatus: String
    }

    private struct CachedValidationSnapshot {
        let timestamp: Date
        let snapshot: ValidationSnapshot
    }

    private static let validationCacheLock = NSLock()
    private static var validationCache: [String: CachedValidationSnapshot] = [:]
    private static let validationCacheTTL: TimeInterval = 0.75

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
        downloadUnavailableReason(using: configuredSource)
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
        currentValidationSnapshot().isDownloaded
    }

    /// Human-readable validation status for UI diagnostics.
    var validationStatus: String {
        currentValidationSnapshot().validationStatus
    }

    private func currentValidationSnapshot() -> ValidationSnapshot {
        let source = configuredSource
        let cacheKey = validationCacheKey(using: source)
        if let snapshot = Self.cachedValidationSnapshot(for: cacheKey) {
            return snapshot
        }

        let snapshot = buildValidationSnapshot(using: source)
        Self.storeValidationSnapshot(snapshot, for: cacheKey)
        return snapshot
    }

    private func validationCacheKey(using source: ParakeetResolvedModelSource?) -> String {
        let sourceID = source?.selectedSourceID ?? "none"
        let modelURLPath = localURL?.path ?? "unresolved"
        let tokenizerName = source?.tokenizerFilename ?? "none"
        return "\(id)|\(sourceID)|\(modelURLPath)|\(tokenizerName)"
    }

    private func buildValidationSnapshot(using source: ParakeetResolvedModelSource?) -> ValidationSnapshot {
        if let sourceError = downloadUnavailableReason(using: source) {
            return ValidationSnapshot(isDownloaded: false, validationStatus: sourceError)
        }

        guard let modelURL = localURL else {
            return ValidationSnapshot(isDownloaded: false, validationStatus: "Path unavailable")
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            return ValidationSnapshot(isDownloaded: false, validationStatus: "Not downloaded")
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: modelURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            logger.warning("Cannot read attributes for model at \(modelURL.path)")
            return ValidationSnapshot(isDownloaded: false, validationStatus: "Cannot read file")
        }

        let minimumModelBytes = minimumValidModelBytes(using: source)
        if fileSize < minimumModelBytes {
            logger.warning("Model file too small (\(fileSize) bytes < \(minimumModelBytes) min), treating as incomplete")
            let status = "Incomplete (\(fileSize / 1_000_000) MB / \(minimumModelBytes / 1_000_000) MB minimum expected)"
            return ValidationSnapshot(isDownloaded: false, validationStatus: status)
        }

        if let sidecarStatus = modelDataValidationStatus(using: source),
           sidecarStatus.isReady == false {
            logger.warning("Model sidecar not ready for \(self.id): \(sidecarStatus.detail)")
            return ValidationSnapshot(isDownloaded: false, validationStatus: sidecarStatus.detail)
        }

        if let tokenizerStatus = tokenizerValidationStatus(using: source),
           tokenizerStatus.isReady == false {
            logger.warning("Tokenizer not ready for \(self.id): \(tokenizerStatus.detail)")
            return ValidationSnapshot(isDownloaded: false, validationStatus: tokenizerStatus.detail)
        }

        return ValidationSnapshot(
            isDownloaded: true,
            validationStatus: "Ready (\(fileSize / 1_000_000) MB)"
        )
    }

    private func downloadUnavailableReason(using source: ParakeetResolvedModelSource?) -> String? {
        guard let source else {
            return "Model source is unavailable for variant '\(id)'."
        }
        if let error = source.error {
            return "\(error) The app will retry with the recommended source automatically."
        }
        if source.modelURL == nil {
            return "Model source URL is not configured. Automatic setup will retry with the recommended source."
        }
        return nil
    }

    private static func cachedValidationSnapshot(for key: String) -> ValidationSnapshot? {
        validationCacheLock.lock()
        defer { validationCacheLock.unlock() }

        guard let cached = validationCache[key] else { return nil }
        if Date().timeIntervalSince(cached.timestamp) <= validationCacheTTL {
            return cached.snapshot
        }

        validationCache.removeValue(forKey: key)
        return nil
    }

    private static func storeValidationSnapshot(_ snapshot: ValidationSnapshot, for key: String) {
        validationCacheLock.lock()
        validationCache[key] = CachedValidationSnapshot(timestamp: Date(), snapshot: snapshot)
        validationCacheLock.unlock()
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
            return (false, "ONNX sidecar data file is missing (model.onnx.data). Automatic setup will retry.")
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: sidecarURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            return (false, "ONNX sidecar data file cannot be read yet. Automatic setup will retry.")
        }

        guard fileSize >= 200_000_000 else {
            return (false, "ONNX sidecar data file appears incomplete (\(fileSize / 1_000_000) MB). Automatic setup will retry.")
        }

        return (true, "ONNX sidecar ready (\(sidecarURL.lastPathComponent), \(fileSize / 1_000_000) MB)")
    }

    func tokenizerValidationStatus(using source: ParakeetResolvedModelSource?) -> (isReady: Bool, detail: String)? {
        guard let source, source.tokenizerURL != nil else { return nil }
        guard let tokenizerURL = tokenizerLocalURL(using: source) else {
            return (
                false,
                "Tokenizer path unavailable. Automatic setup will retry."
            )
        }

        guard FileManager.default.fileExists(atPath: tokenizerURL.path) else {
            return (
                false,
                "Tokenizer file is missing. Automatic setup will retry."
            )
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: tokenizerURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            return (
                false,
                "Tokenizer file cannot be read yet. Automatic setup will retry."
            )
        }

        if fileSize < 128 {
            return (
                false,
                "Tokenizer file appears incomplete (\(fileSize) bytes). Automatic setup will retry."
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
    /// NVIDIA Parakeet TDT 0.6B v3 (ONNX export) — multilingual, local, experimental.
    static let parakeetCTC06B = ModelVariant(
        id: ParakeetModelCatalog.ctc06BVariantID,
        displayName: "Parakeet TDT 0.6B v3 (experimental)",
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

    /// Load the user's persisted provider choice, defaulting to `.parakeet`.
    /// Runtime resolver will gracefully fallback while auto-setup completes.
    static func loadSelection() -> STTProviderKind {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let kind = STTProviderKind(rawValue: raw) else {
            logger.info("No saved STT provider, defaulting to Parakeet")
            return .parakeet
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
