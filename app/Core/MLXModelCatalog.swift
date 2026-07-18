import Foundation

/// Which MLX package runs a given model.
enum MLXEngine: String, Codable {
    case parakeet
    case whisper
}

/// One installable MLX speech-to-text model.
struct MLXModel: Equatable, Identifiable {
    /// Stable identifier used for persistence and install markers.
    let id: String
    let displayName: String
    let engine: MLXEngine
    /// Hugging Face repository the runner downloads and loads.
    let repo: String
    let approxSizeLabel: String
    let qualityBand: String
}

/// The set of MLX models the app offers, plus the user's selections.
enum MLXModelCatalog {
    static let parakeetV3 = MLXModel(
        id: "parakeet-tdt-0.6b-v3",
        displayName: "Parakeet TDT 0.6B v3",
        engine: .parakeet,
        repo: "mlx-community/parakeet-tdt-0.6b-v3",
        approxSizeLabel: "2.5 GB",
        qualityBand: "Best speed · 25 languages"
    )

    static let parakeetV2 = MLXModel(
        id: "parakeet-tdt-0.6b-v2",
        displayName: "Parakeet TDT 0.6B v2",
        engine: .parakeet,
        repo: "mlx-community/parakeet-tdt-0.6b-v2",
        approxSizeLabel: "2.5 GB",
        qualityBand: "Best speed · English"
    )

    static let whisperTiny = MLXModel(
        id: "whisper-tiny",
        displayName: "Whisper Tiny",
        engine: .whisper,
        repo: "mlx-community/whisper-tiny",
        approxSizeLabel: "74 MB",
        qualityBand: "Fastest · lower accuracy"
    )

    static let whisperBase = MLXModel(
        id: "whisper-base",
        displayName: "Whisper Base",
        engine: .whisper,
        repo: "mlx-community/whisper-base-mlx",
        approxSizeLabel: "144 MB",
        qualityBand: "Fast · light"
    )

    static let whisperSmall = MLXModel(
        id: "whisper-small",
        displayName: "Whisper Small",
        engine: .whisper,
        repo: "mlx-community/whisper-small-mlx",
        approxSizeLabel: "481 MB",
        qualityBand: "Balanced"
    )

    static let whisperLargeTurbo = MLXModel(
        id: "whisper-large-v3-turbo",
        displayName: "Whisper Large-v3 Turbo",
        engine: .whisper,
        repo: "mlx-community/whisper-large-v3-turbo",
        approxSizeLabel: "1.6 GB",
        qualityBand: "Highest accuracy"
    )

    static let whisperDistilLarge = MLXModel(
        id: "distil-whisper-large-v3",
        displayName: "Distil-Whisper Large-v3",
        engine: .whisper,
        repo: "mlx-community/distil-whisper-large-v3",
        approxSizeLabel: "1.5 GB",
        qualityBand: "High accuracy · faster than Large"
    )

    static let all: [MLXModel] = [
        parakeetV3, parakeetV2,
        whisperTiny, whisperBase, whisperSmall, whisperLargeTurbo, whisperDistilLarge,
    ]

    static let parakeetOptions: [MLXModel] = [parakeetV3, parakeetV2]
    static let whisperOptions: [MLXModel] = [whisperTiny, whisperBase, whisperSmall, whisperLargeTurbo, whisperDistilLarge]

    static func model(withID id: String) -> MLXModel? {
        all.first { $0.id == id }
    }

    // MARK: - Selection persistence

    private static let parakeetSelectionKey = "mlx.parakeet.selectedModel"
    private static let whisperSelectionKey = "mlx.whisper.selectedModel"

    static var selectedParakeetModel: MLXModel {
        get {
            guard let id = UserDefaults.standard.string(forKey: parakeetSelectionKey),
                  let model = model(withID: id), model.engine == .parakeet else {
                return parakeetV3
            }
            return model
        }
        set { UserDefaults.standard.set(newValue.id, forKey: parakeetSelectionKey) }
    }

    static var selectedWhisperModel: MLXModel {
        get {
            guard let id = UserDefaults.standard.string(forKey: whisperSelectionKey),
                  let model = model(withID: id), model.engine == .whisper else {
                return whisperLargeTurbo
            }
            return model
        }
        set { UserDefaults.standard.set(newValue.id, forKey: whisperSelectionKey) }
    }

    /// The model an STT provider kind currently resolves to, if it is MLX-backed.
    static func selectedModel(for kind: STTProviderKind) -> MLXModel? {
        switch kind {
        case .parakeet: return selectedParakeetModel
        case .whisper: return selectedWhisperModel
        case .appleSpeech, .openaiAPI, .stub: return nil
        }
    }
}

/// Locates the bundled MLX runner script.
enum MLXRunnerScript {
    static func resolveURL() throws -> URL {
        let fileManager = FileManager.default

        if let override = ProcessInfo.processInfo.environment["VISPERFLOW_MLX_SCRIPT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if fileManager.fileExists(atPath: url.path) { return url }
        }

        if let bundled = Bundle.main.url(forResource: "mlx_stt_infer", withExtension: "py", subdirectory: "scripts"),
           fileManager.fileExists(atPath: bundled.path) {
            return bundled
        }

        // Development fallback: running the bare binary from the repo.
        let repoRelative = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("scripts/mlx_stt_infer.py")
        if fileManager.fileExists(atPath: repoRelative.path) {
            return repoRelative
        }

        throw STTError.providerError(message: "MLX runner script (mlx_stt_infer.py) not found in app bundle.")
    }
}
