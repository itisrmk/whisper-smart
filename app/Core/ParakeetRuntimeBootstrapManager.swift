import Foundation
import os.log

private let bootstrapLogger = Logger(subsystem: "com.visperflow", category: "ParakeetBootstrap")

enum ParakeetRuntimeBootstrapPhase: String {
    case idle = "Idle"
    case bootstrapping = "Bootstrapping"
    case ready = "Ready"
    case failed = "Failed"
}

struct ParakeetRuntimeBootstrapStatus: Equatable {
    let phase: ParakeetRuntimeBootstrapPhase
    let detail: String
    let runtimeDirectory: URL?
    let pythonCommand: String?
    let timestamp: Date
}

struct ParakeetRuntimeBootstrapError: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class ParakeetRuntimeBootstrapManager {
    static let shared = ParakeetRuntimeBootstrapManager()

    private let queue = DispatchQueue(label: "com.visperflow.parakeet.bootstrap", qos: .userInitiated)
    private let statusLock = NSLock()
    private let fileManager = FileManager.default
    // Keep runtime bootstrap on widely available wheels only.
    // onnx-asr is optional at runtime and must not block one-click setup.
    private let runtimeDependencies = ["numpy", "onnxruntime", "sentencepiece"]

    private var status = ParakeetRuntimeBootstrapStatus(
        phase: .idle,
        detail: "Runtime not bootstrapped yet. It will auto-install on first Parakeet use.",
        runtimeDirectory: nil,
        pythonCommand: nil,
        timestamp: Date()
    )

    private init() {}

    func statusSnapshot() -> ParakeetRuntimeBootstrapStatus {
        statusLock.lock()
        defer { statusLock.unlock() }
        return status
    }

    func ensureRuntimeReady(forceRepair: Bool = false) throws -> String {
        if let override = pythonOverrideCommand() {
            // Never trust override blindly. Validate required imports first.
            do {
                try runCommand(
                    executablePath: "/usr/bin/env",
                    arguments: [override, "-c", "import numpy, onnxruntime, sentencepiece"],
                    step: "verify VISPERFLOW_PARAKEET_PYTHON override"
                )
                updateStatus(
                    phase: .ready,
                    detail: "Using VISPERFLOW_PARAKEET_PYTHON override (\(override)).",
                    runtimeDirectory: nil,
                    pythonCommand: override
                )
                return override
            } catch {
                bootstrapLogger.warning("Python override failed dependency validation; falling back to managed runtime: \(error.localizedDescription, privacy: .public)")
            }
        }

        return try queue.sync {
            try bootstrapLocked(forceRepair: forceRepair)
        }
    }

