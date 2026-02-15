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
        var downloadedModelURL: URL?
        var attemptedSourceIDs: Set<String>
        var transferProgress: Double = 0

        init(
            variant: ModelVariant,
            source: ParakeetResolvedModelSource,
            state: ModelDownloadState?,
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
    private let maxTransferProgressBeforeFinalize = 0.99
    private let auxiliaryArtifactTimeoutSeconds: TimeInterval = 12 * 60 * 60
    private let auxiliaryRequestTimeoutSeconds: TimeInterval = 60
    private let preflightTimeoutSeconds: TimeInterval = 45
    private let backgroundSessionIdentifier = "com.visperflow.modeldownloader.background.v1"
    private var activeDownloadsByVariantID: [String: DownloadContext] = [:]
    private var variantIDByTaskID: [Int: String] = [:]
    private var resumeDataByDownloadKey: [String: Data] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: backgroundSessionIdentifier)
        configuration.waitsForConnectivity = true
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        session.getAllTasks { tasks in
            if !tasks.isEmpty {
                logger.info("Reattached to \(tasks.count) background model download task(s)")
            }
        }
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
            if let active = self.activeDownloadsByVariantID[variant.id] {
                active.state = state
                let progress = active.transferProgress
                logger.info("Download already active for \(variant.id); rebinding observer state")
                DispatchQueue.main.async {
                    state.transitionToDownloading()
                    state.updateProgress(progress)
                }
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
            task.taskDescription = Self.taskDescription(variantID: variant.id, sourceID: source.selectedSourceID)

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
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        logger.info("Background model downloader session finished pending events")
    }

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
            guard let context = ensureContext(forTask: downloadTask),
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
            let rawProgress = min(max(Double(totalBytesWritten) / Double(expectedBytes), 0), 1)
            let clampedProgress = min(rawProgress, self.maxTransferProgressBeforeFinalize)
            context.transferProgress = clampedProgress
            progress = clampedProgress
        }

        guard let state = stateToUpdate, let progress else { return }
        DispatchQueue.main.async {
            state.updateProgress(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        stateQueue.sync {
            guard let context = ensureContext(forTask: downloadTask) else { return }

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
            context.downloadedModelURL = destinationURL
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var completionAction: (() -> Void)?
        var finalizeContext: DownloadContext?
        var finalizeModelURL: URL?

        stateQueue.sync {
            guard let context = ensureContext(forTask: task) else { return }

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
                nextTask.taskDescription = Self.taskDescription(
                    variantID: context.variant.id,
                    sourceID: context.source.selectedSourceID
                )
                context.task = nextTask
                nextTask.resume()

                Task {
                    await ParakeetTelemetryStore.shared.recordModelDownloadTransportRetry(
                        attempt: context.retryCount
                    )
                }
                logger.info("Retrying model download for \(context.variant.id) attempt=\(context.retryCount + 1)")
                return
            }

            if let error {
                if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                   !resumeData.isEmpty {
                    resumeDataByDownloadKey[context.resumeDataKey] = resumeData
                }

                let message = downloadFailureMessage(for: error, response: task.response)
                let variantID = context.variant.id
                let state = context.state
                _ = removeContext(forTaskID: task.taskIdentifier)
                completionAction = {
                    state?.transitionToFailed(message: message)
                    self.postModelDownloadEvent(variantID: variantID, isReady: false, message: message)
                }
                return
            }

            if let completionError = context.completionError {
                if self.tryAutoSwitchSourceAfter404(context: context, previousTaskID: task.taskIdentifier) {
                    return
                }

                let variantID = context.variant.id
                let state = context.state
                _ = removeContext(forTaskID: task.taskIdentifier)
                completionAction = {
                    state?.transitionToFailed(message: completionError)
                    self.postModelDownloadEvent(variantID: variantID, isReady: false, message: completionError)
                }
                return
            }

            guard let modelURL = context.downloadedModelURL else {
                let variantID = context.variant.id
                let state = context.state
                _ = removeContext(forTaskID: task.taskIdentifier)
                completionAction = {
                    let message = "Model download finished but no local file was produced."
                    state?.transitionToFailed(message: message)
                    self.postModelDownloadEvent(variantID: variantID, isReady: false, message: message)
                }
                return
            }

            _ = removeContext(forTaskID: task.taskIdentifier)
            finalizeContext = context
            finalizeModelURL = modelURL
        }

        if let finalizeContext, let finalizeModelURL {
            let variantID = finalizeContext.variant.id
            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                let error = await self.finalizeDownloadedArtifacts(context: finalizeContext, modelURL: finalizeModelURL)
                await MainActor.run {
                    if let error {
                        finalizeContext.state?.transitionToFailed(message: error)
                        self.postModelDownloadEvent(variantID: variantID, isReady: false, message: error)
                    } else {
                        finalizeContext.state?.transitionToReady()
                        self.postModelDownloadEvent(variantID: variantID, isReady: true, message: nil)
                    }
                }
            }
        }

        if let completionAction {
            DispatchQueue.main.async(execute: completionAction)
        }
    }
}

