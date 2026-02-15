import Foundation

struct TokenizerArtifactValidator {
    /// Built-in Hugging Face vocab.txt for Parakeet is currently ~93,939 bytes.
    /// Keep this in tests so future hard-coded expectations don't regress.
    static let knownParakeetVocabSizeBytes: Int64 = 93_939

    static func validate(at tokenizerURL: URL, source: ParakeetResolvedModelSource?) -> String? {
        guard FileManager.default.fileExists(atPath: tokenizerURL.path) else {
            return "Tokenizer artifact is missing after download. Retry the download."
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: tokenizerURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            return "Tokenizer artifact cannot be read. Check disk permissions and retry."
        }

        guard fileSize >= 128 else {
            return "Tokenizer artifact appears incomplete (\(fileSize) bytes). Retry the download."
        }

        let extensionValue = tokenizerURL.pathExtension.lowercased()
        switch extensionValue {
        case "txt":
            guard let text = try? String(contentsOf: tokenizerURL),
                  text.split(whereSeparator: \.isNewline).count >= 10 else {
                return "Tokenizer vocab.txt is invalid or empty. Retry the download."
            }
        case "json":
            guard let data = try? Data(contentsOf: tokenizerURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  dictionary.isEmpty == false else {
                return "Tokenizer JSON is invalid. Retry the download."
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
                if source?.isBuiltInSource == true {
                    return "Tokenizer download looks incomplete (\(fileSize) bytes; expected around \(expectedSize)). Retry once; if it still fails, switch to the built-in mirror source in Settings → Provider."
                }
                return "Tokenizer download looks incomplete (\(fileSize) bytes; expected around \(expectedSize)). Retry the download."
            }
        }

        return nil
    }
}