    func repairRuntimeInBackground() {
        queue.async {
            do {
                _ = try self.bootstrapLocked(forceRepair: true)
            } catch {
                bootstrapLogger.error("Background Parakeet runtime repair failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Bootstrap internals

private extension ParakeetRuntimeBootstrapManager {
    var bootstrapPythonCommand: String {
        let raw = ProcessInfo.processInfo.environment["VISPERFLOW_PARAKEET_BOOTSTRAP_PYTHON"]
            ?? ProcessInfo.processInfo.environment["VISPERFLOW_BOOTSTRAP_PYTHON"]
            ?? "python3"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "python3" : trimmed
    }

    func pythonOverrideCommand() -> String? {
        guard let raw = ProcessInfo.processInfo.environment["VISPERFLOW_PARAKEET_PYTHON"] else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func bootstrapLocked(forceRepair: Bool) throws -> String {
        try validateHostPrerequisites()

        let runtimeRoot = try resolveRuntimeRootDirectory()
        let venvDirectory = runtimeRoot.appendingPathComponent("venv", isDirectory: true)
        let pythonURL = venvDirectory.appendingPathComponent("bin/python3")

        if !forceRepair, isManagedRuntimeReady(pythonURL: pythonURL) {
            updateStatus(
                phase: .ready,
                detail: "Managed runtime ready at \(pythonURL.path).",
                runtimeDirectory: runtimeRoot,
                pythonCommand: pythonURL.path
            )
            return pythonURL.path
        }

        updateStatus(
            phase: .bootstrapping,
            detail: forceRepair ? "Repairing runtime directory…" : "Preparing runtime directory…",
            runtimeDirectory: runtimeRoot,
            pythonCommand: nil
        )

        do {
            if forceRepair || !fileManager.fileExists(atPath: pythonURL.path) {
                updateStatus(
                    phase: .bootstrapping,
                    detail: "Creating virtual environment…",
                    runtimeDirectory: runtimeRoot,
                    pythonCommand: nil
                )
                try runCommand(
                    executablePath: "/usr/bin/env",
                    arguments: [bootstrapPythonCommand, "-m", "venv", venvDirectory.path],
                    step: "create Python virtual environment"
                )
            }

            updateStatus(
                phase: .bootstrapping,
                detail: "Upgrading pip…",
                runtimeDirectory: runtimeRoot,
                pythonCommand: pythonURL.path
            )
            try runCommand(
                executablePath: pythonURL.path,
                arguments: ["-m", "pip", "install", "--upgrade", "pip"],
                step: "upgrade pip"
            )

            updateStatus(
                phase: .bootstrapping,
                detail: "Installing dependencies (numpy, onnxruntime, sentencepiece)…",
                runtimeDirectory: runtimeRoot,
                pythonCommand: pythonURL.path
            )
            try runCommand(
                executablePath: pythonURL.path,
                arguments: ["-m", "pip", "install", "--upgrade"] + runtimeDependencies,
                step: "install Parakeet runtime dependencies"
            )

            updateStatus(
                phase: .bootstrapping,
                detail: "Verifying Python runtime imports…",
                runtimeDirectory: runtimeRoot,
                pythonCommand: pythonURL.path
            )
            try runCommand(
                executablePath: pythonURL.path,
                arguments: ["-c", "import numpy, onnxruntime, sentencepiece"],
                step: "verify runtime dependencies"
            )

            updateStatus(
                phase: .ready,
                detail: "Managed runtime ready at \(pythonURL.path).",
                runtimeDirectory: runtimeRoot,
                pythonCommand: pythonURL.path
            )
            return pythonURL.path
        } catch {
            let message = "Parakeet runtime bootstrap failed: \(error.localizedDescription)"
            updateStatus(
                phase: .failed,
                detail: message,
                runtimeDirectory: runtimeRoot,
                pythonCommand: nil
            )
            throw ParakeetRuntimeBootstrapError(
                message: "\(message) Use Repair Parakeet Runtime in Settings → Provider."
            )
        }
    }

    func validateHostPrerequisites() throws {
        guard commandExists("xcode-select") else {
            throw ParakeetRuntimeBootstrapError(
                message: "Missing Apple Command Line Tools (xcode-select not found). Install with 'xcode-select --install', then retry."
            )
        }

        guard commandExists(bootstrapPythonCommand) else {
            throw ParakeetRuntimeBootstrapError(
                message: "Python runtime prerequisite not found ('\(bootstrapPythonCommand)'). Install Python 3 and ensure it is on PATH, or set VISPERFLOW_PARAKEET_BOOTSTRAP_PYTHON."
            )
        }

        do {
            try runCommand(
                executablePath: "/usr/bin/env",
                arguments: ["xcode-select", "-p"],
                step: "verify Apple Command Line Tools"
            )
        } catch {
            throw ParakeetRuntimeBootstrapError(
                message: "Apple Command Line Tools are required for one-click runtime setup. Run 'xcode-select --install' and open Xcode once to finish setup."
            )
        }

        do {
            try runCommand(
                executablePath: "/usr/bin/env",
                arguments: [bootstrapPythonCommand, "-m", "venv", "--help"],
                step: "verify Python venv support"
            )
        } catch {
            throw ParakeetRuntimeBootstrapError(
                message: "Python prerequisite is missing venv support. Install a full Python 3 build (with venv), then retry one-click runtime setup."
            )
        }
    }

    func commandExists(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func resolveRuntimeRootDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["VISPERFLOW_PARAKEET_RUNTIME_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let projectLocal = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".visperflow", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("parakeet", isDirectory: true)

        var candidates = AppStoragePaths.runtimeRootCandidates(fileManager: fileManager)
        candidates.append(projectLocal)

        var createErrors: [String] = []
        for candidate in candidates {
            do {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
                return candidate
            } catch {
                createErrors.append("\(candidate.path): \(error.localizedDescription)")
            }
        }

        throw ParakeetRuntimeBootstrapError(
            message: "Cannot create Parakeet runtime directory. Tried: \(createErrors.joined(separator: " | "))"
        )
    }

    func isManagedRuntimeReady(pythonURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: pythonURL.path) else { return false }
        do {
            try runCommand(
                executablePath: pythonURL.path,
                arguments: ["-c", "import numpy, onnxruntime, sentencepiece"],
                step: "verify managed runtime"
            )
            return true
        } catch {
            bootstrapLogger.warning("Managed runtime verification failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func runCommand(executablePath: String, arguments: [String], step: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ParakeetRuntimeBootstrapError(
                message: "Failed to \(step): \(error.localizedDescription)"
            )
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let details = !stderr.isEmpty ? stderr : stdout
            throw ParakeetRuntimeBootstrapError(
                message: "Failed to \(step) (exit \(process.terminationStatus)): \(details)"
            )
        }

        return stdout
    }

    func updateStatus(
        phase: ParakeetRuntimeBootstrapPhase,
        detail: String,
        runtimeDirectory: URL?,
        pythonCommand: String?
    ) {
        statusLock.lock()
        status = ParakeetRuntimeBootstrapStatus(
            phase: phase,
            detail: detail,
            runtimeDirectory: runtimeDirectory,
            pythonCommand: pythonCommand,
            timestamp: Date()
        )
        statusLock.unlock()

        bootstrapLogger.info("Parakeet runtime status: \(phase.rawValue, privacy: .public) - \(detail, privacy: .public)")
        NotificationCenter.default.post(name: .parakeetRuntimeBootstrapDidChange, object: nil)
    }
}

extension Notification.Name {
    static let parakeetRuntimeBootstrapDidChange = Notification.Name("parakeetRuntimeBootstrapDidChange")
}