// MARK: - Validation and plumbing

private extension ModelDownloaderService {
    static func resumeDataKey(variantID: String, source: ParakeetResolvedModelSource) -> String {
        let modelURL = source.modelURL?.absoluteString ?? "none"
        return "\(variantID)|\(source.selectedSourceID)|\(modelURL)"
    }

    static func taskDescription(variantID: String, sourceID: String) -> String {
        "\(variantID)||\(sourceID)"
    }

    static func parseTaskDescription(_ description: String?) -> (variantID: String, sourceID: String)? {
        guard let description, !description.isEmpty else { return nil }
        let components = description.components(separatedBy: "||")
        guard components.count == 2 else { return nil }
        let variantID = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceID = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !variantID.isEmpty, !sourceID.isEmpty else { return nil }
        return (variantID, sourceID)
    }

    private func ensureContext(forTask task: URLSessionTask) -> DownloadContext? {
        if let existing = context(forTaskID: task.taskIdentifier) {
            return existing
        }

        guard let descriptor = Self.parseTaskDescription(task.taskDescription),
              descriptor.variantID == ModelVariant.parakeetCTC06B.id,
              let source = resolvedSource(for: descriptor.variantID, sourceID: descriptor.sourceID),
              let downloadTask = task as? URLSessionDownloadTask else {
            return nil
        }

        let context = DownloadContext(
            variant: .parakeetCTC06B,
            source: source,
            state: nil,
            task: downloadTask,
            resumeDataKey: Self.resumeDataKey(variantID: descriptor.variantID, source: source)
        )
        context.attemptedSourceIDs = [source.selectedSourceID]
        activeDownloadsByVariantID[descriptor.variantID] = context
        variantIDByTaskID[task.taskIdentifier] = descriptor.variantID

        logger.info(
            "Reconstructed background download context for variant \(descriptor.variantID, privacy: .public) source \(source.selectedSourceID, privacy: .public)"
        )
        return context
    }

