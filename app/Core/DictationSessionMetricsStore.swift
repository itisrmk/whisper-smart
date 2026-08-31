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
    /// Metrics load on demand and are dropped again once nothing displays
    /// them, so a session where History is never opened does not carry 1000
    /// decoded records for its whole life.
    private var isLoaded = false
    private var viewers = 0
    /// Visual-regression mode never loads, so releasing must never re-arm a
    /// later load that would pull in the developer's real data.
    private let snapshotMode: Bool
    private let fileURL: URL
    /// Persistence runs off the main thread so a save scheduled right after
    /// dictation cannot delay the pending paste timer.
    private let persistenceQueue = DispatchQueue(label: "com.visperflow.metrics.save", qos: .utility)

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = appSupport
            .appendingPathComponent(AppStoragePaths.canonicalAppSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("metrics", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("dictation-sessions.json")

        // Visual-regression snapshots must render deterministic empty state,
        // never the developer's real session metrics, so they never load at all.
        self.snapshotMode = ProcessInfo.processInfo.environment["VISPERFLOW_UI_SNAPSHOT"] == "1"
    }

    /// Loads metrics if they are not already resident. Main thread only.
    func ensureLoaded() {
        guard !snapshotMode, !isLoaded else { return }
        isLoaded = true
        load()
    }

    /// Called by the History UI while it is on screen.
    func beginObserving() {
        viewers += 1
        ensureLoaded()
    }

    func endObserving() {
        viewers = max(0, viewers - 1)
        releaseIfUnobserved()
    }

    private func releaseIfUnobserved() {
        guard !snapshotMode, viewers == 0, isLoaded else { return }
        sessions = []
        isLoaded = false
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
            // Must be resident before appending: saving a partially-loaded
            // array would rewrite the file with only the new metric.
            self.ensureLoaded()
            self.sessions.insert(metric, at: 0)
            if self.sessions.count > self.maxEntries {
                self.sessions = Array(self.sessions.prefix(self.maxEntries))
            }
            self.save()
            self.releaseIfUnobserved()
        }
    }

    /// Summarises what is currently resident. Deliberately does *not* load:
    /// this is read from a view body, and loading there would publish a change
    /// mid-render. The History tab's `beginObserving()` loads it on appear.
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
        let snapshot = sessions
        let fileURL = fileURL
        persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
