import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "MLXSTT")

/// Local speech-to-text via MLX (parakeet-mlx / mlx-whisper) running in the
/// app-managed Python runtime. Buffers PCM during the session, then hands a
/// WAV file to a long-lived runner daemon on session end.
///
/// The daemon (`mlx_stt_infer.py --serve`) loads the model once and stays
/// resident, so per-dictation latency is inference-only instead of paying
/// Python startup + MLX import + model weight loading on every session.
final class MLXSTTProvider: STTProvider {
    let displayName: String
    let transcriptionTimeout: TimeInterval = 120

    var onResult: ((STTResult) -> Void)?
    var onError: ((STTError) -> Void)?

    private let model: MLXModel
    private let stateLock = NSLock()
    private let samplesLock = NSLock()
    private let inferenceQueue = DispatchQueue(label: "com.visperflow.mlx.inference", qos: .userInitiated)
    /// Budget for spawning the daemon and loading model weights (first
    /// session only, or after a crash). Prewarm usually hides this entirely.
    private let daemonStartTimeout: TimeInterval = 75
    /// Budget for a single warm-daemon transcription request.
    private let requestTimeout: TimeInterval = 40

    private var sessionActive = false
    private var inferenceInFlight = false
    private var capturedSamples: [Float] = []
    /// Bumped by `cancelSession()`; results from an older generation are dropped.
    private var generation = 0
    /// The resident runner daemon, so sessions reuse the loaded model.
    private var daemon: MLXInferenceDaemon?

    init(model: MLXModel) {
        self.model = model
        self.displayName = "\(model.displayName) (MLX)"
        logger.info("MLXSTTProvider initialized: \(model.id, privacy: .public)")
        prewarmDaemonIfPossible()
    }

    deinit {
        stateLock.lock()
        let daemon = daemon
        self.daemon = nil
        stateLock.unlock()
        daemon?.terminate()
    }

