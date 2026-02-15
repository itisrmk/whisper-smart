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
    // Keep dependencies to the guaranteed core runtime. onnx-asr is optional
    // and the runner already falls back to raw ONNX inference when absent.
    private let runtimeDependencies = ["numpy", "onnxruntime"]
    private let commandTimeoutSeconds: TimeInterval = 45 * 60
    private let dependencyImportProbe = "import numpy, onnxruntime"

    private var status = ParakeetRuntimeBootstrapStatus(
        phase: .idle,
        detail: "Runtime not bootstrapped yet. It will auto-install in the background.",
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
                    arguments: [override, "-c", dependencyImportProbe],
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
        let candidate = trimmed.isEmpty ? "python3" : trimmed

        if candidate == "python3" {
            for fallback in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
                if fileManager.isExecutableFile(atPath: fallback) {
                    return fallback
                }
            }
        }

        return candidate
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
        let venvPythonURL = venvDirectory.appendingPathComponent("bin/python3")
        let sitePackagesDirectory = runtimeRoot.appendingPathComponent("python-packages", isDirectory: true)
        let shimPythonURL = runtimeRoot
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3")

        if !forceRepair, isManagedRuntimeReady(pythonURL: venvPythonURL) {
            updateStatus(
                phase: .ready,
                detail: "Managed runtime ready at \(venvPythonURL.path).",
                runtimeDirectory: runtimeRoot,
                pythonCommand: venvPythonURL.path
            )
            return venvPythonURL.path
        }

        if !forceRepair, isManagedSitePackagesRuntimeReady(shimPythonURL: shimPythonURL) {
            updateStatus(
                phase: .ready,
                detail: "Managed runtime ready at \(shimPythonURL.path).",
                runtimeDirectory: runtimeRoot,
                pythonCommand: shimPythonURL.path
            )
            return shimPythonURL.path
        }

        updateStatus(
            phase: .bootstrapping,
            detail: forceRepair ? "Repairing runtime directory…" : "Preparing runtime directory…",
            runtimeDirectory: runtimeRoot,
            pythonCommand: nil
        )

        do {
            if supportsVenv(pythonCommand: bootstrapPythonCommand) {
                if forceRepair || !fileManager.fileExists(atPath: venvPythonURL.path) {
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
                    pythonCommand: venvPythonURL.path
                )
                do {
                    try runCommand(
                        executablePath: venvPythonURL.path,
                        arguments: [
                            "-m", "pip", "install", "--disable-pip-version-check",
                            "--no-input", "--progress-bar", "off", "--upgrade", "pip"
                        ],
                        step: "upgrade pip"
                    )
                } catch {
                    // Continue with existing pip to keep bootstrap resilient when
                    // pip self-upgrade fails transiently.
                    bootstrapLogger.warning("pip upgrade failed; continuing with existing pip: \(error.localizedDescription, privacy: .public)")
                }

                updateStatus(
                    phase: .bootstrapping,
                    detail: "Installing dependencies (numpy, onnxruntime)…",
                    runtimeDirectory: runtimeRoot,
                    pythonCommand: venvPythonURL.path
                )
                try runCommand(
                    executablePath: venvPythonURL.path,
                    arguments: [
                        "-m", "pip", "install", "--disable-pip-version-check",
                        "--no-input", "--progress-bar", "off", "--upgrade"
                    ] + runtimeDependencies,
                    step: "install Parakeet runtime dependencies"
                )

                updateStatus(
                    phase: .bootstrapping,
                    detail: "Verifying Python runtime imports…",
                    runtimeDirectory: runtimeRoot,
                    pythonCommand: venvPythonURL.path
                )
                try runCommand(
                    executablePath: venvPythonURL.path,
                    arguments: ["-c", dependencyImportProbe],
                    step: "verify runtime dependencies"
                )

                updateStatus(
                    phase: .ready,
                    detail: "Managed runtime ready at \(venvPythonURL.path).",
                    runtimeDirectory: runtimeRoot,
                    pythonCommand: venvPythonURL.path
                )
                return venvPythonURL.path
            }

            bootstrapLogger.warning("Python venv support unavailable; using managed PYTHONPATH runtime mode")
            return try setupManagedSitePackagesRuntime(
                runtimeRoot: runtimeRoot,
                sitePackagesDirectory: sitePackagesDirectory,
                shimPythonURL: shimPythonURL
            )
        } catch {
            let message = "Parakeet runtime bootstrap failed: \(error.localizedDescription)"
            updateStatus(
                phase: .failed,
                detail: message,
                runtimeDirectory: runtimeRoot,
                pythonCommand: nil
            )
            throw ParakeetRuntimeBootstrapError(
                message: "\(message) Runtime setup is managed automatically; retry Parakeet after a few seconds."
            )
        }
    }

    func validateHostPrerequisites() throws {
        guard commandExists(bootstrapPythonCommand) else {
            throw ParakeetRuntimeBootstrapError(
                message: "Python runtime prerequisite not found ('\(bootstrapPythonCommand)'). Automatic setup requires Python 3."
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
                arguments: ["-c", dependencyImportProbe],
                step: "verify managed runtime"
            )
            return true
        } catch {
            bootstrapLogger.warning("Managed runtime verification failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func supportsVenv(pythonCommand: String) -> Bool {
        do {
            _ = try runCommand(
                executablePath: "/usr/bin/env",
                arguments: [pythonCommand, "-m", "venv", "--help"],
                step: "detect Python venv support"
            )
            return true
        } catch {
            return false
        }
    }

    func isManagedSitePackagesRuntimeReady(shimPythonURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: shimPythonURL.path) else { return false }
        do {
            try runCommand(
                executablePath: shimPythonURL.path,
                arguments: ["-c", dependencyImportProbe],
                step: "verify managed PYTHONPATH runtime"
            )
            return true
        } catch {
            bootstrapLogger.warning("Managed PYTHONPATH runtime verification failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func setupManagedSitePackagesRuntime(
        runtimeRoot: URL,
        sitePackagesDirectory: URL,
        shimPythonURL: URL
    ) throws -> String {
        try fileManager.createDirectory(at: sitePackagesDirectory, withIntermediateDirectories: true)

        updateStatus(
            phase: .bootstrapping,
            detail: "Preparing managed Python runtime…",
            runtimeDirectory: runtimeRoot,
            pythonCommand: bootstrapPythonCommand
        )

        do {
            _ = try runCommand(
                executablePath: "/usr/bin/env",
                arguments: [bootstrapPythonCommand, "-m", "pip", "--version"],
                step: "verify pip availability"
            )
        } catch {
            _ = try runCommand(
                executablePath: "/usr/bin/env",
                arguments: [bootstrapPythonCommand, "-m", "ensurepip", "--upgrade"],
                step: "bootstrap pip"
            )
        }

        updateStatus(
            phase: .bootstrapping,
            detail: "Installing dependencies (numpy, onnxruntime)…",
            runtimeDirectory: runtimeRoot,
            pythonCommand: bootstrapPythonCommand
        )
        _ = try runCommand(
            executablePath: "/usr/bin/env",
            arguments: [
                bootstrapPythonCommand, "-m", "pip", "install",
                "--disable-pip-version-check", "--no-input", "--progress-bar", "off",
                "--upgrade", "--target", sitePackagesDirectory.path
            ] + runtimeDependencies,
            step: "install managed runtime dependencies"
        )

        let shimURL = try ensureShimPythonLauncher(
            runtimeRoot: runtimeRoot,
            basePythonCommand: bootstrapPythonCommand,
            sitePackagesDirectory: sitePackagesDirectory,
            shimPythonURL: shimPythonURL
        )

        updateStatus(
            phase: .bootstrapping,
            detail: "Verifying Python runtime imports…",
            runtimeDirectory: runtimeRoot,
            pythonCommand: shimURL.path
        )
        _ = try runCommand(
            executablePath: shimURL.path,
            arguments: ["-c", dependencyImportProbe],
            step: "verify managed runtime dependencies"
        )

        updateStatus(
            phase: .ready,
            detail: "Managed runtime ready at \(shimURL.path).",
            runtimeDirectory: runtimeRoot,
            pythonCommand: shimURL.path
        )
        return shimURL.path
    }

    func ensureShimPythonLauncher(
        runtimeRoot: URL,
        basePythonCommand: String,
        sitePackagesDirectory: URL,
        shimPythonURL: URL
    ) throws -> URL {
        let shimDirectory = runtimeRoot.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: shimDirectory, withIntermediateDirectories: true)

        let escapedSitePackages = shellQuoted(sitePackagesDirectory.path)
        let escapedPythonCommand = shellQuoted(basePythonCommand)
        let script = """
        #!/bin/sh
        set -e
        SITE_PACKAGES=\(escapedSitePackages)
        if [ -n "$PYTHONPATH" ]; then
          export PYTHONPATH="$SITE_PACKAGES:$PYTHONPATH"
        else
          export PYTHONPATH="$SITE_PACKAGES"
        fi
        exec /usr/bin/env \(escapedPythonCommand) "$@"
        """

        try script.write(to: shimPythonURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimPythonURL.path)
        return shimPythonURL
    }

    func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
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

        let stdoutData = NSMutableData()
        let stderrData = NSMutableData()
        let completion = DispatchSemaphore(value: 0)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stdoutData.append(chunk)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                stderrData.append(chunk)
            }
        }

        process.terminationHandler = { _ in
            completion.signal()
        }

        do {
            try process.run()
        } catch {
            throw ParakeetRuntimeBootstrapError(
                message: "Failed to \(step): \(error.localizedDescription)"
            )
        }

        let completed = completion.wait(timeout: .now() + commandTimeoutSeconds) == .success
        if !completed {
            process.terminate()
            _ = completion.wait(timeout: .now() + 2)
            if process.isRunning {
                process.interrupt()
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ParakeetRuntimeBootstrapError(
                message: "Failed to \(step): command timed out after \(Int(commandTimeoutSeconds))s."
            )
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let trailingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let trailingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !trailingStdout.isEmpty { stdoutData.append(trailingStdout) }
        if !trailingStderr.isEmpty { stderrData.append(trailingStderr) }

        let stdout = String(data: stdoutData as Data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData as Data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

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
