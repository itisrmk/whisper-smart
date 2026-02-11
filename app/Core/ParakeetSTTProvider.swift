import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "ParakeetSTT")

/// STT provider for NVIDIA Parakeet local ONNX inference.
final class ParakeetSTTProvider: STTProvider {
    let displayName = "NVIDIA Parakeet (local)"
    static let inferenceImplemented = true

    var onResult: ((STTResult) -> Void)?
    var onError: ((STTError) -> Void)?

    private let variant: ModelVariant
    private let stateLock = NSLock()
    private let samplesLock = NSLock()
    private let inferenceQueue = DispatchQueue(label: "com.visperflow.parakeet.inference", qos: .userInitiated)
    private let expectedSampleRate = 16_000
    private let runtimeBootstrapManager = ParakeetRuntimeBootstrapManager.shared

    private var sessionActive = false
    private var inferenceInFlight = false
    private var runtimeValidated = false
    private var capturedSamples: [Float] = []

    init(variant: ModelVariant = .parakeetCTC06B) {
        self.variant = variant
        logger.info("ParakeetSTTProvider initialized with variant: \(variant.id)")
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
            throw STTError.providerError(message: "Parakeet session is already active.")
        }
        if currentInferenceInFlight {
            throw STTError.providerError(
                message: "Previous Parakeet inference is still running. Wait for transcription to complete."
            )
        }

        guard let modelURL = variant.localURL else {
            throw STTError.providerError(message: "Cannot resolve Parakeet model path from Application Support.")
        }
        guard variant.isDownloaded else {
            let status = variant.validationStatus
            logger.error("Parakeet model not ready: \(status), path: \(modelURL.path)")
            throw STTError.providerError(
                message: "Parakeet model not ready (\(status)). Download a complete model in Settings → Provider."
            )
        }

        let scriptURL = try resolveRunnerScriptURL()
        let pythonCommand: String
        do {
            pythonCommand = try runtimePythonCommand()
        } catch {
            throw STTError.providerError(message: error.localizedDescription)
        }

        if !currentRuntimeValidated {
            do {
                _ = try runRunner(
                    pythonCommand: pythonCommand,
                    scriptURL: scriptURL,
                    arguments: checkArguments(modelURL: modelURL)
                )
                updateRuntimeValidated(true)
                logger.info("Parakeet runtime validation passed")
            } catch let error as STTError {
                throw error
            } catch {
                throw STTError.providerError(
                    message: "Parakeet runtime validation failed: \(error.localizedDescription)"
                )
            }
        }

        samplesLock.lock()
        capturedSamples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        updateSessionActive(true)
        logger.info("Parakeet session started")
    }

    func endSession() {
        guard currentSessionActive else {
            logger.warning("endSession called but no session was active — ignoring")
            return
        }

        updateSessionActive(false)
        updateInferenceInFlight(true)

        let samples = snapshotAndClearCapturedSamples()
        guard !samples.isEmpty else {
            logger.error("No audio captured during Parakeet session")
            updateInferenceInFlight(false)
            onError?(.providerError(
                message: "No audio captured for Parakeet inference. Check microphone input and try again."
            ))
            return
        }

        guard let modelURL = variant.localURL else {
            updateInferenceInFlight(false)
            onError?(.providerError(message: "Cannot resolve Parakeet model path from Application Support."))
            return
        }

        let scriptURL: URL
        do {
            scriptURL = try resolveRunnerScriptURL()
        } catch let error as STTError {
            updateInferenceInFlight(false)
            onError?(error)
            return
        } catch {
            updateInferenceInFlight(false)
            onError?(.providerError(message: error.localizedDescription))
            return
        }

        let pythonCommand: String
        do {
            pythonCommand = try runtimePythonCommand()
        } catch {
            updateInferenceInFlight(false)
            onError?(.providerError(message: error.localizedDescription))
            return
        }
        logger.info("Parakeet session ended, launching local inference (samples=\(samples.count))")

        inferenceQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<String, STTError>
            do {
                let text = try self.runInference(
                    samples: samples,
                    modelURL: modelURL,
                    scriptURL: scriptURL,
                    pythonCommand: pythonCommand
                )
                result = .success(text)
            } catch let error as STTError {
                result = .failure(error)
            } catch {
                result = .failure(.providerError(message: "Parakeet inference failed: \(error.localizedDescription)"))
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateInferenceInFlight(false)
                switch result {
                case .success(let transcript):
                    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        self.onError?(.providerError(
                            message: "Parakeet inference returned an empty transcript. Speak clearly and verify model/tokenizer files."
                        ))
                        return
                    }
                    self.onResult?(STTResult(
                        text: trimmed,
                        isPartial: false,
                        confidence: nil
                    ))
                case .failure(let error):
                    self.onError?(error)
                }
            }
        }
    }
}

// MARK: - Inference

private extension ParakeetSTTProvider {
    func runInference(
        samples: [Float],
        modelURL: URL,
        scriptURL: URL,
        pythonCommand: String
    ) throws -> String {
        let tempAudioURL = try writeTemporaryWAV(samples: samples)
        defer {
            try? FileManager.default.removeItem(at: tempAudioURL)
        }

        return try runRunner(
            pythonCommand: pythonCommand,
            scriptURL: scriptURL,
            arguments: inferenceArguments(modelURL: modelURL, audioURL: tempAudioURL)
        )
    }