    private func resolvedSource(for variantID: String, sourceID: String) -> ParakeetResolvedModelSource? {
        let store = ParakeetModelSourceConfigurationStore.shared
        if store.availableSources(for: variantID).contains(where: { $0.id == sourceID }) {
            _ = store.selectSource(id: sourceID, for: variantID)
        }

        let resolved = store.resolvedSource(for: variantID)
        guard resolved.error == nil, resolved.modelURL != nil else { return nil }
        return resolved
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
        let originalSourceID = context.source.selectedSourceID
        var resolvedFallback: ParakeetResolvedModelSource?
        var fallbackURL: URL?

        for candidate in alternatives {
            guard let candidateURL = candidate.modelURL,
                  candidateURL.pathExtension.lowercased() == "onnx",
                  candidate.runtimeCompatibility.unsupportedReason == nil else {
                continue
            }

            _ = sourceStore.selectSource(id: candidate.id, for: context.variant.id)
            let resolvedCandidate = sourceStore.resolvedSource(for: context.variant.id)
            guard resolvedCandidate.error == nil,
                  let resolvedModelURL = resolvedCandidate.modelURL else {
                continue
            }

            resolvedFallback = resolvedCandidate
            fallbackURL = resolvedModelURL
            break
        }

        guard let resolved = resolvedFallback, let fallbackURL else {
            if sourceStore.selectedSourceID(for: context.variant.id) != originalSourceID {
                _ = sourceStore.selectSource(id: originalSourceID, for: context.variant.id)
            }
            return false
        }

        let nextTask = session.downloadTask(with: fallbackURL)
        nextTask.taskDescription = Self.taskDescription(
            variantID: context.variant.id,
            sourceID: resolved.selectedSourceID
        )

        variantIDByTaskID.removeValue(forKey: previousTaskID)
        variantIDByTaskID[nextTask.taskIdentifier] = context.variant.id

        context.source = resolved
        context.resumeDataKey = Self.resumeDataKey(variantID: context.variant.id, source: resolved)
        context.task = nextTask
        context.retryCount = 0
        context.completionError = nil
        context.expectedContentLength = nil
        context.attemptedSourceIDs.insert(resolved.selectedSourceID)

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

    private func finalizeDownloadedArtifacts(context: DownloadContext, modelURL: URL) async -> String? {
        if let modelDataError = await downloadModelDataArtifactIfNeeded(
            variant: context.variant,
            source: context.source
        ) {
            cleanupArtifacts(variant: context.variant, source: context.source, modelURL: modelURL)
            return modelDataError
        }

        if let tokenizerError = await downloadTokenizerArtifactIfNeeded(
            variant: context.variant,
            source: context.source
        ) {
            cleanupArtifacts(variant: context.variant, source: context.source, modelURL: modelURL)
            return tokenizerError
        }

        if let validationError = validateDownloadedModel(
            variant: context.variant,
            at: modelURL,
            source: context.source
        ) {
            cleanupArtifacts(variant: context.variant, source: context.source, modelURL: modelURL)
            return validationError
        }

        return nil
    }

    func downloadModelDataArtifactIfNeeded(
        variant: ModelVariant,
        source: ParakeetResolvedModelSource
    ) async -> String? {
        guard let modelDataURL = source.modelDataURL else {
            return nil
        }

        guard let modelURL = variant.localURL else {
            return "Model data path resolution failed. Check Application Support permissions and retry."
        }

        let destinationURL = modelURL.appendingPathExtension("data")

        if modelDataArtifactValidationError(at: destinationURL, expectedSizeBytes: source.modelDataExpectedSizeBytes) == nil {
            return nil
        }

        if let downloadError = await downloadAuxiliaryArtifact(
            from: modelDataURL,
            to: destinationURL,
            label: "model data"
        ) {
            return downloadError
        }

        return modelDataArtifactValidationError(
            at: destinationURL,
            expectedSizeBytes: source.modelDataExpectedSizeBytes
        )
    }

    func downloadTokenizerArtifactIfNeeded(
        variant: ModelVariant,
        source: ParakeetResolvedModelSource
    ) async -> String? {
        guard let tokenizerRemoteURL = source.tokenizerURL else {
            return nil
        }

        guard let tokenizerDestinationURL = variant.tokenizerLocalURL(using: source) else {
            return "Tokenizer path resolution failed. Check Application Support permissions and retry."
        }

        if let downloadError = await downloadAuxiliaryArtifact(
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

    func downloadAuxiliaryArtifact(from sourceURL: URL, to destinationURL: URL, label: String) async -> String? {
        var lastError: String?

        for attempt in 0...maxRetryAttempts {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = auxiliaryRequestTimeoutSeconds
            configuration.timeoutIntervalForResource = auxiliaryArtifactTimeoutSeconds
            let session = URLSession(configuration: configuration)
            defer {
                session.invalidateAndCancel()
            }

            var completionError: String?
            do {
                let (tempURL, response) = try await session.download(from: sourceURL)

                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode) == false {
                    completionError = "Failed to download \(label) artifact: server returned HTTP \(httpResponse.statusCode)."
                } else if let moveError = Self.moveDownloadedFileAtomically(from: tempURL, to: destinationURL) {
                    completionError = "Failed to store \(label) artifact: \(moveError)"
                }
            } catch {
                completionError = "Failed to download \(label) artifact: \(downloadFailureMessage(for: error))"
            }

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

    func modelDataArtifactValidationError(at fileURL: URL, expectedSizeBytes: Int64?) -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return "Model data artifact is missing after download. Automatic setup will retry."
        }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            return "Model data artifact cannot be read. Automatic setup will retry."
        }

        let minimumBytes: Int64
        if let expectedSizeBytes, expectedSizeBytes > 0 {
            minimumBytes = max(200_000_000, Int64(Double(expectedSizeBytes) * 0.95))
        } else {
            minimumBytes = 200_000_000
        }

        guard fileSize >= minimumBytes else {
            if let expectedSizeBytes, expectedSizeBytes > 0 {
                return "Model data artifact is incomplete (\(fileSize / 1_000_000) MB; expected about \(expectedSizeBytes / 1_000_000) MB). Automatic setup will retry."
            }
            return "Model data artifact is incomplete (\(fileSize / 1_000_000) MB). Automatic setup will retry."
        }

        return nil
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
            return "Downloaded model size check failed (\(fileSize) < expected \(expectedLength) bytes). Automatic setup will retry."
        }

        if source.tokenizerURL != nil {
            guard let tokenizerURL = variant.tokenizerLocalURL(using: source) else {
                return "Tokenizer path resolution failed after download. Automatic setup will retry."
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

        // Keep model finalize non-blocking. Runtime bootstrap can still be in-flight
        // during first install; preflight runs later during provider warmup.
        if runtimeBootstrapManager.statusSnapshot().phase != .ready {
            logger.info("Skipping ONNX preflight during finalize because runtime is not ready yet")
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
            return "Downloaded file saved, but ONNX preflight is pending while runtime provisioning completes: \(error.localizedDescription)"
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

        let timeoutResult = DispatchGroup()
        timeoutResult.enter()
        process.terminationHandler = { _ in
            timeoutResult.leave()
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            timeoutResult.leave()
            return "ONNX preflight launch failed: \(error.localizedDescription)"
        }

        if timeoutResult.wait(timeout: .now() + preflightTimeoutSeconds) == .timedOut {
            process.terminate()
            return "ONNX preflight timed out while validating the downloaded model. Retry download or switch to the recommended Parakeet ONNX source."
        }

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
            return "Tokenizer validation failed during ONNX preflight. Automatic setup will retry."
        }
        if lowercased.contains("dependency_missing") || lowercased.contains("modulenotfounderror") {
            return "Parakeet runtime dependencies are still installing. Runtime setup is automatic; retry shortly."
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
        guard let stream = InputStream(url: fileURL) else {
            return "\(label.capitalized) checksum validation failed: file is unreadable."
        }

        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let chunkSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: chunkSize)
            if bytesRead < 0 {
                return "\(label.capitalized) checksum validation failed: \(stream.streamError?.localizedDescription ?? "stream read failed")."
            }
            if bytesRead == 0 {
                break
            }

            let chunk = Data(bytes: buffer, count: bytesRead)
            hasher.update(data: chunk)
        }

        if let streamError = stream.streamError {
            return "\(label.capitalized) checksum validation failed: \(streamError.localizedDescription)."
        }

        let digest = hasher.finalize()
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

    func postModelDownloadEvent(variantID: String, isReady: Bool, message: String?) {
        if !isReady {
            Task {
                await ParakeetTelemetryStore.shared.recordModelDownloadFailure(message ?? "unknown")
            }
        }

        var userInfo: [String: Any] = [
            "variantID": variantID,
            "isReady": isReady
        ]
        if let message {
            userInfo["message"] = message
        }
        NotificationCenter.default.post(
            name: .modelDownloadDidChange,
            object: nil,
            userInfo: userInfo
        )
    }
}

extension Notification.Name {
    static let modelDownloadDidChange = Notification.Name("modelDownloadDidChange")
}
