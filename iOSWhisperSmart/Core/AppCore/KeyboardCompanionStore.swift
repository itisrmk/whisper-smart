import Foundation

struct KeyboardSnippet: Codable, Equatable, Identifiable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

final class KeyboardCompanionStore {
    static let appGroupID = "group.com.visperflow.iOSWhisperSmart"
    static let shared = KeyboardCompanionStore()

    private enum Keys {
        static let latestTranscript = "keyboard.latestTranscript"
        static let recentSnippets = "keyboard.recentSnippets"
        static let lastUpdatedAt = "keyboard.lastUpdatedAt"
    }

    private let defaults: UserDefaults
    private let maxSnippets = 8

    init(userDefaults: UserDefaults? = UserDefaults(suiteName: KeyboardCompanionStore.appGroupID)) {
        self.defaults = userDefaults ?? .standard
    }

    var latestTranscript: String? {
        let value = defaults.string(forKey: Keys.latestTranscript)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    var lastUpdatedAt: Date? {
        defaults.object(forKey: Keys.lastUpdatedAt) as? Date
    }

    var recentSnippets: [KeyboardSnippet] {
        guard let data = defaults.data(forKey: Keys.recentSnippets),
              let decoded = try? JSONDecoder().decode([KeyboardSnippet].self, from: data) else {
            return []
        }
        return decoded
    }

    func saveFinalTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        defaults.set(trimmed, forKey: Keys.latestTranscript)
        defaults.set(Date(), forKey: Keys.lastUpdatedAt)

        var updatedSnippets = recentSnippets.filter { $0.text.caseInsensitiveCompare(trimmed) != .orderedSame }
        updatedSnippets.insert(KeyboardSnippet(text: trimmed), at: 0)
        if updatedSnippets.count > maxSnippets {
            updatedSnippets = Array(updatedSnippets.prefix(maxSnippets))
        }

        if let data = try? JSONEncoder().encode(updatedSnippets) {
            defaults.set(data, forKey: Keys.recentSnippets)
        }
    }

    func clearCache() {
        defaults.removeObject(forKey: Keys.latestTranscript)
        defaults.removeObject(forKey: Keys.recentSnippets)
        defaults.removeObject(forKey: Keys.lastUpdatedAt)
    }
}
