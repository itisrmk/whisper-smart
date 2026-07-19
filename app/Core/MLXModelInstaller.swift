import Foundation
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "MLXModelInstaller")

/// Downloads MLX models into the Hugging Face cache via the runner script and
/// tracks per-model install state with marker files. Also ensures the Python
/// runtime is installed first, so one click sets up everything a model needs.
final class MLXModelInstaller: ObservableObject {
    static let shared = MLXModelInstaller()

    enum Phase: Equatable {
        case idle
        /// `modelID` identifies which card is busy; `detail` is user-facing.
        case installing(modelID: String, detail: String)
        case failed(modelID: String, message: String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Cancellation marker owned by a single install task. Each install
    /// captures its own token, so cancelling task A stays effective even if
    /// a new install starts while A is still running on the serial queue —
    /// a shared flag reset by `install()` would resurrect the cancelled
    /// download (e.g. onboarding: cancel model A, then install model B).
    private final class CancelToken {
        var isCancelled = false
    }

    private let queue = DispatchQueue(label: "com.visperflow.mlx.install", qos: .utility)
    private let processLock = NSLock()
    private var currentProcess: Process?
    private var activeInstallToken: CancelToken?
    private let downloadTimeout: TimeInterval = 60 * 60

    private init() {}

    // MARK: - State

    func isInstalled(_ model: MLXModel) -> Bool {
        guard let marker = Self.markerURL(for: model) else { return false }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    private var isInstalling: Bool {
        if case .installing = phase { return true }
        return false
    }

    // MARK: - Install

    /// Installs the runtime (if needed) and prefetches the model. `completion`
    /// runs on the main queue with `true` on success.
    func install(_ model: MLXModel, completion: ((Bool) -> Void)? = nil) {
        guard !isInstalling else {
            completion?(false)
            return
        }

        MLXSetupPolicy.setupConsentGranted = true
        setPhase(.installing(modelID: model.id, detail: "Preparing runtime…"))
        let token = CancelToken()
        activeInstallToken = token

        queue.async {
            do {
                let pythonCommand = try MLXRuntimeBootstrapManager.shared.ensureRuntimeReady(allowInstall: true)
                guard !token.isCancelled else {
                    self.finish(model: model, success: false, completion: completion)
                    return
                }

                self.setPhase(.installing(modelID: model.id, detail: "Downloading \(model.displayName) (\(model.approxSizeLabel))…"))
                try self.runDownload(pythonCommand: pythonCommand, model: model)
                guard !token.isCancelled else {
                    self.finish(model: model, success: false, completion: completion)
                    return
                }

                try self.writeMarker(for: model)
                logger.info("MLX model installed: \(model.id, privacy: .public)")
                self.setPhase(.idle)
                self.finish(model: model, success: true, completion: completion)
            } catch {
                guard !token.isCancelled else {
                    self.finish(model: model, success: false, completion: completion)
                    return
                }
                logger.error("MLX model install failed for \(model.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.setPhase(.failed(modelID: model.id, message: error.localizedDescription))
                self.finish(model: model, success: false, completion: completion)
            }
        }
    }

    func cancelInstall() {
        activeInstallToken?.isCancelled = true
        activeInstallToken = nil
        processLock.lock()
        currentProcess?.terminate()
        currentProcess = nil
        processLock.unlock()
        setPhase(.idle)
    }

    /// Removes the install marker so the model shows as not installed. The HF
    /// cache itself is left in place (re-install is instant if still cached).
    func uninstall(_ model: MLXModel) {
        if let marker = Self.markerURL(for: model) {
            try? FileManager.default.removeItem(at: marker)
        }
        postChange()
    }

    // MARK: - Internals

    private func runDownload(pythonCommand: String, model: MLXModel) throws {
        let scriptURL = try MLXRunnerScript.resolveURL()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            pythonCommand, scriptURL.path,
            "--download",
            "--engine", model.engine.rawValue,
            "--model", model.repo,
        ]

        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe

        let stderrData = NSMutableData()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stderrData.append(chunk) }
        }

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }

        processLock.lock()
        currentProcess = process
        processLock.unlock()

        defer {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            processLock.lock()
            currentProcess = nil
            processLock.unlock()
        }

        try process.run()

        if completion.wait(timeout: .now() + downloadTimeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 2)
            }
            throw STTError.providerError(message: "Model download timed out. Check your network and retry.")
        }

        guard process.terminationStatus == 0 else {
            let detail = String(data: stderrData as Data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw STTError.providerError(
                message: detail.isEmpty
                    ? "Model download failed (exit \(process.terminationStatus))."
                    : String(detail.suffix(300))
            )
        }
    }

    private static func markerURL(for model: MLXModel) -> URL? {
        AppStoragePaths.resolvedModelURL(relativePath: "mlx-models/\(model.id).installed")
    }

    private func writeMarker(for model: MLXModel) throws {
        guard let marker = Self.markerURL(for: model) else {
            throw STTError.providerError(message: "Cannot resolve Application Support path for install marker.")
        }
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("installed \(model.repo)\n".utf8).write(to: marker)
    }

    private func setPhase(_ newPhase: Phase) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.phase != newPhase else { return }
            self.phase = newPhase
        }
    }

    private func finish(model: MLXModel, success: Bool, completion: ((Bool) -> Void)?) {
        postChange()
        DispatchQueue.main.async {
            completion?(success)
        }
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mlxModelInstallDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    /// An MLX model finished installing, failed, or was uninstalled.
    static let mlxModelInstallDidChange = Notification.Name("mlxModelInstallDidChange")
}
