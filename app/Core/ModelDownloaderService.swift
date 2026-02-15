import Foundation
import CryptoKit
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "ModelDownloader")

/// Coordinates downloading of model files for local STT providers.
final class ModelDownloaderService: NSObject {

    static let shared = ModelDownloaderService()

    private final class DownloadContext {
        let variant: ModelVariant
        var source: ParakeetResolvedModelSource
        weak var state: ModelDownloadState?
        var task: URLSessionDownloadTask
        var resumeDataKey: String
        var isUserCancelled = false
        var completionError: String?
        var retryCount = 0
        var expectedContentLength: Int64?
        var attemptedSourceIDs: Set<String>

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
            self.attemptedSourceIDs = [source.selectedSourceID]
        }
    }

    private let runtimeBootstrapManager = ParakeetRuntimeBootstrapManager.shared
    private let stateQueue = DispatchQueue(label: "com.visperflow.modeldownloader.state")
    private let maxRetryAttempts = 2
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

            if let response = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                context.completionError = "Model download failed: server returned HTTP \(response.statusCode)."
                return
            }

            guard let destinationURL = context.variant.localURL else {
                context.completionError = "Cannot resolve model storage path. Check disk permissions."
                return
            }

            if let expectedLength = downloadTask.response?.expectedContentLength, expectedLength > 0 {
                context.expectedContentLength = expectedLength
            }

            if let moveError = Self.moveDownloadedFileAtomically(from: location, to: destinationURL) {
                context.completionError = moveError
                return
            }

            if let modelDataError = downloadModelDataArtifactIfNeeded(
                variant: context.variant,
                source: context.source
            ) {
                context.completionError = modelDataError
                cleanupArtifacts(variant: context.variant, source: context.source, modelURL: destinationURL)
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
            guard let context = context(forTaskID: task.taskIdentifier) else { return }

            if context.isUserCancelled {
                _ = removeContext(forTaskID: task.taskIdentifier)
                return
            }

            if let error,
               shouldRetry(error: error, retryCount: context.retryCount) {
                context.retryCount += 1
                let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                let nextTask: URLSessionDownloadTask
                if let resumeData, !resumeData.isEmpty {
                    nextTask = session.downloadTask(withResumeData: resumeData)
                } else if let modelURL = context.source.modelURL {
                    nextTask = session.downloadTask(with: modelURL)
                } else {
                    completionAction = {
                        context.state?.transitionToFailed(message: "Model source URL is invalid.")
                    }
                    _ = removeContext(forTaskID: task.taskIdentifier)
                    return
                }

                variantIDByTaskID.removeValue(forKey: task.taskIdentifier)
                variantIDByTaskID[nextTask.taskIdentifier] = context.variant.id
                context.task = nextTask
                nextTask.resume()

                logger.info("Retrying model download for \(context.variant.id) attempt=\(context.retryCount + 1)")
                return
            }

            guard let context = removeContext(forTaskID: task.taskIdentifier) else { return }
            guard let state = context.state else { return }
            completionState = state

            if let error {
                if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                   !resumeData.isEmpty {
                    resumeDataByDownloadKey[context.resumeDataKey] = resumeData
                }

                let message = downloadFailureMessage(for: error, response: task.response)
                completionAction = {
                    state.transitionToFailed(message: message)
                }
                return
            }

            if let completionError = context.completionError {
                if self.tryAutoSwitchSourceAfter404(context: context, previousTaskID: task.taskIdentifier) {
                    return
                }

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

    private func tryAutoSwitchSourceAfter404(context: DownloadContext, previousTaskID: Int) -> Bool {
        guard let failure = context.completionError?.lowercased(), failure.contains("http 404") else {
            return false
        }

        let sourceStore = ParakeetModelSourceConfigurationStore.shared
        let alternatives = sourceStore.availableSources(for: context.variant.id)
            .filter { $0.id != context.source.selectedSourceID }
            .filter { context.attemptedSourceIDs.contains($0.id) == false }

        guard let fallback = alternatives.first(where: { $0.modelURL != nil }) else {
            return false
        }

        _ = sourceStore.selectSource(id: fallback.id, for: context.variant.id)
        let resolved = sourceStore.resolvedSource(for: context.variant.id)
        guard let fallbackURL = resolved.modelURL else {
            return false
        }

        let nextTask = session.downloadTask(with: fallbackURL)

        variantIDByTaskID.removeValue(forKey: previousTaskID)
        variantIDByTaskID[nextTask.taskIdentifier] = context.variant.id

        context.source = resolved
        context.resumeDataKey = Self.resumeDataKey(variantID: context.variant.id, source: resolved)
        context.task = nextTask
        context.retryCount = 0
        context.completionError = nil
        context.expectedContentLength = nil
        context.attemptedSourceIDs.insert(fallback.id)

        logger.warning(
            "Primary source returned HTTP 404 for \(context.variant.id, privacy: .public). Auto-switching to source \(resolved.selectedSourceName, privacy: .public)."
        )

        nextTask.resume()
        return true
    }

    static func moveDownloadedFileAtomically(from sourceURL: URL, to destinationURL: URL) -> String? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let tempURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".\(destinationURL.lastPathComponent).download")
            if fileManager.fileExists(atPath: tempURL.path) {
                try fileManager.removeItem(at: tempURL)
            }
            try fileManager.moveItem(at: sourceURL, to: tempURL)

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: destinationURL)
            }
            return nil
        } catch {
            logger.error("Failed to move downloaded model to \(destinationURL.path): \(error.localizedDescription)")
            return "Failed to store downloaded model: \(error.localizedDescription)"
        }
    }

    func cleanupArtifacts(variant: ModelVariant, source: ParakeetResolvedModelSource, modelURL: URL) {
        try? FileManager.default.removeItem(at: modelURL)

        let sidecarURL = modelURL.appendingPathExtension("data")
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            try? FileManager.default.removeItem(at: sidecarURL)
        }

        if source.tokenizerURL != nil,
           let tokenizerURL = variant.tokenizerLocalURL(using: source) {
            try? FileManager.default.removeItem(at: tokenizerURL)
        }
    }

    func downloadModelDataArtifactIfNeeded(
        variant: ModelVariant,
        source: ParakeetResolvedModelSource
    ) -> String? {
        guard let modelDataURL = source.modelDataURL else {
            return nil
        }

        guard let modelURL = variant.localURL else {
            return "Model data path resolution failed. Check Application Support permissions and retry."
        }

        let destinationURL = modelURL.appendingPathExtension("data")

        if let downloadError = downloadAuxiliaryArtifact(
            from: modelDataURL,
            to: destinationURL,
            label: "model data"
        ) {
            return downloadError
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
              let fileSize = attrs[.size] as? Int64,
              fileSize >= 1_000_000 else {
            return "Model data artifact is missing or incomplete. Retry the download."
        }

        return nil
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

        if let expectedSHA = source.tokenizerSHA256,
           let checksumError = validateSHA256(at: tokenizerDestinationURL, expectedHex: expectedSHA, label: "tokenizer") {
            return checksumError
        }

        return TokenizerArtifactValidator.validate(at: tokenizerDestinationURL, source: source)
    }

    func downloadAuxiliaryArtifact(from sourceURL: URL, to destinationURL: URL, label: String) -> String? {
        var lastError: String?

        for attempt in 0...maxRetryAttempts {
            let semaphore = DispatchSemaphore(value: 0)
            var completionError: String?

            let task = URLSession.shared.downloadTask(with: sourceURL) { tempURL, response, error in
                defer { semaphore.signal() }

                if let error {
                    completionError = "Failed to download \(label) artifact: \(self.downloadFailureMessage(for: error, response: response))"
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

                if let moveError = Self.moveDownloadedFileAtomically(from: tempURL, to: destinationURL) {
                    completionError = "Failed to store \(label) artifact: \(moveError)"
                    return
                }
            }

            task.resume()
            semaphore.wait()

            if completionError == nil {
                return nil
            }
            lastError = completionError
            if attempt < maxRetryAttempts {
                logger.warning("Retrying \(label, privacy: .public) artifact download (attempt \(attempt + 2))")
            }
        }

        return lastError
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

        let minimumModelBytes = max(variant.minimumValidModelBytes(using: source), source.modelExpectedSizeBytes ?? 0)
        guard fileSize >= minimumModelBytes else {
            return "Downloaded model file is too small (\(fileSize / 1_000_000) MB). Minimum expected is \(minimumModelBytes / 1_000_000) MB."
        }

        if let expectedSHA = source.modelSHA256,
           let checksumError = validateSHA256(at: modelURL, expectedHex: expectedSHA, label: "model") {
            return checksumError
        }

        if let expectedLength = source.modelExpectedSizeBytes,
           fileSize < expectedLength {
            return "Downloaded model size check failed (\(fileSize) < expected \(expectedLength) bytes). Retry the download."
        }

        if source.tokenizerURL != nil {
            guard let tokenizerURL = variant.tokenizerLocalURL(using: source) else {
                return "Tokenizer path resolution failed after download. Retry the download."
            }
            if let tokenizerValidationError = TokenizerArtifactValidator.validate(at: tokenizerURL, source: source) {
                return tokenizerValidationError
            }
        }

        guard variant.id == ModelVariant.parakeetCTC06B.id else {
            return nil
        }

        let modelExtension = modelURL.pathExtension.lowercased()
        guard modelExtension == "onnx" else {
            logger.info("Skipping ONNX preflight for non-ONNX model artifact: \(modelURL.lastPathComponent, privacy: .public)")
            return nil
        }

        let tokenizerURL = variant.tokenizerLocalURL(using: source)
        return parakeetONNXPreflightError(modelURL: modelURL, tokenizerURL: tokenizerURL)
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
            let details = !stderr.isEmpty ? stderr : stdout
            if let mappedError = mappedPreflightFailure(
                details: details,
                exitCode: process.terminationStatus
            ) {
                return mappedError
            }

            logger.warning("ONNX preflight returned non-fatal mismatch: \(details, privacy: .public)")
            return nil
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

    func mappedPreflightFailure(details: String, exitCode: Int32) -> String? {
        let lowercased = details.lowercased()
        if lowercased.contains("model_signature_error") || lowercased.contains("unsupported onnx audio input signature") {
            // Signature mismatch should not block model download; this is a runtime
            // capability mismatch and may be handled by alternative inference paths.
            return nil
        }

        if lowercased.contains("model_load_error") {
            // Some Parakeet exports can fail strict preflight load while still being
            // consumable by onnx-asr in runtime. Do not hard-fail download here.
            return nil
        }
        if lowercased.contains("tokenizer_missing") || lowercased.contains("tokenizer_error") {
            return "Tokenizer validation failed during ONNX preflight. Re-download model artifacts from Settings -> Provider."
        }
        if lowercased.contains("dependency_missing") || lowercased.contains("modulenotfounderror") {
            return "Parakeet runtime dependencies are incomplete on this Mac. Try Repair Parakeet Runtime in Settings -> Provider, or switch to Light preset for guaranteed local setup."
        }
        if details.isEmpty {
            return "ONNX preflight failed with exit status \(exitCode) and no diagnostics."
        }
        return "ONNX preflight failed: \(details)"
    }

    func shouldRetry(error: Error, retryCount: Int) -> Bool {
        guard retryCount < maxRetryAttempts else { return false }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }

        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorResourceUnavailable:
            return true
        default:
            return false
        }
    }

    func validateSHA256(at fileURL: URL, expectedHex: String, label: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return "\(label.capitalized) checksum validation failed: file is unreadable."
        }
        let digest = SHA256.hash(data: data)
        let actual = digest.compactMap { String(format: "%02x", $0) }.joined()
        if actual.lowercased() != expectedHex.lowercased() {
            return "\(label.capitalized) checksum mismatch. Retry download from the built-in source."
        }
        return nil
    }

    func downloadFailureMessage(for error: Error, response: URLResponse? = nil) -> String {
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 401, 403:
                return "Download failed: access denied by model host (HTTP \(http.statusCode))."
            case 404:
                return "Download failed: model file was not found on the server (HTTP 404)."
            case 429:
                return "Download failed: host is rate-limiting requests (HTTP 429). Try again shortly."
            case 500...599:
                return "Download failed: model host is temporarily unavailable (HTTP \(http.statusCode))."
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return "Download failed: no internet connection."
            case NSURLErrorTimedOut:
                return "Download timed out. Retry when the network is stable."
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "Download failed: cannot reach the model host."
            case NSURLErrorCancelled:
                return "Download was cancelled."
            default:
                break
            }
        }
        return "Download failed: \(error.localizedDescription)"
    }
}
