import Foundation
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "ModelDownloader")

/// Coordinates downloading of model files for local STT providers.
final class ModelDownloaderService: NSObject {

    static let shared = ModelDownloaderService()

    private final class DownloadContext {
        let variant: ModelVariant
        let source: ParakeetResolvedModelSource
        weak var state: ModelDownloadState?
        let task: URLSessionDownloadTask
        let resumeDataKey: String
        var isUserCancelled = false
        var completionError: String?

        init(
            variant: ModelVariant,
            source: ParakeetResolvedModelSource,
            state: ModelDownloadState,
            task: URLSessionDownloadTask,
            resumeDataKey: String
        ) {
            self.variant = variant
            self.source = source
            self.state = state
            self.task = task
            self.resumeDataKey = resumeDataKey
        }
    }

    private let runtimeBootstrapManager = ParakeetRuntimeBootstrapManager.shared
    private let stateQueue = DispatchQueue(label: "com.visperflow.modeldownloader.state")
    private var activeDownloadsByVariantID: [String: DownloadContext] = [:]
    private var variantIDByTaskID: [Int: String] = [:]
    private var resumeDataByDownloadKey: [String: Data] = [:]

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

        guard let source = variant.configuredSource else {
            state.transitionToFailed(message: variant.downloadUnavailableReason ?? "Model source not configured.")
            return
        }

        guard let sourceURL = source.modelURL else {
            state.transitionToFailed(
                message: source.error ?? variant.downloadUnavailableReason ?? "Model source not configured."
            )
            return
        }

        stateQueue.async {
            guard self.activeDownloadsByVariantID[variant.id] == nil else {
                logger.info("Download already active for \(variant.id)")
                return
            }

            let resumeKey = Self.resumeDataKey(variantID: variant.id, source: source)
            let task: URLSessionDownloadTask
            if let resumeData = self.resumeDataByDownloadKey.removeValue(forKey: resumeKey) {
                task = self.session.downloadTask(withResumeData: resumeData)
                logger.info("Resuming model download for \(variant.id) from source \(source.selectedSourceName, privacy: .public)")
            } else {
                task = self.session.downloadTask(with: sourceURL)
                logger.info("Starting model download for \(variant.id) from \(sourceURL.absoluteString, privacy: .public)")
            }

            let context = DownloadContext(
                variant: variant,
                source: source,
                state: state,
                task: task,
                resumeDataKey: resumeKey
            )
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
                    self.resumeDataByDownloadKey[context.resumeDataKey] = data
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

            if let tokenizerError = downloadTokenizerArtifactIfNeeded(
                variant: context.variant,
                source: context.source
            ) {
                context.completionError = tokenizerError
                cleanupArtifacts(variant: context.variant, source: context.source, modelURL: destinationURL)
                return
            }

            if let validationError = validateDownloadedModel(
                variant: context.variant,
                at: destinationURL,
                source: context.source
            ) {
                context.completionError = validationError
                cleanupArtifacts(variant: context.variant, source: context.source, modelURL: destinationURL)
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
                    resumeDataByDownloadKey[context.resumeDataKey] = resumeData
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
    static func resumeDataKey(variantID: String, source: ParakeetResolvedModelSource) -> String {
        let modelURL = source.modelURL?.absoluteString ?? "none"
        return "\(variantID)|\(source.selectedSourceID)|\(modelURL)"
    }

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

    func cleanupArtifacts(variant: ModelVariant, source: ParakeetResolvedModelSource, modelURL: URL) {
        try? FileManager.default.removeItem(at: modelURL)
        if source.tokenizerURL != nil,
           let tokenizerURL = variant.tokenizerLocalURL(using: source) {
            try? FileManager.default.removeItem(at: tokenizerURL)
        }
    }

    func downloadTokenizerArtifactIfNeeded(
        variant: ModelVariant,
        source: ParakeetResolvedModelSource
    ) -> String? {
        guard let tokenizerRemoteURL = source.tokenizerURL else {
            return nil
        }

        guard let tokenizerDestinationURL = variant.tokenizerLocalURL(using: source) else {
            return "Tokenizer path resolution failed. Check Application Support permissions and retry."
        }

        if let downloadError = downloadAuxiliaryArtifact(
            from: tokenizerRemoteURL,
            to: tokenizerDestinationURL,
            label: "tokenizer"
        ) {
            return downloadError
        }

        return validateTokenizerArtifact(at: tokenizerDestinationURL)
    }

    func downloadAuxiliaryArtifact(from sourceURL: URL, to destinationURL: URL, label: String) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var completionError: String?

        let task = URLSession.shared.downloadTask(with: sourceURL) { tempURL, response, error in
            defer { semaphore.signal() }

            if let error {
                completionError = "Failed to download \(label) artifact: \(self.downloadFailureMessage(for: error))"
                return
            }

            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode) == false {
                completionError = "Failed to download \(label) artifact: server returned HTTP \(httpResponse.statusCode)."
                return
            }

            guard let tempURL else {
                completionError = "Failed to download \(label) artifact: no file data received."
                return
            }

            if let moveError = Self.moveDownloadedFile(from: tempURL, to: destinationURL) {
                completionError = "Failed to store \(label) artifact: \(moveError)"
                return
            }
        }

        task.resume()
        semaphore.wait()
        return completionError
    }

