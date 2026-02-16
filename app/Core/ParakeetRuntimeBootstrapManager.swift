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
    // Parakeet TDT requires onnx-asr compatibility glue; raw ONNX fallback is
    // not sufficient for this model family.
    private let runtimeDependencies = ["numpy", "onnxruntime", "onnx-asr[cpu,hub]"]
    private let commandTimeoutSeconds: TimeInterval = 45 * 60
    private let networkCommandTimeoutSeconds: TimeInterval = 20 * 60
    private let minimumSupportedPythonMinor = 10
    private let preferredMaximumPythonMinor = 13
    private let dependencyImportProbe = "import numpy, onnxruntime, onnx_asr"

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
            for fallback in [
                "/opt/homebrew/bin/python3.13",
                "/opt/homebrew/bin/python3.12",
                "/opt/homebrew/bin/python3.11",
                "/usr/local/bin/python3.13",
                "/usr/local/bin/python3.12",
                "/usr/local/bin/python3.11",
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
                "/usr/bin/python3"
            ] {
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

        let pythonCandidates: [String]
        do {
            pythonCandidates = try bootstrapPythonCandidates(runtimeRoot: runtimeRoot)
        } catch {
            let message = "Parakeet runtime bootstrap failed: \(error.localizedDescription)"
            updateStatus(
                phase: .failed,
                detail: message,
                runtimeDirectory: runtimeRoot,
                pythonCommand: nil
            )
            throw ParakeetRuntimeBootstrapError(
                message: "\(message) Run runtime setup from Settings -> Provider, then retry Parakeet."
            )
        }

        guard !pythonCandidates.isEmpty else {
            let message = "Parakeet runtime bootstrap failed: no Python interpreter candidates are available."
            updateStatus(
                phase: .failed,
                detail: message,
                runtimeDirectory: runtimeRoot,
                pythonCommand: nil
            )
            throw ParakeetRuntimeBootstrapError(
                message: "\(message) Run runtime setup from Settings -> Provider, then retry Parakeet."
            )
        }

        var attemptFailures: [String] = []

        for (index, pythonCommand) in pythonCandidates.enumerated() {
            if let version = pythonVersionInfo(pythonCommand: pythonCommand),
               !isSupportedPythonVersion(version) {
                attemptFailures.append(
                    "\(pythonCommand) (Python \(version.major).\(version.minor)) is unsupported; requires Python 3.\(minimumSupportedPythonMinor)+."
                )
                continue
            }

            if forceRepair || index > 0 {
                resetManagedRuntimeArtifacts(
                    venvDirectory: venvDirectory,
                    sitePackagesDirectory: sitePackagesDirectory,
                    shimPythonURL: shimPythonURL
                )
            }

            updateStatus(
                phase: .bootstrapping,
                detail: "Preparing Python runtime (\(pythonCommand))…",
                runtimeDirectory: runtimeRoot,
                pythonCommand: pythonCommand
            )

            do {
                if supportsVenv(pythonCommand: pythonCommand) {
                    return try setupManagedVenvRuntime(
                        runtimeRoot: runtimeRoot,
                        venvDirectory: venvDirectory,
                        venvPythonURL: venvPythonURL,
                        pythonCommand: pythonCommand
                    )
                }

                bootstrapLogger.warning("Python venv support unavailable for \(pythonCommand, privacy: .public); using managed PYTHONPATH runtime mode")
                return try setupManagedSitePackagesRuntime(
                    runtimeRoot: runtimeRoot,
                    sitePackagesDirectory: sitePackagesDirectory,
                    shimPythonURL: shimPythonURL,
                    pythonCommand: pythonCommand
                )
            } catch {
                attemptFailures.append("\(pythonCommand): \(error.localizedDescription)")
                bootstrapLogger.warning("Parakeet runtime bootstrap attempt failed for \(pythonCommand, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        let failureDetail = attemptFailures.isEmpty ? "unknown bootstrap failure" : attemptFailures.joined(separator: " | ")
        let message = "Parakeet runtime bootstrap failed: \(failureDetail)"
        updateStatus(
            phase: .failed,
            detail: message,
            runtimeDirectory: runtimeRoot,
            pythonCommand: nil
        )
        throw ParakeetRuntimeBootstrapError(
            message: "\(message) Run runtime setup from Settings -> Provider, then retry Parakeet."
        )
    }

    func setupManagedVenvRuntime(
        runtimeRoot: URL,
        venvDirectory: URL,
        venvPythonURL: URL,
        pythonCommand: String
    ) throws -> String {
        if !fileManager.fileExists(atPath: venvPythonURL.path) {
            updateStatus(
                phase: .bootstrapping,
                detail: "Creating virtual environment…",
                runtimeDirectory: runtimeRoot,
                pythonCommand: pythonCommand
            )
            try runCommand(
                executablePath: "/usr/bin/env",
                arguments: [pythonCommand, "-m", "venv", venvDirectory.path],
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
            detail: "Installing dependencies (numpy, onnxruntime, onnx-asr)…",
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

    func resetManagedRuntimeArtifacts(
        venvDirectory: URL,
        sitePackagesDirectory: URL,
        shimPythonURL: URL
    ) {
        if fileManager.fileExists(atPath: venvDirectory.path) {
            try? fileManager.removeItem(at: venvDirectory)
        }
        if fileManager.fileExists(atPath: sitePackagesDirectory.path) {
            try? fileManager.removeItem(at: sitePackagesDirectory)
        }
        if fileManager.fileExists(atPath: shimPythonURL.path) {
            try? fileManager.removeItem(at: shimPythonURL)
        }
    }

    func bootstrapPythonCandidates(runtimeRoot: URL) throws -> [String] {
        let seed = bootstrapPythonCommand
        let hostCandidates = hostPythonCandidateCommands(seed: seed)

        var supportedHostCandidates: [String] = []
        var allDetectedCandidates: [String] = []

        for candidate in hostCandidates where commandExists(candidate) {
            allDetectedCandidates.append(candidate)
            guard let version = pythonVersionInfo(pythonCommand: candidate) else {
                supportedHostCandidates.append(candidate)
                continue
            }

            if isSupportedPythonVersion(version) {
                supportedHostCandidates.append(candidate)
            }
        }

        var preferredCandidates = supportedHostCandidates.filter { candidate in
            guard let version = pythonVersionInfo(pythonCommand: candidate) else { return false }
            return isPreferredPythonVersion(version)
        }

        if preferredCandidates.isEmpty {
            if let portable = try? ensurePortablePythonCommand(runtimeRoot: runtimeRoot) {
                preferredCandidates.append(portable)
            }
        }

        let fallbackCandidates = supportedHostCandidates.filter { candidate in
            preferredCandidates.contains(candidate) == false
        }

        let ordered = deduplicatedStrings(preferredCandidates + fallbackCandidates + allDetectedCandidates)
        return ordered.filter { commandExists($0) }
    }

    func hostPythonCandidateCommands(seed: String) -> [String] {
        deduplicatedStrings([
            seed,
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/usr/local/bin/python3.13",
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
            "python3"
        ])
    }

    func deduplicatedStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard seen.contains(value) == false else { continue }
            seen.insert(value)
            result.append(value)
        }
        return result
    }

    func pythonVersionInfo(pythonCommand: String) -> (major: Int, minor: Int)? {
        do {
            let output = try runCommand(
                executablePath: "/usr/bin/env",
                arguments: [pythonCommand, "-c", "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')"],
                step: "detect Python version"
            )
            let parts = output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ".")
            guard parts.count >= 2,
                  let major = Int(parts[0]),
                  let minor = Int(parts[1]) else {
                return nil
            }
            return (major, minor)
        } catch {
            return nil
        }
    }

    func isSupportedPythonVersion(_ version: (major: Int, minor: Int)) -> Bool {
        if version.major > 3 { return true }
        guard version.major == 3 else { return false }
        return version.minor >= minimumSupportedPythonMinor
    }

    func isPreferredPythonVersion(_ version: (major: Int, minor: Int)) -> Bool {
        guard version.major == 3 else { return false }
        return version.minor >= minimumSupportedPythonMinor && version.minor <= preferredMaximumPythonMinor
    }

    func ensurePortablePythonCommand(runtimeRoot: URL) throws -> String {
        let toolchainRoot = runtimeRoot.appendingPathComponent("toolchain/python", isDirectory: true)
        if let existing = locatePortablePythonExecutable(toolchainRoot: toolchainRoot),
           let version = pythonVersionInfo(pythonCommand: existing),
           isSupportedPythonVersion(version) {
            return existing
        }

        if fileManager.fileExists(atPath: toolchainRoot.path) {
            try? fileManager.removeItem(at: toolchainRoot)
        }
        try fileManager.createDirectory(at: toolchainRoot, withIntermediateDirectories: true)

        updateStatus(
            phase: .bootstrapping,
            detail: "Installing managed Python toolchain (one-time setup)…",
            runtimeDirectory: runtimeRoot,
            pythonCommand: nil
        )

        let assetURL = try resolvePortablePythonAssetURL()
        let archiveURL = toolchainRoot.appendingPathComponent(assetURL.lastPathComponent)

        try runCommand(
            executablePath: "/usr/bin/curl",
            arguments: ["-fL", assetURL.absoluteString, "-o", archiveURL.path],
            step: "download managed Python toolchain",
            timeout: networkCommandTimeoutSeconds
        )
        try runCommand(
            executablePath: "/usr/bin/tar",
            arguments: ["-xf", archiveURL.path, "-C", toolchainRoot.path],
            step: "extract managed Python toolchain",
            timeout: networkCommandTimeoutSeconds
        )
        try? fileManager.removeItem(at: archiveURL)

        if let portable = locatePortablePythonExecutable(toolchainRoot: toolchainRoot) {
            return portable
        }

        throw ParakeetRuntimeBootstrapError(
            message: "Failed to locate managed Python executable after toolchain extraction."
        )
    }

    func resolvePortablePythonAssetURL() throws -> URL {
        struct ReleaseAsset: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        struct LatestRelease: Decodable {
            let assets: [ReleaseAsset]
        }

        let architectureToken: String
        #if arch(arm64)
        architectureToken = "aarch64-apple-darwin-install_only"
        #else
        architectureToken = "x86_64-apple-darwin-install_only"
        #endif

        let requestURL = URL(string: "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest")!
        var request = URLRequest(url: requestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WhisperSmart-ParakeetBootstrap", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = networkCommandTimeoutSeconds

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + networkCommandTimeoutSeconds) == .timedOut {
            task.cancel()
            throw ParakeetRuntimeBootstrapError(message: "Timed out while querying managed Python toolchain metadata.")
        }

        if let resultError {
            throw ParakeetRuntimeBootstrapError(
                message: "Failed to query managed Python toolchain metadata: \(resultError.localizedDescription)"
            )
        }

        guard let httpResponse = resultResponse as? HTTPURLResponse else {
            throw ParakeetRuntimeBootstrapError(message: "Managed Python metadata request returned an invalid response.")
        }

        guard (200...299).contains(httpResponse.statusCode), let resultData else {
            throw ParakeetRuntimeBootstrapError(
                message: "Managed Python metadata request failed with HTTP \(httpResponse.statusCode)."
            )
        }

        let decoded: LatestRelease
        do {
            decoded = try JSONDecoder().decode(LatestRelease.self, from: resultData)
        } catch {
            throw ParakeetRuntimeBootstrapError(
                message: "Failed to parse managed Python metadata: \(error.localizedDescription)"
            )
        }

        let preferredSuffixes = [".tar.gz", ".tar.zst"]
        for suffix in preferredSuffixes {
            if let match = decoded.assets.first(where: { asset in
                asset.name.contains(architectureToken) && asset.name.hasSuffix(suffix)
            }), let url = URL(string: match.browserDownloadURL) {
                return url
            }
        }

        throw ParakeetRuntimeBootstrapError(
            message: "No managed Python download asset found for \(architectureToken)."
        )
    }

    func locatePortablePythonExecutable(toolchainRoot: URL) -> String? {
        let directCandidates = [
            toolchainRoot.appendingPathComponent("python/install/bin/python3"),
            toolchainRoot.appendingPathComponent("bin/python3")
        ]
        for candidate in directCandidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate.path
        }

        guard let enumerator = fileManager.enumerator(
            at: toolchainRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var matches: [String] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "python3",
                  fileManager.isExecutableFile(atPath: url.path) else {
                continue
            }
            if url.path.contains("/install/bin/") || url.path.contains("/bin/") {
                matches.append(url.path)
            }
        }

        matches.sort { lhs, rhs in
            if lhs.count == rhs.count { return lhs < rhs }
            return lhs.count < rhs.count
        }
        return matches.first
    }

    func validateHostPrerequisites() throws {
        guard commandExists(bootstrapPythonCommand) else {
            throw ParakeetRuntimeBootstrapError(
                message: "Python runtime prerequisite not found ('\(bootstrapPythonCommand)'). Parakeet setup requires Python 3. Install it, then retry from Settings -> Provider."
            )
        }
    }

    func commandExists(_ command: String) -> Bool {
        if command.contains("/") {
            return fileManager.isExecutableFile(atPath: command)
        }

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
        shimPythonURL: URL,
        pythonCommand: String
    ) throws -> String {
        try fileManager.createDirectory(at: sitePackagesDirectory, withIntermediateDirectories: true)

        updateStatus(
            phase: .bootstrapping,
            detail: "Preparing managed Python runtime…",
            runtimeDirectory: runtimeRoot,
            pythonCommand: pythonCommand
        )

        do {
            _ = try runCommand(
                executablePath: "/usr/bin/env",
                arguments: [pythonCommand, "-m", "pip", "--version"],
                step: "verify pip availability"
            )
        } catch {
            _ = try runCommand(
                executablePath: "/usr/bin/env",
                arguments: [pythonCommand, "-m", "ensurepip", "--upgrade"],
                step: "bootstrap pip"
            )
        }

        updateStatus(
            phase: .bootstrapping,
            detail: "Installing dependencies (numpy, onnxruntime, onnx-asr)…",
            runtimeDirectory: runtimeRoot,
            pythonCommand: pythonCommand
        )
        _ = try runCommand(
            executablePath: "/usr/bin/env",
            arguments: [
                pythonCommand, "-m", "pip", "install",
                "--disable-pip-version-check", "--no-input", "--progress-bar", "off",
                "--upgrade", "--target", sitePackagesDirectory.path
            ] + runtimeDependencies,
            step: "install managed runtime dependencies"
        )

        let shimURL = try ensureShimPythonLauncher(
            runtimeRoot: runtimeRoot,
            basePythonCommand: pythonCommand,
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
    func runCommand(
        executablePath: String,
        arguments: [String],
        step: String,
        timeout: TimeInterval? = nil
    ) throws -> String {
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

        let timeoutSeconds = timeout ?? commandTimeoutSeconds
        let completed = completion.wait(timeout: .now() + timeoutSeconds) == .success
        if !completed {
            process.terminate()
            _ = completion.wait(timeout: .now() + 2)
            if process.isRunning {
                process.interrupt()
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ParakeetRuntimeBootstrapError(
                message: "Failed to \(step): command timed out after \(Int(timeoutSeconds))s."
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
