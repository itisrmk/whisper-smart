import Foundation
import os.log

private let modelSourceLogger = Logger(subsystem: "com.visperflow", category: "ParakeetModelSource")

enum ParakeetModelCatalog {
    static let ctc06BVariantID = "parakeet-ctc-0.6b"
}

enum ParakeetRuntimeCompatibility: Equatable {
    case runnable
    case notRunnable(reason: String)

    var unsupportedReason: String? {
        if case .notRunnable(let reason) = self { return reason }
        return nil
    }
}

struct ParakeetModelSourceOption: Identifiable, Equatable {
    static let customSourceID = "custom"

    let id: String
    let displayName: String
    let modelURLString: String
    let modelDataURLString: String?
    let tokenizerURLString: String?
    let decoderJointURLString: String?
    let configURLString: String?
    let nemoNormalizerURLString: String?
    let modelExpectedSizeBytes: Int64?
    let modelDataExpectedSizeBytes: Int64?
    let tokenizerExpectedSizeBytes: Int64?
    let decoderJointExpectedSizeBytes: Int64?
    let configExpectedSizeBytes: Int64?
    let nemoNormalizerExpectedSizeBytes: Int64?
    let modelSHA256: String?
    let tokenizerSHA256: String?
    let isBuiltIn: Bool
    let runtimeCompatibility: ParakeetRuntimeCompatibility

    var modelURL: URL? {
        Self.parseHTTPURL(modelURLString)
    }

    var modelDataURL: URL? {
        Self.parseHTTPURL(modelDataURLString)
    }

    var tokenizerURL: URL? {
        Self.parseHTTPURL(tokenizerURLString)
    }

    var decoderJointURL: URL? {
        Self.parseHTTPURL(decoderJointURLString)
    }

    var configURL: URL? {
        Self.parseHTTPURL(configURLString)
    }

    var nemoNormalizerURL: URL? {
        Self.parseHTTPURL(nemoNormalizerURLString)
    }

    var tokenizerFilename: String? {
        guard let tokenizerURL else { return nil }
        let lastPath = tokenizerURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lastPath.isEmpty else { return nil }
        return lastPath
    }

    fileprivate static func parseHTTPURL(_ rawValue: String?) -> URL? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return nil
        }
        return url
    }
}

struct ParakeetResolvedModelSource: Equatable {
    let selectedSourceID: String
    let selectedSourceName: String
    let isBuiltInSource: Bool
    let modelURL: URL?
    let modelDataURL: URL?
    let tokenizerURL: URL?
    let decoderJointURL: URL?
    let configURL: URL?
    let nemoNormalizerURL: URL?
    let tokenizerFilename: String?
    let decoderJointFilename: String?
    let configFilename: String?
    let nemoNormalizerFilename: String?
    let modelExpectedSizeBytes: Int64?
    let modelDataExpectedSizeBytes: Int64?
    let tokenizerExpectedSizeBytes: Int64?
    let decoderJointExpectedSizeBytes: Int64?
    let configExpectedSizeBytes: Int64?
    let nemoNormalizerExpectedSizeBytes: Int64?
    let modelSHA256: String?
    let tokenizerSHA256: String?
    let error: String?
    let runtimeCompatibility: ParakeetRuntimeCompatibility
    let availableSources: [ParakeetModelSourceOption]

    var isUsable: Bool {
        modelURL != nil && error == nil
    }

    var modelURLDisplay: String {
        modelURL?.absoluteString ?? "Unavailable"
    }

    var tokenizerURLDisplay: String {
        tokenizerURL?.absoluteString ?? "Not configured"
    }
}

final class ParakeetModelSourceConfigurationStore {
    static let shared = ParakeetModelSourceConfigurationStore()
    static let supportedModelExtensions: Set<String> = ["onnx"]

    private let defaults = UserDefaults.standard

    private init() {}

    func availableSources(for variantID: String) -> [ParakeetModelSourceOption] {
        // Keep Parakeet zero-touch by exposing only the vetted built-in source.
        builtInSources(for: variantID)
    }

    func selectedSourceID(for variantID: String) -> String {
        let options = availableSources(for: variantID)
        if let stored = storedSelectedSourceID(for: variantID),
           options.contains(where: { $0.id == stored }) {
            return stored
        }
        return options.first?.id ?? ParakeetModelSourceOption.customSourceID
    }

    @discardableResult
    func selectSource(id: String, for variantID: String) -> String? {
        guard availableSources(for: variantID).contains(where: { $0.id == id }) else {
            return "Unknown model source '\(id)'."
        }

        defaults.set(id, forKey: selectedSourceDefaultsKey(for: variantID))
        modelSourceLogger.info("Selected model source \(id, privacy: .public) for variant \(variantID, privacy: .public)")
        NotificationCenter.default.post(name: .parakeetModelSourceDidChange, object: nil)
        return nil
    }

    func customSourceDraft(for variantID: String) -> (modelURL: String, tokenizerURL: String) {
        let model = defaults.string(forKey: customModelURLDefaultsKey(for: variantID)) ?? ""
        let tokenizer = defaults.string(forKey: customTokenizerURLDefaultsKey(for: variantID)) ?? ""
        return (model, tokenizer)
    }

