import Foundation
import AppKit

struct TranscriptLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let provider: String
    let appName: String
    let durationMs: Int?
    let text: String
    let status: String
}

final class TranscriptLogStore: ObservableObject {
    static let shared = TranscriptLogStore()

    @Published private(set) var entries: [TranscriptLogEntry] = []

    private let maxEntries = 2000
    /// History is loaded on demand rather than at launch, and dropped again
    /// once nothing is displaying it: 2000 decoded entries are dead weight
    /// for the many sessions where the user never opens the History tab.
    private var isLoaded = false
    private var viewers = 0
    /// Visual-regression mode never loads, so releasing must never re-arm a
    /// later load that would pull in the developer's real data.
    private let snapshotMode: Bool
    private let fileURL: URL
    /// Persistence runs off the main thread so a save scheduled right after
    /// dictation cannot delay the pending paste timer.
    private let persistenceQueue = DispatchQueue(label: "com.visperflow.transcriptlog.save", qos: .utility)

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupport
            .appendingPathComponent(AppStoragePaths.canonicalAppSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("transcripts.json")

        // Visual-regression snapshots must render deterministic empty state,
        // never the developer's real transcript history, so they never load at all.
        self.snapshotMode = ProcessInfo.processInfo.environment["VISPERFLOW_UI_SNAPSHOT"] == "1"
    }

    /// Loads history if it is not already resident. Main thread only.
    func ensureLoaded() {
        guard !snapshotMode, !isLoaded else { return }
        isLoaded = true
        load()
    }

    /// Called by the History UI while it is on screen. Between `begin` and
    /// `end` the entries stay resident; outside that window they do not.
    func beginObserving() {
        viewers += 1
        ensureLoaded()
    }

    func endObserving() {
        viewers = max(0, viewers - 1)
        releaseIfUnobserved()
    }

    /// Transcript texts for callers that need the history once (vocabulary
    /// suggestions) without pinning it in memory afterwards.
    func historyTexts() -> [String] {
        ensureLoaded()
        defer { releaseIfUnobserved() }
        return entries.map(\.text)
    }

    private func releaseIfUnobserved() {
        guard !snapshotMode, viewers == 0, isLoaded else { return }
        entries = []
        isLoaded = false
    }

    func append(provider: String, appName: String, durationMs: Int?, text: String, status: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let entry = TranscriptLogEntry(
            id: UUID(),
            timestamp: Date(),
            provider: provider,
            appName: appName,
            durationMs: durationMs,
            text: trimmed,
            status: status
        )

        DispatchQueue.main.async {
            // Must be resident before appending: saving a partially-loaded
            // array would rewrite the file with only the new entry.
            self.ensureLoaded()
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.maxEntries {
                self.entries = Array(self.entries.prefix(self.maxEntries))
            }
            self.save()
            // `save()` already holds its own snapshot, so dropping the
            // entries here costs nothing and keeps idle dictation from
            // leaving the whole history resident.
            self.releaseIfUnobserved()
        }
    }

    func clearAll() {
        DispatchQueue.main.async {
            self.isLoaded = true
            self.entries = []
            self.save()
            self.releaseIfUnobserved()
        }
    }

    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func requestReinsert(_ text: String) {
        NotificationCenter.default.post(
            name: .transcriptLogReinsertRequested,
            object: nil,
            userInfo: ["text": text]
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([TranscriptLogEntry].self, from: data) else { return }
        self.entries = decoded
    }

    private func save() {
        let snapshot = entries
        let fileURL = fileURL
        persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

extension Notification.Name {
    static let transcriptLogReinsertRequested = Notification.Name("transcriptLogReinsertRequested")
}
