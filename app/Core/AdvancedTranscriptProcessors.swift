import Foundation
import AppKit

private enum AdvancedJSONParser {
    static func stringMap(from json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let map = object as? [String: String] else {
            return [:]
        }

        var cleaned: [String: String] = [:]
        for (key, value) in map {
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty, !v.isEmpty {
                cleaned[k] = v
            }
        }
        return cleaned
    }

    static func objectMap(from json: String) -> [String: [String: String]] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let map = object as? [String: [String: Any]] else {
            return [:]
        }

        var out: [String: [String: String]] = [:]
        for (bundleID, values) in map {
            var normalized: [String: String] = [:]
            for (key, value) in values {
                if let stringValue = value as? String {
                    normalized[key] = stringValue
                }
            }
            if !normalized.isEmpty {
                out[bundleID] = normalized
            }
        }
        return out
    }
}

struct VoiceCommandFormattingProcessor: TranscriptPostProcessor {
    func process(_ text: String, context: TranscriptPostProcessingContext) -> String {
        guard DictationWorkflowSettings.voiceCommandFormattingEnabled else { return text }
        guard context.isFinal else { return text }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()

        if normalized == "delete that" || normalized == "scratch that" {
            return ""
        }

        if let commandOutput = applyInlineReplaceCommand(trimmed) {
            return commandOutput
        }

        var output = text

        let replacements: [(String, String)] = [
            (#"\bnew paragraph\b"#, "\n\n"),
            (#"\bnew line\b"#, "\n"),
            (#"\bcomma\b"#, ","),
            (#"\bperiod\b"#, "."),
            (#"\bquestion mark\b"#, "?"),
            (#"\bexclamation mark\b"#, "!"),
            (#"\bcolon\b"#, ":"),
            (#"\bsemicolon\b"#, ";"),
            (#"\bopen parenthesis\b"#, "("),
            (#"\bclose parenthesis\b"#, ")")
        ]

        for (pattern, replacement) in replacements {
            output = regexReplace(output, pattern: pattern, replacement: replacement, caseInsensitive: true)
        }

        return output
    }

    private func regexReplace(_ text: String, pattern: String, replacement: String, caseInsensitive: Bool = false) -> String {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    /// Supports command phrasing:
    /// "replace OLD with NEW in TEXT"
    private func applyInlineReplaceCommand(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^replace\s+(.+?)\s+with\s+(.+?)\s+in\s+(.+)$"#,
            options: [.caseInsensitive]
        ) else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges == 4,
              let oldRange = Range(match.range(at: 1), in: text),
              let newRange = Range(match.range(at: 2), in: text),
              let contentRange = Range(match.range(at: 3), in: text) else {
            return nil
        }

        let oldValue = String(text[oldRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = String(text[newRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var content = String(text[contentRange])

        guard !oldValue.isEmpty else { return nil }

        let escaped = NSRegularExpression.escapedPattern(for: oldValue)
        guard let replaceRegex = try? NSRegularExpression(pattern: escaped, options: [.caseInsensitive]) else {
            return nil
        }
        let contentRangeNS = NSRange(content.startIndex..<content.endIndex, in: content)
        content = replaceRegex.stringByReplacingMatches(in: content, options: [], range: contentRangeNS, withTemplate: newValue)
        return content
    }
}

struct CorrectionDictionaryProcessor: TranscriptPostProcessor {
    func process(_ text: String, context: TranscriptPostProcessingContext) -> String {
        guard context.isFinal else { return text }
        let map = AdvancedJSONParser.stringMap(from: DictationWorkflowSettings.correctionDictionaryJSON)
        guard !map.isEmpty else { return text }

        var output = text
        for (from, to) in map.sorted(by: { $0.key.count > $1.key.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: from)
            output = replaceCaseInsensitiveWholePhrase(output, escapedPhrasePattern: escaped, replacement: to)
        }
        return output
    }

    private func replaceCaseInsensitiveWholePhrase(_ text: String, escapedPhrasePattern: String, replacement: String) -> String {
        let mergedPattern = "\\b" + escapedPhrasePattern + "\\b"
        guard let regex = try? NSRegularExpression(pattern: mergedPattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}

struct SnippetExpansionProcessor: TranscriptPostProcessor {
    func process(_ text: String, context: TranscriptPostProcessingContext) -> String {
        guard context.isFinal else { return text }
        let map = AdvancedJSONParser.stringMap(from: DictationWorkflowSettings.snippetsJSON)
        guard !map.isEmpty else { return text }

        var output = text
        for (cue, expansion) in map.sorted(by: { $0.key.count > $1.key.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: cue)
            output = replaceCaseInsensitiveWholePhrase(output, escapedPhrasePattern: escaped, replacement: expansion)
        }
        return output
    }

    private func replaceCaseInsensitiveWholePhrase(_ text: String, escapedPhrasePattern: String, replacement: String) -> String {
        let pattern = "\\b" + escapedPhrasePattern + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}

struct SmartSentenceCasingProcessor: TranscriptPostProcessor {
    func process(_ text: String, context: TranscriptPostProcessingContext) -> String {
        guard !text.isEmpty else { return text }

        var output = text
        output = output.replacingOccurrences(of: #"\bi\b"#, with: "I", options: .regularExpression)

        if let first = output.first, first.isLetter, first.isLowercase {
            output.replaceSubrange(output.startIndex...output.startIndex, with: String(first).uppercased())
        }

        output = regexReplace(output, pattern: #"([.!?]\s+)([a-z])"#, replacement: "$1$2", transformSecondToUpper: true)

        if context.isFinal,
           output.last.map({ ".!?".contains($0) }) != true,
           output.count > 24 {
            output.append(".")
        }

        return output
    }

    private func regexReplace(_ text: String, pattern: String, replacement: String, transformSecondToUpper: Bool) -> String {
        guard transformSecondToUpper,
              let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let fullRange = Range(match.range(at: 0), in: result),
                  let firstGroup = Range(match.range(at: 1), in: result),
                  let secondGroup = Range(match.range(at: 2), in: result) else {
                continue
            }
            let prefix = String(result[firstGroup])
            let second = String(result[secondGroup]).uppercased()
            result.replaceSubrange(fullRange, with: prefix + second)
        }

        return result
    }
}

struct AppStyleProfileProcessor: TranscriptPostProcessor {
    func process(_ text: String, context: TranscriptPostProcessingContext) -> String {
        guard context.isFinal else { return text }

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let profiles = AdvancedJSONParser.objectMap(from: DictationWorkflowSettings.perAppDefaultsJSON)
        let profile = profiles[bundleID]

        var output = text
        let style = normalizedStyle(
            profileStyle: profile?["style"]?.lowercased(),
            fallback: DictationWorkflowSettings.effectiveDefaultWritingStyle.rawValue
        )

        output = applyStyle(style, to: output, context: context)

        if let prefix = profile?["prefix"], !prefix.isEmpty, !output.hasPrefix(prefix) {
            output = prefix + output
        }

        if let suffix = profile?["suffix"], !suffix.isEmpty, !output.hasSuffix(suffix) {
            output = output + suffix
        }

        return output
    }

    private func normalizedStyle(profileStyle: String?, fallback: String) -> String {
        let selected = profileStyle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selected.isEmpty {
            return selected
        }
        return fallback
    }

    private func applyStyle(_ style: String, to text: String, context: TranscriptPostProcessingContext) -> String {
        switch style {
        case "formal":
            return formalize(text)
        case "concise":
            return makeConcise(text)
        case "developer":
            return DeveloperDictationProcessor(forceEnabled: true).process(text, context: context)
        case "casual", "neutral":
            return text
        default:
            return text
        }
    }

    private func formalize(_ text: String) -> String {
        var output = text
        let replacements: [(String, String)] = [
            (#"\bcan't\b"#, "cannot"),
            (#"\bwon't\b"#, "will not"),
            (#"\bi'm\b"#, "I am"),
            (#"\bdon't\b"#, "do not")
        ]
        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: replacement)
        }
        return output
    }

    private func makeConcise(_ text: String) -> String {
        var output = text
        let removals = ["please note that", "just to let you know", "kind of", "sort of"]
        for phrase in removals {
            output = output.replacingOccurrences(of: phrase, with: "", options: .caseInsensitive)
        }
        return output.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct DeveloperDictationProcessor: TranscriptPostProcessor {
    private let forceEnabled: Bool

    init(forceEnabled: Bool = false) {
        self.forceEnabled = forceEnabled
    }

    func process(_ text: String, context: TranscriptPostProcessingContext) -> String {
        guard forceEnabled || DictationWorkflowSettings.developerModeEnabled else { return text }
        guard context.isFinal else { return text }

        var output = text
        let replacements: [(String, String)] = [
            (#"\bopen paren\b|\bopen parenthesis\b"#, "("),
            (#"\bclose paren\b|\bclose parenthesis\b"#, ")"),
            (#"\bopen bracket\b"#, "["),
            (#"\bclose bracket\b"#, "]"),
            (#"\bopen brace\b"#, "{"),
            (#"\bclose brace\b"#, "}"),
            (#"\barrow\b"#, " -> "),
            (#"\bunderscore\b"#, "_"),
            (#"\bdouble quote\b"#, "\""),
            (#"\bsingle quote\b"#, "'"),
            (#"\bbacktick\b"#, "`")
        ]

        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: replacement)
        }

        return output
    }
}