    @discardableResult
    func saveCustomSource(
        modelURLString: String,
        tokenizerURLString: String,
        for variantID: String
    ) -> String? {
        let trimmedModel = modelURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTokenizer = tokenizerURLString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedModel.isEmpty else {
            return "Custom model source URL is required."
        }

        guard let modelURL = ParakeetModelSourceOption.parseHTTPURL(trimmedModel) else {
            return "Custom model source must be a valid http(s) URL."
        }

        guard Self.supportedModelExtensions.contains(modelURL.pathExtension.lowercased()) else {
            return "Custom model source must point to .onnx."
        }

        if !trimmedTokenizer.isEmpty {
            guard let tokenizerURL = ParakeetModelSourceOption.parseHTTPURL(trimmedTokenizer) else {
                return "Custom tokenizer source must be a valid http(s) URL."
            }
            let tokenizerExtension = tokenizerURL.pathExtension.lowercased()
            if tokenizerExtension != "model" && tokenizerExtension != "json" && tokenizerExtension != "txt" {
                return "Custom tokenizer source must end with .model, .json, or .txt."
            }
        }

        defaults.set(trimmedModel, forKey: customModelURLDefaultsKey(for: variantID))
        if trimmedTokenizer.isEmpty {
            defaults.removeObject(forKey: customTokenizerURLDefaultsKey(for: variantID))
        } else {
            defaults.set(trimmedTokenizer, forKey: customTokenizerURLDefaultsKey(for: variantID))
        }
        defaults.set(ParakeetModelSourceOption.customSourceID, forKey: selectedSourceDefaultsKey(for: variantID))

        modelSourceLogger.info("Saved custom model source for variant \(variantID, privacy: .public)")
        NotificationCenter.default.post(name: .parakeetModelSourceDidChange, object: nil)
        return nil
    }

    func resolvedSource(for variantID: String) -> ParakeetResolvedModelSource {
        let options = availableSources(for: variantID)
        guard !options.isEmpty else {
            return ParakeetResolvedModelSource(
                selectedSourceID: "none",
                selectedSourceName: "Unavailable",
                isBuiltInSource: false,
                modelURL: nil,
                modelDataURL: nil,
                tokenizerURL: nil,
                decoderJointURL: nil,
                configURL: nil,
                nemoNormalizerURL: nil,
                tokenizerFilename: nil,
                decoderJointFilename: nil,
                configFilename: nil,
                nemoNormalizerFilename: nil,
                modelExpectedSizeBytes: nil,
                modelDataExpectedSizeBytes: nil,
                tokenizerExpectedSizeBytes: nil,
                decoderJointExpectedSizeBytes: nil,
                configExpectedSizeBytes: nil,
                nemoNormalizerExpectedSizeBytes: nil,
                modelSHA256: nil,
                tokenizerSHA256: nil,
                error: "No default model source is bundled for variant '\(variantID)'.",
                runtimeCompatibility: .notRunnable(reason: "This model source is unavailable."),
                availableSources: []
            )
        }

        let selectedID = selectedSourceID(for: variantID)
        let selectedSource = options.first(where: { $0.id == selectedID }) ?? options[0]

        var error: String?

        if selectedSource.modelURL == nil {
            error = "Selected source '\(selectedSource.displayName)' has an invalid model URL."
        } else if let modelExtension = selectedSource.modelURL?.pathExtension.lowercased(),
                  Self.supportedModelExtensions.contains(modelExtension) == false {
            error = "Selected source '\(selectedSource.displayName)' must point to .onnx."
        }

        if error == nil,
           let tokenizerRaw = selectedSource.tokenizerURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tokenizerRaw.isEmpty,
           selectedSource.tokenizerURL == nil {
            error = "Selected source '\(selectedSource.displayName)' has an invalid tokenizer URL."
        }

        if error == nil,
           let decoderRaw = selectedSource.decoderJointURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !decoderRaw.isEmpty,
           selectedSource.decoderJointURL == nil {
            error = "Selected source '\(selectedSource.displayName)' has an invalid decoder URL."
        }

        if error == nil,
           let configRaw = selectedSource.configURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configRaw.isEmpty,
           selectedSource.configURL == nil {
            error = "Selected source '\(selectedSource.displayName)' has an invalid config URL."
        }

        if error == nil,
           let nemoRaw = selectedSource.nemoNormalizerURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nemoRaw.isEmpty,
           selectedSource.nemoNormalizerURL == nil {
            error = "Selected source '\(selectedSource.displayName)' has an invalid nemo normalizer URL."
        }

        if error == nil,
           let unsupportedReason = selectedSource.runtimeCompatibility.unsupportedReason {
            error = unsupportedReason
        }

        if error == nil,
           let tokenizerURL = selectedSource.tokenizerURL {
            let extensionValue = tokenizerURL.pathExtension.lowercased()
            if extensionValue != "model" && extensionValue != "json" && extensionValue != "txt" {
                error = "Tokenizer URL must end with .model, .json, or .txt."
            }
        }

        return ParakeetResolvedModelSource(
            selectedSourceID: selectedSource.id,
            selectedSourceName: selectedSource.displayName,
            isBuiltInSource: selectedSource.isBuiltIn,
            modelURL: selectedSource.modelURL,
            modelDataURL: selectedSource.modelDataURL,
            tokenizerURL: selectedSource.tokenizerURL,
            decoderJointURL: selectedSource.decoderJointURL,
            configURL: selectedSource.configURL,
            nemoNormalizerURL: selectedSource.nemoNormalizerURL,
            tokenizerFilename: selectedSource.tokenizerFilename,
            decoderJointFilename: selectedSource.decoderJointURL?.lastPathComponent,
            configFilename: selectedSource.configURL?.lastPathComponent,
            nemoNormalizerFilename: selectedSource.nemoNormalizerURL?.lastPathComponent,
            modelExpectedSizeBytes: selectedSource.modelExpectedSizeBytes,
            modelDataExpectedSizeBytes: selectedSource.modelDataExpectedSizeBytes,
            tokenizerExpectedSizeBytes: selectedSource.tokenizerExpectedSizeBytes,
            decoderJointExpectedSizeBytes: selectedSource.decoderJointExpectedSizeBytes,
            configExpectedSizeBytes: selectedSource.configExpectedSizeBytes,
            nemoNormalizerExpectedSizeBytes: selectedSource.nemoNormalizerExpectedSizeBytes,
            modelSHA256: selectedSource.modelSHA256,
            tokenizerSHA256: selectedSource.tokenizerSHA256,
            error: error,
            runtimeCompatibility: selectedSource.runtimeCompatibility,
            availableSources: options
        )
    }
}

