import Foundation
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "ModelDownloader")

/// Coordinates downloading of model files for local STT providers.
final class ModelDownloaderService: NSObject {

    static let shared = ModelDownloaderService()

    private final class DownloadContext {
        let variant: ModelVariant
        weak var state: ModelDownloadState?
        let task: URLSessionDownloadTask
        var isUserCancelled = false
        var completionError: String?

        init(variant: ModelVariant, state: ModelDownloadState, task: URLSessionDownloadTask) {
            self.variant = variant
            self.state = state
            self.task = task
        }
    }

    private let runtimeBootstrapManager = ParakeetRuntimeBootstrapManager.shared
    private let stateQueue = DispatchQueue(label: "com.visperflow.modeldownloader.state")
    private var activeDownloadsByVariantID: [String: DownloadContext] = [:]
    private var variantIDByTaskID: [Int: String] = [:]
    private var resumeDataByVariantID: [String: Data] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    // MARK: - Public

    /// Starts downloading the given variant and drives state transitions.
    func download(variant: ModelVariant, state: ModelDownloadState) {
        // Already on disk and valid — just sync state.
        if variant.isDownloaded {
            logger.info("Model already downloaded and valid: \(variant.id)")
            state.transitionToReady()
            return
        }
        switch state.phase {
        case .downloading, .ready:
            return
        case .notReady, .failed:
            break
        }

        guard let sourceURL = variant.remoteURL else {
            state.transitionToFailed(message: variant.downloadUnavailableReason ?? "Model source not configured.")
            return
        }

        stateQueue.async {
            guard self.activeDownloadsByVariantID[variant.id] == nil else {
                logger.info("Download already active for \(variant.id)")
                return
            }

            let task: URLSessionDownloadTask
            if let resumeData = self.resumeDataByVariantID.removeValue(forKey: variant.id) {
                task = self.session.downloadTask(withResumeData: resumeData)
                logger.info("Resuming model download for \(variant.id)")
            } else {
                task = self.session.downloadTask(with: sourceURL)
                logger.info("Starting model download for \(variant.id) from \(sourceURL.absoluteString, privacy: .public)")
            }

            let context = DownloadContext(variant: variant, state: state, task: task)
            self.activeDownloadsByVariantID[variant.id] = context
            self.variantIDByTaskID[task.taskIdentifier] = variant.id

            DispatchQueue.main.async {
                state.transitionToDownloading()
            }

            task.resume()
        }
    }

    /// Cancels an in-progress download while preserving resume data when possible.
    func cancel(variant: ModelVariant, state: ModelDownloadState) {
        stateQueue.async {
            guard let context = self.activeDownloadsByVariantID[variant.id] else {
                DispatchQueue.main.async {
                    state.reset()
                }
                return
            }

            context.isUserCancelled = true
            context.task.cancel(byProducingResumeData: { [weak self] data in
                guard let self else { return }
                guard let data, !data.isEmpty else { return }
                self.stateQueue.async {
                    self.resumeDataByVariantID[variant.id] = data
                }
            })

            DispatchQueue.main.async {
                state.reset()
            }
            logger.info("Download cancelled for \(variant.id)")
        }
    }
}

// MARK: - URLSession delegates

