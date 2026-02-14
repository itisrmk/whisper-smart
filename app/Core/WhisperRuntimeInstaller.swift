import Foundation
import CryptoKit
import os.log

private let whisperRuntimeLogger = Logger(subsystem: "com.visperflow", category: "WhisperRuntimeInstaller")

enum WhisperRuntimeInstallPhase: Equatable {
    case notInstalled
    case installing
    case ready(path: String)
    case failed(message: String)
}

final class WhisperRuntimeInstaller: ObservableObject {
    static let shared = WhisperRuntimeInstaller()

    @Published private(set) var phase: WhisperRuntimeInstallPhase = .notInstalled

    private let queue = DispatchQueue(label: "com.visperflow.whisper.runtime", qos: .utility)
    private var installProcess: Process?
    private var installCancelled = false

    private init() {
        refreshState()
    }

    func refreshState() {
        if let path = WhisperLocalRuntime.detectCLIPath() {
            DictationProviderPolicy.whisperCLIPath = path
            phase = .ready(path: path)
        } else {
            phase = .notInstalled
        }
    }

    func installRuntime() {
        guard !isInstalling else { return }
        phase = .installing
        installCancelled = false

        queue.async {
            do {
                let cliPath = try self.installManagedRuntime()
                guard !self.installCancelled else { return }
                DictationProviderPolicy.whisperCLIPath = cliPath
                DispatchQueue.main.async {
                    self.phase = .ready(path: cliPath)
                }
                whisperRuntimeLogger.info("Managed Whisper runtime install completed: \(cliPath, privacy: .public)")
            } catch {
                guard !self.installCancelled else { return }
                DispatchQueue.main.async {
                    self.phase = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    func cancelInstall() {
        installCancelled = true
        installProcess?.terminate()
        installProcess = nil
        refreshState()
    }

    private var isInstalling: Bool {
        if case .installing = phase { return true }
        return false
    }
}

private extension WhisperRuntimeInstaller {
    struct RuntimeAsset {
        let version: String
        let sourceURL: URL
        let sha256: String
    }

    func installManagedRuntime() throws -> String {
        try validateHostPrerequisites()

        let runtimeRoot = try resolveRuntimeRootDirectory()
        let binDir = runtimeRoot.appendingPathComponent("bin", isDirectory: true)
        let cliURL = binDir.appendingPathComponent("whisper-cli")

        if FileManager.default.isExecutableFile(atPath: cliURL.path) {
            return cliURL.path
        }

        let asset = RuntimeAsset(
            version: "v1.8.3",
            sourceURL: URL(string: "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.8.3.tar.gz")!,
            sha256: "ef85e2bc866f9198b8c2fd36749067abeb0e9886db60e3f690fc56f247becd7a"
        )

        let tmpRoot = runtimeRoot.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let workDir = tmpRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let archiveURL = workDir.appendingPathComponent("whisper.tar.gz")
        let srcRoot = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcRoot, withIntermediateDirectories: true)

        try downloadFile(from: asset.sourceURL, to: archiveURL)
        try verifySHA256(of: archiveURL, expectedHex: asset.sha256)
        try runCommand("/usr/bin/env", ["tar", "-xzf", archiveURL.path, "-C", srcRoot.path], step: "extract whisper source")

        guard let extractedDir = try FileManager.default.contentsOfDirectory(
            at: srcRoot,
            includingPropertiesForKeys: nil
        ).first(where: { $0.lastPathComponent.hasPrefix("whisper.cpp-") }) else {
            throw NSError(domain: "WhisperRuntimeInstaller", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Whisper source extraction failed: archive layout was unexpected."
            ])
        }

        let jobs = max(ProcessInfo.processInfo.processorCount / 2, 1)
        try runCommand("/usr/bin/env", ["make", "-j\(jobs)", "whisper-cli"], cwd: extractedDir, step: "build whisper-cli")

        let builtCandidates = [
            extractedDir.appendingPathComponent("build/bin/whisper-cli"),
            extractedDir.appendingPathComponent("bin/whisper-cli")
        ]
        guard let builtCLI = builtCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw NSError(domain: "WhisperRuntimeInstaller", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Whisper runtime build finished but whisper-cli was not produced."
            ])
        }

        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let versionedTarget = binDir.appendingPathComponent("whisper-cli-\(asset.version)")
        let tempTarget = binDir.appendingPathComponent(".whisper-cli.tmp")

        if FileManager.default.fileExists(atPath: tempTarget.path) {
            try? FileManager.default.removeItem(at: tempTarget)
        }
        try FileManager.default.copyItem(at: builtCLI, to: tempTarget)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempTarget.path)

