import Foundation

struct DictationSessionMetric: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let provider: String
    let appName: String
    let recordingDurationMs: Int?
    let transcribingDurationMs: Int?
    let endToEndDurationMs: Int?
    let status: String
}

struct DictationSessionMetricsSummary: Equatable {
    let totalSessions: Int
    let successfulSessions: Int
    let failedSessions: Int
    let averageEndToEndMs: Int?
    let p95EndToEndMs: Int?

    var successRatePercent: Int {
        guard totalSessions > 0 else { return 0 }
        return Int((Double(successfulSessions) / Double(totalSessions)) * 100)
    }

    var averageMeetsSLO: Bool? {
        guard let averageEndToEndMs else { return nil }
        return averageEndToEndMs <= DictationSessionMetricsStore.sloAverageEndToEndMs
    }

    var p95MeetsSLO: Bool? {
        guard let p95EndToEndMs else { return nil }
        return p95EndToEndMs <= DictationSessionMetricsStore.sloP95EndToEndMs
    }
}

final class DictationSessionMetricsStore: ObservableObject {
    static let shared = DictationSessionMetricsStore()
    static let sloAverageEndToEndMs = 1_200
    static let sloP95EndToEndMs = 2_400

    @Published private(set) var sessions: [DictationSessionMetric] = []

    private let maxEntries = 1000
    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupport
            .appendingPathComponent(AppStoragePaths.canonicalAppSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("metrics", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("dictation-sessions.json")
        load()
    }

    func append(
        provider: String,
        appName: String,
        recordingDurationMs: Int?,
        transcribingDurationMs: Int?,
        endToEndDurationMs: Int?,
        status: String
    ) {
        let metric = DictationSessionMetric(
            id: UUID(),
            timestamp: Date(),
            provider: provider,
            appName: appName,
            recordingDurationMs: recordingDurationMs,
            transcribingDurationMs: transcribingDurationMs,
            endToEndDurationMs: endToEndDurationMs,
            status: status
        )

        DispatchQueue.main.async {
            self.sessions.insert(metric, at: 0)
            if self.sessions.count > self.maxEntries {
                self.sessions = Array(self.sessions.prefix(self.maxEntries))
            }
            self.save()
        }
    }

    func summary(last count: Int = 100) -> DictationSessionMetricsSummary {
        let window = Array(sessions.prefix(max(1, count)))
        let success = window.filter { $0.status == "inserted" }.count
        let failed = window.filter { $0.status != "inserted" }.count
        let durations = window.compactMap(\.endToEndDurationMs).sorted()
        let avg = durations.isEmpty ? nil : (durations.reduce(0, +) / durations.count)
        let p95: Int?
        if durations.isEmpty {
            p95 = nil
        } else {
            let index = min(durations.count - 1, Int((Double(durations.count) * 0.95).rounded(.up)) - 1)
            p95 = durations[index]
        }

        return DictationSessionMetricsSummary(
            totalSessions: window.count,
            successfulSessions: success,
            failedSessions: failed,
            averageEndToEndMs: avg,
            p95EndToEndMs: p95
        )
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode([DictationSessionMetric].self, from: data) else { return }
        self.sessions = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