extension ModelDownloaderService: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        var stateToUpdate: ModelDownloadState?
        var progress: Double?

        stateQueue.sync {
            guard let context = context(forTaskID: downloadTask.taskIdentifier),
                  let state = context.state else {
                return
            }

            let expectedBytes: Int64
            if totalBytesExpectedToWrite > 0 {
                expectedBytes = totalBytesExpectedToWrite
            } else {
                expectedBytes = max(context.variant.sizeBytes, 1)
            }

            guard expectedBytes > 0 else { return }
            stateToUpdate = state
            progress = min(max(Double(totalBytesWritten) / Double(expectedBytes), 0), 1)
        }

        guard let state = stateToUpdate, let progress else { return }
        DispatchQueue.main.async {
            state.updateProgress(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        stateQueue.sync {
            guard let context = context(forTaskID: downloadTask.taskIdentifier) else { return }

            guard let destinationURL = context.variant.localURL else {
                context.completionError = "Cannot resolve model storage path. Check disk permissions."
                return
            }

            if let moveError = Self.moveDownloadedFile(from: location, to: destinationURL) {
                context.completionError = moveError
                return
            }

            if let validationError = validateDownloadedModel(variant: context.variant, at: destinationURL) {
                context.completionError = validationError
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var completionState: ModelDownloadState?
        var completionAction: (() -> Void)?

        stateQueue.sync {
            guard let context = removeContext(forTaskID: task.taskIdentifier) else { return }

            if context.isUserCancelled {
                return
            }

            guard let state = context.state else { return }
            completionState = state

            if let error {
                if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                   !resumeData.isEmpty {
                    resumeDataByVariantID[context.variant.id] = resumeData
                }

                let message = downloadFailureMessage(for: error)
                completionAction = {
                    state.transitionToFailed(message: message)
                }
                return
            }

            if let completionError = context.completionError {
                completionAction = {
                    state.transitionToFailed(message: completionError)
                }
                return
            }

            completionAction = {
                state.transitionToReady()
            }
        }

        guard completionState != nil, let completionAction else { return }
        DispatchQueue.main.async(execute: completionAction)
    }
}

// MARK: - Validation and plumbing

private extension ModelDownloaderService {
    private func context(forTaskID taskID: Int) -> DownloadContext? {
        guard let variantID = variantIDByTaskID[taskID] else { return nil }
        return activeDownloadsByVariantID[variantID]
    }

    private func removeContext(forTaskID taskID: Int) -> DownloadContext? {
        guard let variantID = variantIDByTaskID.removeValue(forKey: taskID) else { return nil }
        return activeDownloadsByVariantID.removeValue(forKey: variantID)
    }

    static func moveDownloadedFile(from sourceURL: URL, to destinationURL: URL) -> String? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return nil
        } catch {
            logger.error("Failed to move downloaded model to \(destinationURL.path): \(error.localizedDescription)")
            return "Failed to store downloaded model: \(error.localizedDescription)"
        }
    }

    func validateDownloadedModel(variant: ModelVariant, at modelURL: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: modelURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            return "Downloaded file is unreadable. Check disk permissions and retry."
        }

        guard fileSize >= variant.minimumValidBytes else {
            return "Downloaded file is too small (\(fileSize / 1_000_000) MB). Minimum expected is \(variant.minimumValidBytes / 1_000_000) MB."
        }

        guard variant.id == ModelVariant.parakeetCTC06B.id else {
            return nil
        }

        return parakeetONNXPreflightError(modelURL: modelURL)
    }

    func parakeetONNXPreflightError(modelURL: URL) -> String? {
        let pythonCommand: String
        do {
            pythonCommand = try runtimeBootstrapManager.ensureRuntimeReady()
        } catch {
            return "Downloaded file saved, but ONNX preflight could not run because runtime bootstrap failed: \(error.localizedDescription)"
        }

        let scriptURL: URL
        do {
            scriptURL = try resolveParakeetRunnerScriptURL()
        } catch {
            return "Downloaded file saved, but ONNX preflight could not run: \(error.localizedDescription)"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [pythonCommand, scriptURL.path, "--check", "--model", modelURL.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return "ONNX preflight launch failed: \(error.localizedDescription)"
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            return mappedPreflightFailure(
                details: !stderr.isEmpty ? stderr : stdout,
                exitCode: process.terminationStatus
            )
        }

        return nil
    }

    func resolveParakeetRunnerScriptURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let override = environment["VISPERFLOW_PARAKEET_SCRIPT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }

        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        candidates.append(workingDirectory.appendingPathComponent("scripts/parakeet_infer.py"))

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(sourceRoot.appendingPathComponent("scripts/parakeet_infer.py"))

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("scripts/parakeet_infer.py"))
        }

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        let checkedPaths = candidates.map(\.path).joined(separator: ", ")
        throw NSError(
            domain: "ModelDownloaderService",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Parakeet inference runner script not found. Checked: \(checkedPaths). Set VISPERFLOW_PARAKEET_SCRIPT."
            ]
        )
    }

    func mappedPreflightFailure(details: String, exitCode: Int32) -> String {
        let lowercased = details.lowercased()
        if lowercased.contains("model_load_error") {
            return "MODEL_LOAD_ERROR during ONNX preflight. The downloaded file is not a loadable Parakeet ONNX model. Delete it and download again."
        }
        if lowercased.contains("tokenizer_missing") {
            return "Model download completed but tokenizer assets are missing. Add tokenizer.model/tokenizer.json/vocab.txt next to the ONNX model or set VISPERFLOW_PARAKEET_TOKENIZER."
        }
        if lowercased.contains("dependency_missing") || lowercased.contains("modulenotfounderror") {
            return "Parakeet runtime dependencies are missing. Run Repair Parakeet Runtime in Settings → Provider."
        }
        if details.isEmpty {
            return "ONNX preflight failed with exit status \(exitCode) and no diagnostics."
        }
        return "ONNX preflight failed: \(details)"
    }

    func downloadFailureMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "Download failed: no internet connection."
            case NSURLErrorTimedOut:
                return "Download timed out. Retry when the network is stable."
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "Download failed: cannot reach the model host."
            default:
                break
            }
        }
        return "Download failed: \(error.localizedDescription)"
    }
}