    func feedAudio(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard currentSessionActive else { return }
        guard let channelData = buffer.floatChannelData else {
            DispatchQueue.main.async { [weak self] in
                self?.onError?(.unsupportedAudioFormat)
            }
            return
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let chunk = UnsafeBufferPointer(start: channelData[0], count: frameCount)
        samplesLock.lock()
        capturedSamples.append(contentsOf: chunk)
        samplesLock.unlock()
    }

    func beginSession() throws {
        if currentSessionActive {
            throw STTError.providerError(message: "MLX session is already active.")
        }
        if currentInferenceInFlight {
            throw STTError.providerError(message: "Previous MLX transcription is still running.")
        }

        guard MLXModelInstaller.shared.isInstalled(model) else {
            throw STTError.providerError(
                message: "\(model.displayName) is not installed. Open Settings -> Provider and click Download."
            )
        }

        // Fast file-existence check only — the full runtime probe launches a
        // Python subprocess and must never block the main thread here. The
        // daemon spawn path (off-main) performs the real verification.
        guard MLXRuntimeBootstrapManager.shared.hasInstalledRuntimeArtifacts() else {
            throw STTError.providerError(
                message: "Local MLX runtime is not installed. Open Settings -> Provider and run runtime setup."
            )
        }

        samplesLock.lock()
        capturedSamples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        updateSessionActive(true)

        // Spin the daemon up in the background while audio is being captured
        // so it is warm by the time the recording ends.
        prewarmDaemonIfPossible()
    }

    func endSession() {
        guard currentSessionActive else { return }

        updateSessionActive(false)
        updateInferenceInFlight(true)
        let gen = currentGeneration

        let samples = snapshotAndClearCapturedSamples()
        guard !samples.isEmpty else {
            updateInferenceInFlight(false)
            onError?(.providerError(message: "No audio captured for MLX transcription."))
            return
        }

        let model = model
        inferenceQueue.async { [weak self] in
            guard let self else { return }

            let result: Result<String, STTError>
            do {
                result = .success(try self.runInference(samples: samples, model: model, generation: gen))
            } catch let err as STTError {
                result = .failure(err)
            } catch {
                result = .failure(.providerError(message: error.localizedDescription))
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Cancelled sessions must stay silent — a newer session may
                // already be recording or transcribing.
                guard gen == self.currentGeneration else {
                    logger.info("Dropping MLX result from cancelled session (gen=\(gen))")
                    return
                }
                self.updateInferenceInFlight(false)
                switch result {
                case .success(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        self.onError?(.providerError(message: "MLX returned an empty transcript."))
                        return
                    }
                    self.onResult?(STTResult(text: trimmed, isPartial: false, confidence: nil))
                case .failure(let error):
                    self.onError?(error)
                }
            }
        }
    }

    func cancelSession() {
        stateLock.lock()
        sessionActive = false
        let hadInferenceInFlight = inferenceInFlight
        inferenceInFlight = false
        generation += 1
        // Only tear the daemon down when a request is actually running on it;
        // an idle warm daemon survives cancellation so the next session stays
        // fast.
        let daemonToKill = hadInferenceInFlight ? daemon : nil
        if hadInferenceInFlight { daemon = nil }
        stateLock.unlock()

        samplesLock.lock()
        capturedSamples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        if let daemonToKill {
            logger.info("Cancelling MLX session — terminating in-flight runner daemon")
            daemonToKill.terminate()
            prewarmDaemonIfPossible()
        } else {
            logger.info("Cancelling MLX session (no inference in flight)")
        }
    }

    // MARK: - Inference

    private func runInference(samples: [Float], model: MLXModel, generation gen: Int) throws -> String {
        guard gen == currentGeneration else {
            throw STTError.providerError(message: "Transcription was cancelled.")
        }

        let daemon = try ensureDaemonReady()

        guard gen == currentGeneration else {
            throw STTError.providerError(message: "Transcription was cancelled.")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-smart-mlx", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let audioURL = tempDir.appendingPathComponent("session-\(UUID().uuidString).wav")

        let wav = AudioWAVEncoding.make16BitMonoWAV(samples: samples, sampleRate: 16_000)
        try wav.write(to: audioURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            return try daemon.transcribe(audioPath: audioURL.path, timeout: requestTimeout)
        } catch {
            // Any request failure (timeout, crash, protocol error) discards
            // the daemon so the next session starts from a clean process.
            discardDaemon(daemon)
            throw error
        }
    }

    /// Returns a ready daemon, spawning one if needed. Runs on `inferenceQueue`.
    private func ensureDaemonReady() throws -> MLXInferenceDaemon {
        if let existing = currentDaemon, existing.isUsable {
            return existing
        }
        if let stale = currentDaemon {
            discardDaemon(stale)
        }

        let scriptURL = try MLXRunnerScript.resolveURL()
        let pythonCommand = try MLXRuntimeBootstrapManager.shared.ensureRuntimeReady()

        logger.info("Spawning MLX runner daemon for \(self.model.id, privacy: .public)")
        let started = Date()
        let daemon = try MLXInferenceDaemon(
            pythonCommand: pythonCommand,
            scriptURL: scriptURL,
            engine: model.engine.rawValue,
            modelRepo: model.repo
        )
        setCurrentDaemon(daemon)

        guard daemon.waitUntilReady(timeout: daemonStartTimeout) else {
            discardDaemon(daemon)
            let tail = daemon.stderrTail
            let detail = tail.isEmpty ? "" : " Details: \(String(tail.suffix(400)))"
            throw STTError.providerError(
                message: "MLX engine failed to start (model load).\(detail)"
            )
        }
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        logger.info("MLX runner daemon ready in \(elapsedMs)ms (model=\(self.model.id, privacy: .public))")
        return daemon
    }

    /// Starts the daemon in the background when the model + runtime are
    /// already installed, so the first transcription doesn't pay model load.
    private func prewarmDaemonIfPossible() {
        guard MLXModelInstaller.shared.isInstalled(model),
              MLXRuntimeBootstrapManager.shared.hasInstalledRuntimeArtifacts() else {
            return
        }
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            do {
                _ = try self.ensureDaemonReady()
            } catch {
                logger.warning("MLX daemon prewarm failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private var currentDaemon: MLXInferenceDaemon? {
        stateLock.lock(); defer { stateLock.unlock() }
        return daemon
    }

    private func setCurrentDaemon(_ newDaemon: MLXInferenceDaemon) {
        stateLock.lock(); daemon = newDaemon; stateLock.unlock()
    }

    private func discardDaemon(_ target: MLXInferenceDaemon) {
        stateLock.lock()
        if daemon === target { daemon = nil }
        stateLock.unlock()
        target.terminate()
    }

    // MARK: - Locked state

    private var currentSessionActive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return sessionActive
    }

    private var currentInferenceInFlight: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return inferenceInFlight
    }

    private var currentGeneration: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return generation
    }

    private func updateSessionActive(_ value: Bool) {
        stateLock.lock(); sessionActive = value; stateLock.unlock()
    }

    private func updateInferenceInFlight(_ value: Bool) {
        stateLock.lock(); inferenceInFlight = value; stateLock.unlock()
    }

    private func snapshotAndClearCapturedSamples() -> [Float] {
        samplesLock.lock(); defer { samplesLock.unlock() }
        let snapshot = capturedSamples
        capturedSamples.removeAll(keepingCapacity: true)
        return snapshot
    }
}

// MARK: - Runner daemon

/// One long-lived `mlx_stt_infer.py --serve` process with the model loaded.
/// Requests are newline-delimited JSON on stdin; responses on stdout.
/// One request is in flight at a time (callers serialize on `inferenceQueue`).
private final class MLXInferenceDaemon {
    private let process = Process()
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle

    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrData = Data()
    private var ready = false
    private var exited = false
    private let readySemaphore = DispatchSemaphore(value: 0)

