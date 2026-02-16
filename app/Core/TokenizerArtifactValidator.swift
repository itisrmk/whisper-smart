import Foundation

struct TokenizerArtifactValidator {
    /// Built-in Hugging Face vocab.txt for Parakeet is currently ~93,939 bytes.
    /// Keep this in tests so future hard-coded expectations don't regress.
    static let knownParakeetVocabSizeBytes: Int64 = 93_939

    static func validate(at tokenizerURL: URL, source: ParakeetResolvedModelSource?) -> String? {
        guard FileManager.default.fileExists(atPath: tokenizerURL.path) else {
            return "Tokenizer artifact is missing after download. Run setup again from Settings -> Provider."
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: tokenizerURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            return "Tokenizer artifact cannot be read. Run setup again from Settings -> Provider."
        }

        guard fileSize >= 128 else {
            return "Tokenizer artifact appears incomplete (\(fileSize) bytes). Run setup again from Settings -> Provider."
        }

        let extensionValue = tokenizerURL.pathExtension.lowercased()
        switch extensionValue {
        case "txt":
            guard let text = try? String(contentsOf: tokenizerURL),
                  text.split(whereSeparator: \.isNewline).count >= 10 else {
                return "Tokenizer vocab.txt is invalid or empty. Run setup again from Settings -> Provider."
            }
        case "json":
            guard let data = try? Data(contentsOf: tokenizerURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  dictionary.isEmpty == false else {
                return "Tokenizer JSON is invalid. Run setup again from Settings -> Provider."
            }
        case "model":
            break
        default:
            return "Tokenizer file extension '.\(extensionValue)' is unsupported. Use .model, .json, or .txt."
        }

        if let expectedSize = source?.tokenizerExpectedSizeBytes,
           expectedSize > 0 {
            let tolerantMinimum = max(2_048, Int64(Double(expectedSize) * 0.85))
            if fileSize < tolerantMinimum {
                return "Tokenizer download looks incomplete (\(fileSize) bytes; expected around \(expectedSize)). Run setup again from Settings -> Provider."
            }
        }

        return nil
    }
}
