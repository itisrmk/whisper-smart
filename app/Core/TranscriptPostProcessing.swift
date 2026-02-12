import Foundation

struct TranscriptPostProcessingContext {
    let isFinal: Bool
    let timestamp: Date
}

protocol TranscriptPostProcessor {
    func process(_ text: String, context: TranscriptPostProcessingContext) -> String
}

protocol TranscriptBacktrackingHook {
    func didProcess(originalText: String, processedText: String, context: TranscriptPostProcessingContext)
}

final class TranscriptPostProcessingPipeline {
    private let processors: [TranscriptPostProcessor]
    private let backtrackingHooks: [TranscriptBacktrackingHook]
    private let isEnabled: () -> Bool

    init(
        processors: [TranscriptPostProcessor],
        backtrackingHooks: [TranscriptBacktrackingHook] = [],
        isEnabled: @escaping () -> Bool = { true }
    ) {
        self.processors = processors
        self.backtrackingHooks = backtrackingHooks
        self.isEnabled = isEnabled
    }

    func process(_ text: String, isFinal: Bool) -> String {
        guard isEnabled() else { return text }

        let context = TranscriptPostProcessingContext(isFinal: isFinal, timestamp: Date())
        let processed = processors.reduce(text) { partial, processor in
            processor.process(partial, context: context)
        }

        for hook in backtrackingHooks {
            hook.didProcess(originalText: text, processedText: processed, context: context)
        }

        return processed
    }
}

struct BaselineFillerWordTrimmer: TranscriptPostProcessor {
    private let leadingFillerPattern = #"^(?:(?:\s)*(?:(?:uh|um|erm|hmm|mm-hmm)[,\s.!?]*)+)+"#

    func process(_ text: String, context: TranscriptPostProcessingContext) -> String {
        guard context.isFinal else { return text }
        guard let regex = try? NSRegularExpression(pattern: leadingFillerPattern, options: [.caseInsensitive]) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let trimmed = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct BaselineSpacingAndPunctuationNormalizer: TranscriptPostProcessor {
    func process(_ text: String, context: TranscriptPostProcessingContext) -> String {
        guard !text.isEmpty else { return text }

        var output = text

        output = replacing(#"[ \t]{2,}"#, in: output, with: " ")
        output = replacing(#"\s+([,.;:!?])"#, in: output, with: "$1")
        output = replacing(#"([,.;:!?]){2,}"#, in: output, with: "$1")
        output = replacing(#"([,.;:!?])(\S)"#, in: output, with: "$1 $2")

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