    private var nextRequestID = 1
    private var pendingRequestID: Int?
    private var pendingResult: Result<String, STTError>?
    private var pendingSemaphore: DispatchSemaphore?

    init(pythonCommand: String, scriptURL: URL, engine: String, modelRepo: String) throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            pythonCommand, scriptURL.path,
            "--serve",
            "--engine", engine,
            "--model", modelRepo,
        ]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.consumeStdout(chunk)
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.lock.lock()
            self.stderrData.append(chunk)
            if self.stderrData.count > 16_384 {
                self.stderrData = Data(self.stderrData.suffix(8_192))
            }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in
            self?.handleTermination()
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw STTError.providerError(message: "Failed to launch MLX runner: \(error.localizedDescription)")
        }
    }

    var isUsable: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready && !exited
    }

    var stderrTail: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Blocks until the daemon reports the model is loaded (or it dies).
    func waitUntilReady(timeout: TimeInterval) -> Bool {
        lock.lock()
        let alreadyReady = ready
        let alreadyExited = exited
        lock.unlock()
        if alreadyReady { return true }
        if alreadyExited { return false }

        guard readySemaphore.wait(timeout: .now() + timeout) == .success else {
            return false
        }
        lock.lock(); defer { lock.unlock() }
        return ready && !exited
    }

    /// Sends one transcription request and blocks for its response.
    func transcribe(audioPath: String, timeout: TimeInterval) throws -> String {
        let requestID: Int
        let semaphore = DispatchSemaphore(value: 0)

        lock.lock()
        guard ready, !exited else {
            lock.unlock()
            throw STTError.providerError(message: "MLX engine is not running.")
        }
        requestID = nextRequestID
        nextRequestID += 1
        pendingRequestID = requestID
        pendingResult = nil
        pendingSemaphore = semaphore
        lock.unlock()

        defer {
            lock.lock()
            pendingRequestID = nil
            pendingSemaphore = nil
            lock.unlock()
        }

        let payload: [String: Any] = ["id": requestID, "audio": audioPath]
        guard var line = try? JSONSerialization.data(withJSONObject: payload) else {
            throw STTError.providerError(message: "Failed to encode MLX request.")
        }
        line.append(0x0A)

        do {
            try stdinHandle.write(contentsOf: line)
        } catch {
            throw STTError.providerError(message: "MLX engine is not accepting requests (pipe closed).")
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw STTError.providerError(
                message: "MLX transcription timed out. Retry, or pick a smaller model in Settings -> Provider."
            )
        }

        lock.lock()
        let result = pendingResult
        lock.unlock()

        switch result {
        case .success(let text):
            return text
        case .failure(let error):
            throw error
        case nil:
            throw STTError.providerError(message: "MLX engine returned no result.")
        }
    }

    func terminate() {
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdinHandle.close()
        if process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Internals

    private func consumeStdout(_ chunk: Data) {
        lock.lock()
        stdoutBuffer.append(chunk)

        var lines: [Data] = []
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            lines.append(stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newlineIndex))
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
        }
        lock.unlock()

        for line in lines where !line.isEmpty {
            handleMessage(line)
        }
    }

    private func handleMessage(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let message = object as? [String: Any] else {
            logger.warning("MLX daemon emitted non-JSON stdout line; ignoring")
            return
        }

        if let event = message["event"] as? String, event == "ready" {
            lock.lock()
            ready = true
            lock.unlock()
            readySemaphore.signal()
            return
        }

        lock.lock()
        guard let requestID = message["id"] as? Int,
              requestID == pendingRequestID,
              let semaphore = pendingSemaphore else {
            lock.unlock()
            return
        }
        if let errorMessage = message["error"] as? String {
            pendingResult = .failure(.providerError(message: String(errorMessage.suffix(400))))
        } else {
            pendingResult = .success(message["text"] as? String ?? "")
        }
        lock.unlock()
        semaphore.signal()
    }

    private func handleTermination() {
        lock.lock()
        exited = true
        let wasReady = ready
        let semaphore = pendingSemaphore
        if semaphore != nil {
            let tail = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = tail.isEmpty ? "" : " Details: \(String(tail.suffix(400)))"
            pendingResult = .failure(.providerError(message: "MLX engine stopped unexpectedly.\(detail)"))
        }
        lock.unlock()

        if !wasReady {
            readySemaphore.signal()
        }
        semaphore?.signal()
    }
}
