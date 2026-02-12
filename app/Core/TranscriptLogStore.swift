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
    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupport
            .appendingPathComponent(AppStoragePaths.canonicalAppSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("transcripts.json")
        load()
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
            self.entries.insert(entry, at: 0)
            if self.entries.count > self.maxEntries {
                self.entries = Array(self.entries.prefix(self.maxEntries))
            }
            self.save()
        }
    }

    func clearAll() {
        DispatchQueue.main.async {
            self.entries = []
            self.save()
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
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension Notification.Name {
    static let transcriptLogReinsertRequested = Notification.Name("transcriptLogReinsertRequested")
}