    func writeTemporaryWAV(samples: [Float]) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("visperflow-parakeet", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let audioURL = tempDir.appendingPathComponent("session-\(UUID().uuidString).wav")
        let wavData = Self.makeWAV(samples: samples, sampleRate: expectedSampleRate)
        try wavData.write(to: audioURL, options: .atomic)
        return audioURL
    }

    func runRunner(
        pythonCommand: String,
        scriptURL: URL,
        arguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [pythonCommand, scriptURL.path] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw STTError.providerError(
                message: "Failed to launch Python runtime '\(pythonCommand)'. Use Repair Parakeet Runtime in Settings -> Provider. Underlying error: \(error.localizedDescription)"
            )
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let details = !stderr.isEmpty ? stderr : stdout
            throw STTError.providerError(
                message: mappedRunnerFailure(
                    pythonCommand: pythonCommand,
                    exitCode: process.terminationStatus,
                    details: details
                )
            )
        }

        return stdout
    }
}

// MARK: - Argument Builders

private extension ParakeetSTTProvider {
    func runtimePythonCommand() throws -> String {
        try runtimeBootstrapManager.ensureRuntimeReady()
    }

    func resolvedTokenizerPath() -> String? {
        guard let source = variant.configuredSource else {
            return variant.tokenizerLocalURL?.path
        }

        if source.tokenizerURL != nil {
            return variant.tokenizerLocalURL(using: source)?.path
        }

        return variant.tokenizerLocalURL(using: source)?.path
    }

    func checkArguments(modelURL: URL) -> [String] {
        var args = ["--check", "--model", modelURL.path]
        if let tokenizer = resolvedTokenizerPath() {
            args += ["--tokenizer", tokenizer]
        }
        return args
    }

    func inferenceArguments(modelURL: URL, audioURL: URL) -> [String] {
        var args = ["--model", modelURL.path, "--audio", audioURL.path]
        if let tokenizer = resolvedTokenizerPath() {
            args += ["--tokenizer", tokenizer]
        }
        return args
    }

    func resolveRunnerScriptURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let override = env["VISPERFLOW_PARAKEET_SCRIPT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }

        let workingDir = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        candidates.append(workingDir.appendingPathComponent("scripts/parakeet_infer.py"))

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
        throw STTError.providerError(
            message: "Parakeet inference runner script not found. Checked: \(checkedPaths). Reinstall or repair the app bundle resources."
        )
    }
}

// MARK: - State Helpers

private extension ParakeetSTTProvider {
    var currentSessionActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sessionActive
    }

    var currentInferenceInFlight: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return inferenceInFlight
    }

    var currentRuntimeValidated: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runtimeValidated
    }

    func updateSessionActive(_ value: Bool) {
        stateLock.lock()
        sessionActive = value
        stateLock.unlock()
    }

    func updateInferenceInFlight(_ value: Bool) {
        stateLock.lock()
        inferenceInFlight = value
        stateLock.unlock()
    }

    func updateRuntimeValidated(_ value: Bool) {
        stateLock.lock()
        runtimeValidated = value
        stateLock.unlock()
    }

    func snapshotAndClearCapturedSamples() -> [Float] {
        samplesLock.lock()
        defer { samplesLock.unlock() }
        let snapshot = capturedSamples
        capturedSamples.removeAll(keepingCapacity: true)
        return snapshot
    }
}

// MARK: - Error Mapping

private extension ParakeetSTTProvider {
    func mappedRunnerFailure(pythonCommand: String, exitCode: Int32, details: String) -> String {
        let lowercased = details.lowercased()
        if (lowercased.contains("no such file") || lowercased.contains("not found")) && lowercased.contains(pythonCommand.lowercased()) {
            return "Python runtime '\(pythonCommand)' is unavailable. Run Repair Parakeet Runtime in Settings → Provider."
        }
        if lowercased.contains("model_load_error") {
            return "MODEL_LOAD_ERROR: Parakeet ONNX preflight failed. The model file is corrupt or incompatible. Re-download the model in Settings → Provider."
        }
        if lowercased.contains("tokenizer_missing") || lowercased.contains("tokenizer_error") {
            return "Tokenizer validation failed. Re-download model artifacts in Settings -> Provider and verify the selected source."
        }
        if lowercased.contains("modulenotfounderror") || lowercased.contains("dependency_missing") {
            return details
        }
        if details.isEmpty {
            return "Parakeet inference runner exited with status \(exitCode) and no error output."
        }
        return details
    }
}

// MARK: - WAV Encoding

private extension ParakeetSTTProvider {
    static func makeWAV(samples: [Float], sampleRate: Int) -> Data {
        var pcmData = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        pcmData.reserveCapacity(samples.count * MemoryLayout<Int16>.size)

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let scaled = Int16(clamped * Float(Int16.max))
            pcmData.appendLittleEndian(scaled)
        }

        let subchunk2Size = UInt32(pcmData.count)
        let chunkSize = UInt32(36) + subchunk2Size
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16

        var wav = Data()
        wav.appendASCII("RIFF")
        wav.appendLittleEndian(chunkSize)
        wav.appendASCII("WAVE")
        wav.appendASCII("fmt ")
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt32(sampleRate))
        wav.appendLittleEndian(byteRate)
        wav.appendLittleEndian(blockAlign)
        wav.appendLittleEndian(bitsPerSample)
        wav.appendASCII("data")
        wav.appendLittleEndian(subchunk2Size)
        wav.append(pcmData)
        return wav
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(string.data(using: .ascii) ?? Data())
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
