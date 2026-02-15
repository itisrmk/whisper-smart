import Foundation
import os.log
import Darwin

private let persistentRunnerLogger = Logger(subsystem: "com.visperflow", category: "ParakeetPersistentRunner")

final class ParakeetPersistentRunner {
    static let shared = ParakeetPersistentRunner()

    private final class WorkerState {
        let process: Process
        let stdinHandle: FileHandle
        let stdoutFD: Int32
        let pythonCommand: String
        let scriptPath: String
        let modelPath: String
        let tokenizerPath: String?

        init(
            process: Process,
            stdinHandle: FileHandle,
            stdoutFD: Int32,
            pythonCommand: String,
            scriptPath: String,
            modelPath: String,
            tokenizerPath: String?
        ) {
            self.process = process
            self.stdinHandle = stdinHandle
            self.stdoutFD = stdoutFD
            self.pythonCommand = pythonCommand
            self.scriptPath = scriptPath
            self.modelPath = modelPath
            self.tokenizerPath = tokenizerPath
        }
    }

    private let stateLock = NSLock()
    private var worker: WorkerState?
    private var stdoutBuffer = Data()

    private init() {}

    func warmup(pythonCommand: String, scriptURL: URL, modelURL: URL, tokenizerPath: String?) throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        _ = try ensureWorkerLocked(
            pythonCommand: pythonCommand,
            scriptURL: scriptURL,
            modelURL: modelURL,
            tokenizerPath: tokenizerPath
        )

        let requestID = UUID().uuidString
        _ = try sendRequestLocked(
            ["id": requestID, "op": "ping"],
            expectedID: requestID,
            timeout: 20
        )
    }

    func transcribe(
        pythonCommand: String,
        scriptURL: URL,
        modelURL: URL,
        tokenizerPath: String?,
        audioURL: URL,
        timeout: TimeInterval
    ) throws -> String {
        stateLock.lock()
        defer { stateLock.unlock() }

        do {
            return try transcribeLocked(
                pythonCommand: pythonCommand,
                scriptURL: scriptURL,
                modelURL: modelURL,
                tokenizerPath: tokenizerPath,
                audioURL: audioURL,
                timeout: timeout
            )
        } catch {
            // One retry with a brand-new worker if the previous worker died.
            stopWorkerLocked()
            return try transcribeLocked(
                pythonCommand: pythonCommand,
                scriptURL: scriptURL,
                modelURL: modelURL,
                tokenizerPath: tokenizerPath,
                audioURL: audioURL,
                timeout: timeout
            )
        }
    }

    func invalidate() {
        stateLock.lock()
        defer { stateLock.unlock() }
        stopWorkerLocked()
    }
}

