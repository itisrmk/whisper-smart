import Foundation

/// A vocabulary term mined from transcript history that the user may want to
/// promote into the correction dictionary.
struct DictionarySuggestion: Identifiable, Equatable {
    /// The term exactly as it appeared in transcripts (casing preserved).
    let term: String
    /// How many times the qualifying form was seen across history.
    let occurrences: Int

    var id: String { term }
}

/// Scans transcript history for candidate vocabulary using pure local
/// heuristics — no network, no ML. Candidates are tokens that do not look like
/// plain dictionary-cased words:
///   - mixed-case identifiers (e.g. "MacBook", "OpenAI", "iPhone") seen >= 2 times
///   - all-caps terms (e.g. "MLX", "API") seen >= 3 times
///   - consistently Capitalized words seen >= 3 times mid-sentence and never
///     observed fully lowercased (approximates proper nouns)
/// Terms already present in the correction dictionary or snippets, and terms
/// the user dismissed, are never suggested.
enum DictionarySuggestionEngine {
    static let maxSuggestions = 5

    private static let defaults = UserDefaults.standard

    private enum Key {
        static let dismissedTerms = "dictionary.dismissedSuggestionTerms"
    }

    /// Lowercased words that are common enough that capitalization alone is not
    /// a signal (sentence starters, dictation artifacts).
    private static let stopwords: Set<String> = [
        "i", "i'm", "i'll", "i've", "i'd", "it's", "ok", "okay",
        "hi", "hey", "hello", "thanks", "yeah", "yes", "no",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december"
    ]

    // MARK: - Public API

    /// Convenience entry point for the UI: mines history texts and filters out
    /// terms already covered by the correction dictionary, snippets, or the
    /// persisted dismissed set.
    static func suggestions(
        fromHistoryTexts texts: [String],
        limit: Int = maxSuggestions
    ) -> [DictionarySuggestion] {
        var excluded = dismissedTerms
        excluded.formUnion(termsInPhraseMapJSON(DictationWorkflowSettings.correctionDictionaryJSON))
        excluded.formUnion(termsInPhraseMapJSON(DictationWorkflowSettings.snippetsJSON))
        return candidates(in: texts, excluding: excluded, limit: limit)
    }

    /// Pure heuristic core — deterministic and side-effect free so it can be
    /// exercised directly from smoke tests.
    static func candidates(
        in texts: [String],
        excluding excludedLowercasedTerms: Set<String> = [],
        limit: Int = maxSuggestions
    ) -> [DictionarySuggestion] {
        guard limit > 0 else { return [] }

        var totalCounts: [String: Int] = [:]
        var midSentenceCounts: [String: Int] = [:]
        var lowercaseFormsSeen: Set<String> = []

        for text in texts {
            for token in tokens(in: text) {
                totalCounts[token.term, default: 0] += 1
                if !token.isSentenceInitial {
                    midSentenceCounts[token.term, default: 0] += 1
                }
                if token.term == token.term.lowercased() {
                    lowercaseFormsSeen.insert(token.term)
                }
            }
        }

        var results: [DictionarySuggestion] = []
        for (term, count) in totalCounts {
            let lowered = term.lowercased()
            guard !excludedLowercasedTerms.contains(lowered),
                  !stopwords.contains(lowered) else { continue }

            switch shape(of: term) {
            case .plain:
                continue
            case .mixedCase:
                guard count >= 2 else { continue }
            case .allCaps:
                guard count >= 3 else { continue }
            case .capitalized:
                // Sentence-initial capitalization is expected; only trust
                // repeated mid-sentence use of a form never seen lowercased.
                guard midSentenceCounts[term, default: 0] >= 3,
                      !lowercaseFormsSeen.contains(lowered) else { continue }
            }

            results.append(DictionarySuggestion(term: term, occurrences: count))
        }

        results.sort {
            if $0.occurrences != $1.occurrences { return $0.occurrences > $1.occurrences }
            return $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending
        }
        return Array(results.prefix(limit))
    }

    // MARK: - Dismissed persistence

    /// Lowercased terms the user dismissed; these never reappear.
    static var dismissedTerms: Set<String> {
        Set(defaults.stringArray(forKey: Key.dismissedTerms) ?? [])
    }

    static func dismiss(_ term: String) {
        var current = dismissedTerms
        current.insert(term.lowercased())
        defaults.set(current.sorted(), forKey: Key.dismissedTerms)
    }

    // MARK: - Heuristics

    private enum TokenShape {
        case plain
        case mixedCase
        case allCaps
        case capitalized
    }

    struct Token: Equatable {
        let term: String
        let isSentenceInitial: Bool
    }

    /// Splits text into letter-led tokens (letters, digits, apostrophes,
    /// hyphens), tracking whether each token opens a sentence.
    static func tokens(in text: String) -> [Token] {
        var results: [Token] = []
        var current = ""
        var sentenceInitial = true
        var pendingSentenceInitial = true

        func flush() {
            defer { current = "" }
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "'’-"))
            guard let first = trimmed.first, first.isLetter,
                  trimmed.count >= 2, trimmed.count <= 30 else { return }
            results.append(Token(term: trimmed, isSentenceInitial: sentenceInitial))
        }

        for character in text {
            if character.isLetter || character.isNumber
                || character == "'" || character == "’" || character == "-" {
                if current.isEmpty {
                    sentenceInitial = pendingSentenceInitial
                    pendingSentenceInitial = false
                }
                current.append(character)
            } else {
                flush()
                if ".!?\n:;".contains(character) {
                    pendingSentenceInitial = true
                }
            }
        }
        flush()
        return results
    }

    private static func shape(of term: String) -> TokenShape {
        let letters = term.filter(\.isLetter)
        guard !letters.isEmpty else { return .plain }

        let hasLowercase = letters.contains(where: \.isLowercase)
        let hasUppercase = letters.contains(where: \.isUppercase)
        let hasUppercaseAfterFirst = term.dropFirst().contains(where: \.isUppercase)

        if !hasLowercase && hasUppercase {
            return letters.count >= 2 && letters.count <= 10 ? .allCaps : .plain
        }
        if hasUppercaseAfterFirst && hasLowercase {
            return .mixedCase
        }
        if hasUppercase && hasLowercase, term.first?.isUppercase == true,
           term.count >= 3 {
            return .capitalized
        }
        return .plain
    }

    /// Lowercased keys and values from a `{"from": "to"}` phrase map JSON blob.
    private static func termsInPhraseMapJSON(_ json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let map = object as? [String: String] else {
            return []
        }
        var terms: Set<String> = []
        for (key, value) in map {
            terms.insert(key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            terms.insert(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return terms
    }
}

/// Hands a History-tab "Add to dictionary" request over to the Dictionary &
/// Style tab, which is usually not mounted when the request is made.
enum CorrectionDictionaryPrefill {
    private static var pendingText: String?

    static func request(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingText = trimmed
        NotificationCenter.default.post(name: .correctionDictionaryPrefillRequested, object: nil)
    }

    static func consume() -> String? {
        defer { pendingText = nil }
        return pendingText
    }
}

extension Notification.Name {
    /// History tab asked to pre-fill a correction-dictionary entry; the
    /// settings root switches to the Dictionary & Style tab, which consumes
    /// `CorrectionDictionaryPrefill`.
    static let correctionDictionaryPrefillRequested = Notification.Name("correctionDictionaryPrefillRequested")
}
