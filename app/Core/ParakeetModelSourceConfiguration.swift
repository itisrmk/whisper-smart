import Foundation
import os.log

private let modelSourceLogger = Logger(subsystem: "com.visperflow", category: "ParakeetModelSource")

enum ParakeetModelCatalog {
    static let ctc06BVariantID = "parakeet-ctc-0.6b"
}

struct ParakeetModelSourceOption: Identifiable, Equatable {
    static let customSourceID = "custom"

    let id: String
    let displayName: String
    let modelURLString: String
    let modelDataURLString: String?
    let tokenizerURLString: String?
    let modelExpectedSizeBytes: Int64?
    let tokenizerExpectedSizeBytes: Int64?
    let modelSHA256: String?
    let tokenizerSHA256: String?
    let isBuiltIn: Bool

    var modelURL: URL? {
        Self.parseHTTPURL(modelURLString)
    }

    var modelDataURL: URL? {
        Self.parseHTTPURL(modelDataURLString)
    }

    var tokenizerURL: URL? {
        Self.parseHTTPURL(tokenizerURLString)
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
    let modelURL: URL?
    let modelDataURL: URL?
    let tokenizerURL: URL?
    let tokenizerFilename: String?
    let modelExpectedSizeBytes: Int64?
    let tokenizerExpectedSizeBytes: Int64?
    let modelSHA256: String?
    let tokenizerSHA256: String?
    let error: String?
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

    private let defaults = UserDefaults.standard

    private init() {}

    func availableSources(for variantID: String) -> [ParakeetModelSourceOption] {
        var options = builtInSources(for: variantID)

        if let custom = customSourceOption(for: variantID),
           options.contains(where: { $0.id == custom.id }) == false {
            options.append(custom)
        }

        return options
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

        guard modelURL.pathExtension.lowercased() == "onnx" else {
            return "Custom model source must point to an .onnx file."
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
                modelURL: nil,
                modelDataURL: nil,
                tokenizerURL: nil,
                tokenizerFilename: nil,
                modelExpectedSizeBytes: nil,
                tokenizerExpectedSizeBytes: nil,
                modelSHA256: nil,
                tokenizerSHA256: nil,
                error: "No default model source is bundled for variant '\(variantID)'.",
                availableSources: []
            )
        }

        let selectedID = selectedSourceID(for: variantID)
        let selectedSource = options.first(where: { $0.id == selectedID }) ?? options[0]

        var error: String?

        if selectedSource.modelURL == nil {
            error = "Selected source '\(selectedSource.displayName)' has an invalid model URL."
        } else if selectedSource.modelURL?.pathExtension.lowercased() != "onnx" {
            error = "Selected source '\(selectedSource.displayName)' must point to an .onnx model URL."
        }

        if error == nil,
           let tokenizerRaw = selectedSource.tokenizerURLString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tokenizerRaw.isEmpty,
           selectedSource.tokenizerURL == nil {
            error = "Selected source '\(selectedSource.displayName)' has an invalid tokenizer URL."
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
            modelURL: selectedSource.modelURL,
            modelDataURL: selectedSource.modelDataURL,
            tokenizerURL: selectedSource.tokenizerURL,
            tokenizerFilename: selectedSource.tokenizerFilename,
            modelExpectedSizeBytes: selectedSource.modelExpectedSizeBytes,
            tokenizerExpectedSizeBytes: selectedSource.tokenizerExpectedSizeBytes,
            modelSHA256: selectedSource.modelSHA256,
            tokenizerSHA256: selectedSource.tokenizerSHA256,
            error: error,
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
                    displayName: "Hugging Face · nemo128.onnx (recommended)",
                    modelURLString: "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main/nemo128.onnx",
                    modelDataURLString: nil,
                    tokenizerURLString: "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main/vocab.txt",
                    modelExpectedSizeBytes: 35_000_000,
                    tokenizerExpectedSizeBytes: 100_000,
                    modelSHA256: nil,
                    tokenizerSHA256: nil,
                    isBuiltIn: true
                ),
                ParakeetModelSourceOption(
                    id: "hf_parakeet_tdt06b_v3_encoder_split",
                    displayName: "Hugging Face · encoder-model.onnx + .data (mirror)",
                    modelURLString: "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main/encoder-model.onnx",
                    modelDataURLString: "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main/encoder-model.onnx.data",
                    tokenizerURLString: "https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx/resolve/main/vocab.txt",
                    modelExpectedSizeBytes: 40_000_000,
                    tokenizerExpectedSizeBytes: 100_000,
                    modelSHA256: nil,
                    tokenizerSHA256: nil,
                    isBuiltIn: true
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
            modelExpectedSizeBytes: nil,
            tokenizerExpectedSizeBytes: nil,
            modelSHA256: nil,
            tokenizerSHA256: nil,
            isBuiltIn: false
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