private extension ParakeetModelSourceConfigurationStore {
    func builtInSources(for variantID: String) -> [ParakeetModelSourceOption] {
        switch variantID {
        case ParakeetModelCatalog.ctc06BVariantID:
            return [
                ParakeetModelSourceOption(
                    id: "hf_parakeet_tdt06b_v3_onnx",
                    displayName: "Hugging Face · int8 encoder+decoder bundle (recommended)",
                    modelURLString: "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main/encoder-model.int8.onnx",
                    modelDataURLString: nil,
                    tokenizerURLString: "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main/vocab.txt",
                    decoderJointURLString: "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main/decoder_joint-model.int8.onnx",
                    configURLString: "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main/config.json",
                    nemoNormalizerURLString: "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main/nemo128.onnx",
                    modelExpectedSizeBytes: 652_183_999,
                    modelDataExpectedSizeBytes: nil,
                    tokenizerExpectedSizeBytes: 100_000,
                    decoderJointExpectedSizeBytes: 18_202_004,
                    configExpectedSizeBytes: 97,
                    nemoNormalizerExpectedSizeBytes: 139_764,
                    modelSHA256: nil,
                    tokenizerSHA256: nil,
                    isBuiltIn: true,
                    runtimeCompatibility: .runnable
                )
            ]
        default:
            return []
        }
    }

    func customSourceOption(for variantID: String) -> ParakeetModelSourceOption? {
        let modelURL = defaults.string(forKey: customModelURLDefaultsKey(for: variantID))
        let tokenizerURL = defaults.string(forKey: customTokenizerURLDefaultsKey(for: variantID))
        let selectedID = storedSelectedSourceID(for: variantID)

        let hasCustomValue = (modelURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        guard hasCustomValue || selectedID == ParakeetModelSourceOption.customSourceID else {
            return nil
        }

        return ParakeetModelSourceOption(
            id: ParakeetModelSourceOption.customSourceID,
            displayName: "Custom URL",
            modelURLString: modelURL ?? "",
            modelDataURLString: nil,
            tokenizerURLString: tokenizerURL,
            decoderJointURLString: nil,
            configURLString: nil,
            nemoNormalizerURLString: nil,
            modelExpectedSizeBytes: nil,
            modelDataExpectedSizeBytes: nil,
            tokenizerExpectedSizeBytes: nil,
            decoderJointExpectedSizeBytes: nil,
            configExpectedSizeBytes: nil,
            nemoNormalizerExpectedSizeBytes: nil,
            modelSHA256: nil,
            tokenizerSHA256: nil,
            isBuiltIn: false,
            runtimeCompatibility: .runnable
        )
    }

    func storedSelectedSourceID(for variantID: String) -> String? {
        let raw = defaults.string(forKey: selectedSourceDefaultsKey(for: variantID))
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    func selectedSourceDefaultsKey(for variantID: String) -> String {
        "parakeet.modelSource.\(variantID).selected"
    }

    func customModelURLDefaultsKey(for variantID: String) -> String {
        "parakeet.modelSource.\(variantID).custom.modelURL"
    }

    func customTokenizerURLDefaultsKey(for variantID: String) -> String {
        "parakeet.modelSource.\(variantID).custom.tokenizerURL"
    }
}

extension Notification.Name {
    static let parakeetModelSourceDidChange = Notification.Name("parakeetModelSourceDidChange")
}
