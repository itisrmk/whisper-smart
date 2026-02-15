import Foundation
import os.log

private let telemetryLogger = Logger(subsystem: "com.visperflow", category: "ParakeetTelemetry")

struct ParakeetTelemetrySnapshot: Codable, Equatable {
    var runtimeBootstrapFailureCounts: [String: Int]
    var runtimeBootstrapRetryCount: Int
    var modelDownloadRetryCount: Int
    var modelDownloadTransportRetryCount: Int
    var modelDownloadFailureCounts: [String: Int]
    var lastUpdatedAt: Date

    static let empty = ParakeetTelemetrySnapshot(
        runtimeBootstrapFailureCounts: [:],
        runtimeBootstrapRetryCount: 0,
        modelDownloadRetryCount: 0,
        modelDownloadTransportRetryCount: 0,
        modelDownloadFailureCounts: [:],
        lastUpdatedAt: Date()
    )
}

actor ParakeetTelemetryStore {
    static let shared = ParakeetTelemetryStore()

    private let defaults = UserDefaults.standard
    private let snapshotKey = "parakeet.telemetry.snapshot.v1"
    private var snapshot: ParakeetTelemetrySnapshot

    private init() {
        if let raw = defaults.data(forKey: snapshotKey),
           let decoded = try? JSONDecoder().decode(ParakeetTelemetrySnapshot.self, from: raw) {
            snapshot = decoded
        } else {
            snapshot = .empty
        }
    }

    func snapshotValue() -> ParakeetTelemetrySnapshot {
        snapshot
    }

    func recordRuntimeBootstrapFailure(_ message: String) {
        increment(key: classifyRuntimeBootstrapFailure(message), in: &snapshot.runtimeBootstrapFailureCounts)
        persistAndNotify(reason: "runtime_failure")
    }

    func recordRuntimeBootstrapRetryScheduled(attempt: Int) {
        snapshot.runtimeBootstrapRetryCount += 1
        persistAndNotify(reason: "runtime_retry_\(attempt)")
    }

    func recordModelDownloadFailure(_ message: String) {
        increment(key: classifyModelDownloadFailure(message), in: &snapshot.modelDownloadFailureCounts)
        persistAndNotify(reason: "model_failure")
    }

    func recordModelDownloadRetryScheduled(attempt: Int) {
        snapshot.modelDownloadRetryCount += 1
        persistAndNotify(reason: "model_retry_\(attempt)")
    }

    func recordModelDownloadTransportRetry(attempt: Int) {
        snapshot.modelDownloadTransportRetryCount += 1
        persistAndNotify(reason: "model_transport_retry_\(attempt)")
    }

    func reset() {
        snapshot = .empty
        persistAndNotify(reason: "reset")
    }
}

private extension ParakeetTelemetryStore {
    func increment(key: String, in bucket: inout [String: Int]) {
        bucket[key, default: 0] += 1
    }

    func persistAndNotify(reason: String) {
        snapshot.lastUpdatedAt = Date()

        if let encoded = try? JSONEncoder().encode(snapshot) {
            defaults.set(encoded, forKey: snapshotKey)
        }

        telemetryLogger.info(
            "Parakeet telemetry updated reason=\(reason, privacy: .public) runtimeRetries=\(self.snapshot.runtimeBootstrapRetryCount) modelRetries=\(self.snapshot.modelDownloadRetryCount)"
        )

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .parakeetTelemetryDidChange, object: nil)
        }
    }

    func classifyRuntimeBootstrapFailure(_ message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("python") && normalized.contains("not found") { return "missing_python" }
        if normalized.contains("pip") || normalized.contains("ensurepip") { return "pip_install_error" }
        if normalized.contains("permission") || normalized.contains("operation not permitted") { return "filesystem_permission" }
        if normalized.contains("timed out") || normalized.contains("timeout") { return "timeout" }
        if normalized.contains("network") || normalized.contains("connection") { return "network" }
        return "other"
    }

    func classifyModelDownloadFailure(_ message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("http 404") { return "http_404" }
        if normalized.contains("http 429") { return "http_429" }
        if normalized.contains("http 5") { return "http_5xx" }
        if normalized.contains("no internet") || normalized.contains("cannot reach") { return "network" }
        if normalized.contains("timed out") { return "timeout" }
        if normalized.contains("checksum") { return "checksum" }
        if normalized.contains("tokenizer") { return "tokenizer" }
        if normalized.contains("validation") || normalized.contains("incomplete") || normalized.contains("too small") { return "validation" }
        return "other"
    }
}

extension Notification.Name {
    static let parakeetTelemetryDidChange = Notification.Name("parakeetTelemetryDidChange")
}