        if FileManager.default.fileExists(atPath: versionedTarget.path) {
            try FileManager.default.removeItem(at: versionedTarget)
        }
        try FileManager.default.moveItem(at: tempTarget, to: versionedTarget)

        if FileManager.default.fileExists(atPath: cliURL.path) {
            try FileManager.default.removeItem(at: cliURL)
        }
        try FileManager.default.createSymbolicLink(at: cliURL, withDestinationURL: versionedTarget)

        return cliURL.path
    }

    func validateHostPrerequisites() throws {
        guard commandExists("xcode-select") else {
            throw NSError(domain: "WhisperRuntimeInstaller", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Missing Apple Command Line Tools (xcode-select not found). Install with 'xcode-select --install', then retry."
            ])
        }

        guard commandExists("make") else {
            throw NSError(domain: "WhisperRuntimeInstaller", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Missing 'make' build tool. Install Apple Command Line Tools with 'xcode-select --install', then retry."
            ])
        }

        do {
            try runCommand("/usr/bin/env", ["xcode-select", "-p"], step: "verify Apple Command Line Tools")
        } catch {
            throw NSError(domain: "WhisperRuntimeInstaller", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Apple Command Line Tools are required to build whisper-cli. Run 'xcode-select --install' and finish setup, then retry."
            ])
        }
    }

    func commandExists(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func resolveRuntimeRootDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["VISPERFLOW_WHISPER_RUNTIME_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let candidates = AppStoragePaths.whisperRuntimeRootCandidates()
        var createErrors: [String] = []
        for candidate in candidates {
            do {
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                return candidate
            } catch {
                createErrors.append("\(candidate.path): \(error.localizedDescription)")
            }
        }

        throw NSError(domain: "WhisperRuntimeInstaller", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Cannot create Whisper runtime directory. Tried: \(createErrors.joined(separator: " | "))"
        ])
    }

    func downloadFile(from sourceURL: URL, to destinationURL: URL) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var downloadError: Error?

        let task = URLSession.shared.downloadTask(with: sourceURL) { tempURL, response, error in
            defer { semaphore.signal() }
            if let error {
                downloadError = NSError(domain: "WhisperRuntimeInstaller", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to download Whisper runtime sources: \(error.localizedDescription)"
                ])
                return
            }

            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                downloadError = NSError(domain: "WhisperRuntimeInstaller", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to download Whisper runtime sources (HTTP \(http.statusCode))."
                ])
                return
            }

            guard let tempURL else {
                downloadError = NSError(domain: "WhisperRuntimeInstaller", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "Whisper runtime source download returned no data."
                ])
                return
            }

            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            } catch {
                downloadError = error
            }
        }

        task.resume()
        semaphore.wait()
        if let downloadError { throw downloadError }
    }

    func verifySHA256(of fileURL: URL, expectedHex: String) throws {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data)
        let actual = digest.compactMap { String(format: "%02x", $0) }.joined()
        guard actual == expectedHex.lowercased() else {
            throw NSError(domain: "WhisperRuntimeInstaller", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Whisper runtime source checksum validation failed."
            ])
        }
    }

    func runCommand(_ executable: String, _ arguments: [String], cwd: URL? = nil, step: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        installProcess = process

        do {
            try process.run()
        } catch {
            installProcess = nil
            throw NSError(domain: "WhisperRuntimeInstaller", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Failed to \(step): \(error.localizedDescription)"
            ])
        }

        process.waitUntilExit()
        installProcess = nil

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "WhisperRuntimeInstaller", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Failed to \(step) (exit \(process.terminationStatus)). \(output)"
            ])
        }
    }
}
