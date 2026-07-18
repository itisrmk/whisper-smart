import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "MLXSTT")

/// Local speech-to-text via MLX (parakeet-mlx / mlx-whisper) running in the
/// app-managed Python runtime. Buffers PCM during the session, then hands a
/// WAV file to the runner script on session end.
final class MLXSTTProvider: STTProvider {
    let displayName: String
    let transcriptionTimeout: TimeInterval = 120

    var onResult: ((STTResult) -> Void)?
    var onError: ((STTError) -> Void)?

    private let model: MLXModel
    private let stateLock = NSLock()
    private let samplesLock = NSLock()
    private let inferenceQueue = DispatchQueue(label: "com.visperflow.mlx.inference", qos: .userInitiated)
    private let runnerTimeout: TimeInterval = 90

    private var sessionActive = false
    private var inferenceInFlight = false
    private var capturedSamples: [Float] = []

    init(model: MLXModel) {
        self.model = model
        self.displayName = "\(model.displayName) (MLX)"
        logger.info("MLXSTTProvider initialized: \(model.id, privacy: .public)")
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

        // Verify-only: never install from the dictation path.
        do {
            _ = try MLXRuntimeBootstrapManager.shared.ensureRuntimeReady()
        } catch {
            throw STTError.providerError(message: error.localizedDescription)
        }

        samplesLock.lock()
        capturedSamples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        updateSessionActive(true)
    }

    func endSession() {
        guard currentSessionActive else { return }

        updateSessionActive(false)
        updateInferenceInFlight(true)

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
                result = .success(try self.runInference(samples: samples, model: model))
            } catch let err as STTError {
                result = .failure(err)
            } catch {
                result = .failure(.providerError(message: error.localizedDescription))
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
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

    // MARK: - Inference

    private func runInference(samples: [Float], model: MLXModel) throws -> String {
        let scriptURL = try MLXRunnerScript.resolveURL()
        let pythonCommand = try MLXRuntimeBootstrapManager.shared.ensureRuntimeReady()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-smart-mlx", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let audioURL = tempDir.appendingPathComponent("session-\(UUID().uuidString).wav")

        let wav = AudioWAVEncoding.make16BitMonoWAV(samples: samples, sampleRate: 16_000)
        try wav.write(to: audioURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            pythonCommand, scriptURL.path,
            "--engine", model.engine.rawValue,
            "--model", model.repo,
            "--audio", audioURL.path,
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutData = NSMutableData()
        let stderrData = NSMutableData()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stdoutData.append(chunk) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stderrData.append(chunk) }
        }

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }

        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        do {
            try process.run()
        } catch {
            throw STTError.providerError(message: "Failed to launch MLX runner: \(error.localizedDescription)")
        }

        if completion.wait(timeout: .now() + runnerTimeout) == .timedOut {
            logger.error("MLX runner exceeded \(self.runnerTimeout)s; terminating")
            process.terminate()
            if completion.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 2)
            }
            throw STTError.providerError(message: "MLX transcription timed out. Retry, or pick a smaller model in Settings -> Provider.")
        }

        let stdout = String(data: stdoutData as Data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData as Data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let details = stderr.isEmpty ? stdout : stderr
            throw STTError.providerError(
                message: details.isEmpty
                    ? "MLX runner failed (exit \(process.terminationStatus))."
                    : String(details.suffix(400))
            )
        }

        return stdout
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
