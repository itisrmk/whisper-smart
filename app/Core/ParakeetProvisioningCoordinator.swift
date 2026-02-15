import Foundation
import os.log

private let provisioningLogger = Logger(subsystem: "com.visperflow", category: "ParakeetProvisioning")

actor ParakeetProvisioningCoordinator {
    static let shared = ParakeetProvisioningCoordinator()

    private let variant = ModelVariant.parakeetCTC06B
    private let sourceStore = ParakeetModelSourceConfigurationStore.shared
    private let runtimeBootstrap = ParakeetRuntimeBootstrapManager.shared
    private let telemetry = ParakeetTelemetryStore.shared
    private let backgroundState = ModelDownloadState(variant: .parakeetCTC06B)

    private var modelRetryTask: Task<Void, Never>?
    private var runtimeRetryTask: Task<Void, Never>?
    private var modelRetryCount = 0
    private var runtimeRetryCount = 0
    private let maxModelRetries = 5
    private let maxRuntimeRetries = 4

    private init() {}

    func ensureAutomaticSetupForCurrentSelection(
        forceModelRetry: Bool = false,
        forceRuntimeRepair: Bool = false,
        reason: String
    ) async {
        guard STTProviderKind.loadSelection() == .parakeet else {
            cancelRetryTasks()
            return
        }

        ensureRecommendedSource()

        if forceModelRetry {
            backgroundState.reset()
        }
        ModelDownloaderService.shared.download(variant: variant, state: backgroundState)

        provisioningLogger.info(
            "Automatic Parakeet setup reason=\(reason, privacy: .public) forceModelRetry=\(forceModelRetry) forceRuntimeRepair=\(forceRuntimeRepair)"
        )

        Task.detached(priority: .utility) { [runtimeBootstrap] in
            do {
                _ = try runtimeBootstrap.ensureRuntimeReady(forceRepair: forceRuntimeRepair)
            } catch {
                provisioningLogger.warning("Background runtime bootstrap attempt failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func handleModelDownloadEvent(isReady: Bool) async {
        guard STTProviderKind.loadSelection() == .parakeet else { return }

        if isReady {
            modelRetryCount = 0
            modelRetryTask?.cancel()
            modelRetryTask = nil
            return
        }

        scheduleModelRetryIfNeeded()
    }

    func handleRuntimeBootstrapStatusChange(_ status: ParakeetRuntimeBootstrapStatus) async {
        guard STTProviderKind.loadSelection() == .parakeet else { return }

        switch status.phase {
        case .ready:
            runtimeRetryCount = 0
            runtimeRetryTask?.cancel()
            runtimeRetryTask = nil
        case .failed:
            await telemetry.recordRuntimeBootstrapFailure(status.detail)
            scheduleRuntimeRetryIfNeeded()
        case .idle, .bootstrapping:
            break
        }
    }

    func cancelRetries() async {
        cancelRetryTasks()
    }
}

private extension ParakeetProvisioningCoordinator {
    func ensureRecommendedSource() {
        if sourceStore.selectedSourceID(for: variant.id) != "hf_parakeet_tdt06b_v3_onnx" {
            _ = sourceStore.selectSource(id: "hf_parakeet_tdt06b_v3_onnx", for: variant.id)
        }
    }

    func scheduleModelRetryIfNeeded() {
        guard modelRetryTask == nil else { return }
        guard modelRetryCount < maxModelRetries else {
            provisioningLogger.error("Parakeet model retry budget exhausted")
            return
        }

        let attempt = modelRetryCount + 1
        let delaySeconds = min(pow(2.0, Double(modelRetryCount)) * 8.0, 90.0)
        provisioningLogger.warning(
            "Scheduling Parakeet model retry attempt \(attempt) in \(delaySeconds, privacy: .public)s"
        )

        Task { await telemetry.recordModelDownloadRetryScheduled(attempt: attempt) }

        modelRetryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            await self.executeModelRetry()
        }
    }

    func scheduleRuntimeRetryIfNeeded() {
        guard runtimeRetryTask == nil else { return }
        guard runtimeRetryCount < maxRuntimeRetries else {
            provisioningLogger.error("Parakeet runtime retry budget exhausted")
            return
        }

        let attempt = runtimeRetryCount + 1
        let delaySeconds = min(pow(2.0, Double(runtimeRetryCount)) * 10.0, 120.0)
        provisioningLogger.warning(
            "Scheduling Parakeet runtime retry attempt \(attempt) in \(delaySeconds, privacy: .public)s"
        )

        Task { await telemetry.recordRuntimeBootstrapRetryScheduled(attempt: attempt) }

        runtimeRetryTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            await self.executeRuntimeRetry()
        }
    }

    func executeModelRetry() async {
        modelRetryTask = nil
        modelRetryCount += 1
        await ensureAutomaticSetupForCurrentSelection(
            forceModelRetry: true,
            forceRuntimeRepair: false,
            reason: "scheduled_model_retry_\(modelRetryCount)"
        )
    }

    func executeRuntimeRetry() async {
        runtimeRetryTask = nil
        runtimeRetryCount += 1
        await ensureAutomaticSetupForCurrentSelection(
            forceModelRetry: false,
            forceRuntimeRepair: true,
            reason: "scheduled_runtime_retry_\(runtimeRetryCount)"
        )
    }

    func cancelRetryTasks() {
        modelRetryTask?.cancel()
        runtimeRetryTask?.cancel()
        modelRetryTask = nil
        runtimeRetryTask = nil
        modelRetryCount = 0
        runtimeRetryCount = 0
    }
}
