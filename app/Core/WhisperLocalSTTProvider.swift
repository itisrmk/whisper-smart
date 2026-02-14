import AVFoundation
import Foundation

final class WhisperLocalSTTProvider: STTProvider {
    let displayName = "Whisper (local)"

    var onResult: ((STTResult) -> Void)?
    var onError: ((STTError) -> Void)?

    private let stateLock = NSLock()
    private let samplesLock = NSLock()
    private let inferenceQueue = DispatchQueue(label: "com.visperflow.whisper.inference", qos: .userInitiated)

    private var sessionActive = false
    private var inferenceInFlight = false
    private var capturedSamples: [Float] = []

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
            throw STTError.providerError(message: "Whisper session is already active.")
        }
        if currentInferenceInFlight {
            throw STTError.providerError(message: "Previous Whisper inference is still running.")
        }

        if let reason = WhisperLocalRuntime.unavailableReason() {
            throw STTError.providerError(message: reason)
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
            onError?(.providerError(message: "No audio captured for Whisper inference."))
            return
        }

        inferenceQueue.async { [weak self] in
            guard let self else { return }

            let result: Result<String, STTError>
            do {
                result = .success(try Self.runInference(samples: samples))
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
                        self.onError?(.providerError(message: "Whisper returned an empty transcript."))
                        return
                    }
                    self.onResult?(STTResult(text: trimmed, isPartial: false, confidence: nil))
                case .failure(let error):
                    self.onError?(error)
                }
            }
        }
    }

    private static func runInference(samples: [Float]) throws -> String {
        let cliURL = URL(fileURLWithPath: DictationProviderPolicy.whisperCLIPath)
        let modelURL = URL(fileURLWithPath: DictationProviderPolicy.whisperModelPath)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("visperflow-whisper", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let audioURL = tempDir.appendingPathComponent("session-\(token).wav")
        let outputBase = tempDir.appendingPathComponent("result-\(token)")
        let outputTXT = outputBase.appendingPathExtension("txt")

        let wav = AudioWAVEncoding.make16BitMonoWAV(samples: samples, sampleRate: 16_000)
        try wav.write(to: audioURL, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: outputTXT)
        }

        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["-m", modelURL.path, "-f", audioURL.path, "-otxt", "-of", outputBase.path, "-nt"]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw STTError.providerError(message: "Failed to launch whisper-cli: \(error.localizedDescription)")
        }

        process.waitUntilExit()

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw STTError.providerError(message: detail.isEmpty ? "whisper-cli failed with status \(process.terminationStatus)." : detail)
        }

        guard FileManager.default.fileExists(atPath: outputTXT.path) else {
            throw STTError.providerError(message: "whisper-cli completed but did not emit transcript output.")
        }

        return try String(contentsOf: outputTXT, encoding: .utf8)
    }

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

enum WhisperLocalRuntime {
    static func isUsable() -> Bool {
        unavailableReason() == nil
    }

    static func detectCLIPath() -> String? {
        let configured = DictationProviderPolicy.whisperCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }

        var candidates: [String] = []
        for runtimeRoot in AppStoragePaths.whisperRuntimeRootCandidates() {
            candidates.append(runtimeRoot.appendingPathComponent("bin/whisper-cli").path)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ])

        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }

        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "whisper-cli"]
        let out = Pipe()
        which.standardOutput = out
        do {
            try which.run()
            which.waitUntilExit()
            if which.terminationStatus == 0,
               let line = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty,
               FileManager.default.isExecutableFile(atPath: line) {
                return line
            }
        } catch {
            return nil
        }

        return nil
    }

    static func unavailableReason() -> String? {
        guard let cliPath = detectCLIPath() else {
            return "Whisper runtime is not installed yet. Use Provider settings to install the managed local runtime."
        }
        DictationProviderPolicy.whisperCLIPath = cliPath

        let modelPath = DictationProviderPolicy.whisperModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if modelPath.isEmpty {
            return "Whisper model path is not configured. Download a model in Provider settings."
        }
        if !FileManager.default.fileExists(atPath: modelPath) {
            return "Whisper model file not found at '\(modelPath)'."
        }

        return nil
    }
}
