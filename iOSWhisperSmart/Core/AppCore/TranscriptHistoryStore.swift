import Foundation

struct TranscriptEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let transcript: String
    let engine: EnginePolicy
    let usedCloud: Bool
}

struct ReliabilityMetricsSnapshot: Codable, Equatable {
    var startAttempts: Int = 0
    var successfulFinalizations: Int = 0
    var failures: Int = 0
    var localFallbacks: Int = 0
    var totalLatencyMs: Double = 0

    var localSessions: Int = 0
    var cloudSessions: Int = 0

    var fallbackCloudDisabled: Int = 0
    var fallbackConsentMissing: Int = 0
    var fallbackAPIKeyMissing: Int = 0
    var fallbackNetworkUnavailable: Int = 0

    var consentBlockEvents: Int = 0

    var retentionDeletedEntries: Int = 0
    var retentionCleanupRuns: Int = 0

    var averageLatencyMs: Int {
        guard successfulFinalizations > 0 else { return 0 }
        return Int(totalLatencyMs / Double(successfulFinalizations))
    }

    var cloudUsageRatioPercent: Int {
        let total = localSessions + cloudSessions
        guard total > 0 else { return 0 }
        return Int((Double(cloudSessions) / Double(total)) * 100)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startAttempts = try container.decodeIfPresent(Int.self, forKey: .startAttempts) ?? 0
        successfulFinalizations = try container.decodeIfPresent(Int.self, forKey: .successfulFinalizations) ?? 0
        failures = try container.decodeIfPresent(Int.self, forKey: .failures) ?? 0
        localFallbacks = try container.decodeIfPresent(Int.self, forKey: .localFallbacks) ?? 0
        totalLatencyMs = try container.decodeIfPresent(Double.self, forKey: .totalLatencyMs) ?? 0
        localSessions = try container.decodeIfPresent(Int.self, forKey: .localSessions) ?? 0
        cloudSessions = try container.decodeIfPresent(Int.self, forKey: .cloudSessions) ?? 0
        fallbackCloudDisabled = try container.decodeIfPresent(Int.self, forKey: .fallbackCloudDisabled) ?? 0
        fallbackConsentMissing = try container.decodeIfPresent(Int.self, forKey: .fallbackConsentMissing) ?? 0
        fallbackAPIKeyMissing = try container.decodeIfPresent(Int.self, forKey: .fallbackAPIKeyMissing) ?? 0
        fallbackNetworkUnavailable = try container.decodeIfPresent(Int.self, forKey: .fallbackNetworkUnavailable) ?? 0
        consentBlockEvents = try container.decodeIfPresent(Int.self, forKey: .consentBlockEvents) ?? 0
        retentionDeletedEntries = try container.decodeIfPresent(Int.self, forKey: .retentionDeletedEntries) ?? 0
        retentionCleanupRuns = try container.decodeIfPresent(Int.self, forKey: .retentionCleanupRuns) ?? 0
    }
}

@MainActor
final class ReliabilityMetricsStore: ObservableObject {
    @Published private(set) var metrics: ReliabilityMetricsSnapshot

    private let defaults: UserDefaults
    private let key = "app.reliabilityMetrics"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(ReliabilityMetricsSnapshot.self, from: data) {
            self.metrics = decoded
        } else {
            self.metrics = ReliabilityMetricsSnapshot()
        }
    }

    func trackStart() {
        metrics.startAttempts += 1
        persist()
    }

    func trackSuccess(latencyMs: Double) {
        metrics.successfulFinalizations += 1
        metrics.totalLatencyMs += latencyMs
        persist()
    }

    func trackFailure() {
        metrics.failures += 1
        persist()
    }

    func trackSessionRouting(usedCloud: Bool) {
        if usedCloud {
            metrics.cloudSessions += 1
        } else {
            metrics.localSessions += 1
        }
        persist()
    }

    func trackBlockedCloud(reason: CloudBlockReason) {
        switch reason {
        case .cloudDisabled:
            metrics.fallbackCloudDisabled += 1
        case .consentMissing:
            metrics.fallbackConsentMissing += 1
            metrics.consentBlockEvents += 1
        case .apiKeyMissing:
            metrics.fallbackAPIKeyMissing += 1
        case .networkUnavailable:
            metrics.fallbackNetworkUnavailable += 1
        }
        persist()
    }

    func trackLocalFallback() {
        metrics.localFallbacks += 1
        persist()
    }

    func trackRetentionCleanup(deletedCount: Int) {
        metrics.retentionCleanupRuns += 1
        metrics.retentionDeletedEntries += deletedCount
        persist()
    }

    func reset() {
        metrics = ReliabilityMetricsSnapshot()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(metrics) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class TranscriptHistoryStore: ObservableObject {
    @Published private(set) var entries: [TranscriptEntry] = []

    private let fileURL: URL
    private let metricsStore: ReliabilityMetricsStore?
    private(set) var retentionPolicy: TranscriptRetentionPolicy

    init(
        retentionPolicy: TranscriptRetentionPolicy = .keepForever,
        metricsStore: ReliabilityMetricsStore? = nil,
        storageURL: URL? = nil
    ) {
        self.retentionPolicy = retentionPolicy
        self.metricsStore = metricsStore
        if let storageURL {
            let folder = storageURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.fileURL = storageURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let folder = support.appendingPathComponent("iOSWhisperSmart", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.fileURL = folder.appendingPathComponent("transcript_history.json")
        }
        load()
        runRetentionCleanupIfNeeded()
    }

    func updateRetentionPolicy(_ policy: TranscriptRetentionPolicy) {
        retentionPolicy = policy
        runRetentionCleanupIfNeeded()
    }

    func add(transcript: String, engine: EnginePolicy, usedCloud: Bool) {
        guard retentionPolicy != .manualOnly else { return }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let entry = TranscriptEntry(id: UUID(), createdAt: Date(), transcript: trimmed, engine: engine, usedCloud: usedCloud)
        entries.insert(entry, at: 0)
        runRetentionCleanupIfNeeded()
        save()
    }

    func remove(_ entry: TranscriptEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    private func runRetentionCleanupIfNeeded() {
        guard let interval = retentionPolicy.retentionInterval else { return }

        let cutoffDate = Date().addingTimeInterval(-interval)
        let originalCount = entries.count
        entries.removeAll { $0.createdAt < cutoffDate }
        let deleted = originalCount - entries.count
        if deleted > 0 {
            save()
        }
        metricsStore?.trackRetentionCleanup(deletedCount: deleted)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([TranscriptEntry].self, from: data) {
            entries = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
