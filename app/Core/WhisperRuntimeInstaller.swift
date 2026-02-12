import Foundation
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

    func installWithHomebrew() {
        guard !isInstalling else { return }
        phase = .installing

        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["brew", "install", "whisper-cpp"]

            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            self.installProcess = process

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    self.phase = .failed(message: "Failed to start Homebrew install: \(error.localizedDescription)")
                }
                return
            }

            process.waitUntilExit()
            self.installProcess = nil

            if process.terminationStatus == 0, let path = WhisperLocalRuntime.detectCLIPath() {
                DictationProviderPolicy.whisperCLIPath = path
                DispatchQueue.main.async {
                    self.phase = .ready(path: path)
                }
                whisperRuntimeLogger.info("Whisper runtime install completed: \(path, privacy: .public)")
                return
            }

            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = stderr.isEmpty
                ? "brew install whisper-cpp failed with status \(process.terminationStatus)."
                : stderr
            DispatchQueue.main.async {
                self.phase = .failed(message: detail)
            }
        }
    }

    func cancelInstall() {
        installProcess?.terminate()
        installProcess = nil
        refreshState()
    }

    private var isInstalling: Bool {
        if case .installing = phase { return true }
        return false
    }
}