private extension ParakeetPersistentRunner {
    func transcribeLocked(
        pythonCommand: String,
        scriptURL: URL,
        modelURL: URL,
        tokenizerPath: String?,
        audioURL: URL,
        timeout: TimeInterval
    ) throws -> String {
        _ = try ensureWorkerLocked(
            pythonCommand: pythonCommand,
            scriptURL: scriptURL,
            modelURL: modelURL,
            tokenizerPath: tokenizerPath
        )

        let requestID = UUID().uuidString
        let response = try sendRequestLocked(
            [
                "id": requestID,
                "op": "transcribe",
                "audio": audioURL.path
            ],
            expectedID: requestID,
            timeout: timeout
        )

        guard let ok = response["ok"] as? Bool else {
            throw STTError.providerError(message: "Parakeet worker returned malformed response.")
        }

        if ok {
            guard let text = response["text"] as? String else {
                throw STTError.providerError(message: "Parakeet worker returned empty transcript payload.")
            }
            return text
        }

        let message = (response["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw STTError.providerError(message: message?.isEmpty == false ? message! : "Parakeet worker failed.")
    }

    private func ensureWorkerLocked(
        pythonCommand: String,
        scriptURL: URL,
        modelURL: URL,
        tokenizerPath: String?
    ) throws -> WorkerState {
        if let existing = worker,
           existing.process.isRunning,
           existing.pythonCommand == pythonCommand,
           existing.scriptPath == scriptURL.path,
           existing.modelPath == modelURL.path,
           existing.tokenizerPath == tokenizerPath {
            return existing
        }

        stopWorkerLocked()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var arguments = [pythonCommand, scriptURL.path, "--serve", "--model", modelURL.path]
        if let tokenizerPath {
            arguments += ["--tokenizer", tokenizerPath]
        }
        process.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw STTError.providerError(
                message: "Failed to launch persistent Parakeet worker '\(pythonCommand)': \(error.localizedDescription)"
            )
        }

        let stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let currentFlags = fcntl(stdoutFD, F_GETFL, 0)
        if currentFlags >= 0 {
            _ = fcntl(stdoutFD, F_SETFL, currentFlags | O_NONBLOCK)
        }

        stdoutBuffer = Data()
        let newWorker = WorkerState(
            process: process,
            stdinHandle: stdinPipe.fileHandleForWriting,
            stdoutFD: stdoutFD,
            pythonCommand: pythonCommand,
            scriptPath: scriptURL.path,
            modelPath: modelURL.path,
            tokenizerPath: tokenizerPath
        )
        worker = newWorker

        persistentRunnerLogger.info(
            "Started persistent Parakeet worker model=\(modelURL.lastPathComponent, privacy: .public)"
        )
        return newWorker
    }

    func stopWorkerLocked() {
        guard let worker else { return }

        do {
            let requestID = UUID().uuidString
            _ = try sendRequestLocked(
                ["id": requestID, "op": "shutdown"],
                expectedID: requestID,
                timeout: 1
            )
        } catch {
            // Ignore shutdown errors and force terminate below.
        }

        if worker.process.isRunning {
            worker.process.terminate()
            worker.process.waitUntilExit()
        }

        worker.stdinHandle.closeFile()
        self.worker = nil
        stdoutBuffer = Data()
    }

    func sendRequestLocked(
        _ payload: [String: Any],
        expectedID: String,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        guard let worker else {
            throw STTError.providerError(message: "Parakeet worker is not running.")
        }

        let serializedData: Data
        do {
            serializedData = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            throw STTError.providerError(message: "Failed to encode Parakeet worker request.")
        }

        var line = serializedData
        line.append(0x0A)

        do {
            try worker.stdinHandle.write(contentsOf: line)
        } catch {
            throw STTError.providerError(
                message: "Failed to send request to persistent Parakeet worker: \(error.localizedDescription)"
            )
        }

        let responseLine = try readResponseLineLocked(worker: worker, timeout: timeout)
        guard let responseData = responseLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: responseData),
              let response = object as? [String: Any] else {
            throw STTError.providerError(message: "Parakeet worker returned invalid JSON response.")
        }

        if let responseID = response["id"] as? String,
           responseID != expectedID {
            throw STTError.providerError(message: "Parakeet worker response ID mismatch.")
        }

        return response
    }

    private func readResponseLineLocked(worker: WorkerState, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let line = popLineFromBufferLocked() {
                return line
            }

            var byte: UInt8 = 0
            let result = Darwin.read(worker.stdoutFD, &byte, 1)
            if result == 1 {
                stdoutBuffer.append(byte)
                continue
            }
            if result == 0 {
                throw STTError.providerError(message: "Parakeet worker exited unexpectedly.")
            }

            let readError = errno
            if readError == EWOULDBLOCK || readError == EAGAIN {
                if !worker.process.isRunning {
                    throw STTError.providerError(message: "Parakeet worker stopped before responding.")
                }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }

            throw STTError.providerError(
                message: "Failed reading response from Parakeet worker (errno \(readError))."
            )
        }

        throw STTError.providerError(message: "Timed out waiting for Parakeet worker response.")
    }

    func popLineFromBufferLocked() -> String? {
        let newline = Data([0x0A])
        guard let range = stdoutBuffer.range(of: newline) else { return nil }

        let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
        stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
        return String(data: lineData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