    func validateDownloadedModel(
        variant: ModelVariant,
        at modelURL: URL,
        source: ParakeetResolvedModelSource
    ) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: modelURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            return "Downloaded model file is unreadable. Check disk permissions and retry."
        }

        guard fileSize >= variant.minimumValidBytes else {
            return "Downloaded model file is too small (\(fileSize / 1_000_000) MB). Minimum expected is \(variant.minimumValidBytes / 1_000_000) MB."
        }

        if source.tokenizerURL != nil {
            guard let tokenizerURL = variant.tokenizerLocalURL(using: source) else {
                return "Tokenizer path resolution failed after download. Retry the download."
            }
            if let tokenizerValidationError = validateTokenizerArtifact(at: tokenizerURL) {
                return tokenizerValidationError
            }
        }

        guard variant.id == ModelVariant.parakeetCTC06B.id else {
            return nil
        }

        let tokenizerURL = variant.tokenizerLocalURL(using: source)
        return parakeetONNXPreflightError(modelURL: modelURL, tokenizerURL: tokenizerURL)
    }

    func validateTokenizerArtifact(at tokenizerURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: tokenizerURL.path) else {
            return "Tokenizer artifact is missing after download. Retry the download."
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: tokenizerURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            return "Tokenizer artifact cannot be read. Check disk permissions and retry."
        }

        guard fileSize >= 128 else {
            return "Tokenizer artifact appears incomplete (\(fileSize) bytes). Retry the download."
        }

        let extensionValue = tokenizerURL.pathExtension.lowercased()
        switch extensionValue {
        case "txt":
            guard let text = try? String(contentsOf: tokenizerURL),
                  text.split(whereSeparator: \.isNewline).count >= 10 else {
                return "Tokenizer vocab.txt is invalid or empty. Retry the download."
            }
        case "json":
            guard let data = try? Data(contentsOf: tokenizerURL),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  dictionary.isEmpty == false else {
                return "Tokenizer JSON is invalid. Retry the download."
            }
        case "model":
            // Binary SentencePiece file; size validation above is the primary preflight check.
            break
        default:
            return "Tokenizer file extension '.\(extensionValue)' is unsupported. Use .model, .json, or .txt."
        }

        return nil
    }

    func parakeetONNXPreflightError(modelURL: URL, tokenizerURL: URL?) -> String? {
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

        var arguments = [pythonCommand, scriptURL.path, "--check", "--model", modelURL.path]
        if let tokenizerURL {
            arguments += ["--tokenizer", tokenizerURL.path]
        }
        process.arguments = arguments

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
                    "Parakeet inference runner script not found. Checked: \(checkedPaths)."
            ]
        )
    }

    func mappedPreflightFailure(details: String, exitCode: Int32) -> String {
        let lowercased = details.lowercased()
        if lowercased.contains("model_load_error") {
            return "MODEL_LOAD_ERROR during ONNX preflight. The downloaded file is not a loadable Parakeet ONNX model. Delete it and download again."
        }
        if lowercased.contains("tokenizer_missing") || lowercased.contains("tokenizer_error") {
            return "Tokenizer validation failed during ONNX preflight. Re-download model artifacts from Settings -> Provider."
        }
        if lowercased.contains("dependency_missing") || lowercased.contains("modulenotfounderror") {
            return "Parakeet runtime dependencies are missing. Run Repair Parakeet Runtime in Settings -> Provider."
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
