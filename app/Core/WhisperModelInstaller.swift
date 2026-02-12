import Foundation
import Combine
import os.log

private let whisperInstallerLogger = Logger(subsystem: "com.visperflow", category: "WhisperInstaller")

enum WhisperModelTier: String, CaseIterable, Identifiable {
    case baseEn = "base_en"
    case smallEn = "small_en"
    case mediumEn = "medium_en"
    case largeV3Turbo = "large_v3_turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .baseEn: return "Whisper Base.en"
        case .smallEn: return "Whisper Small.en"
        case .mediumEn: return "Whisper Medium.en"
        case .largeV3Turbo: return "Whisper Large-v3 Turbo"
        }
    }

    var fileName: String {
        switch self {
        case .baseEn: return "ggml-base.en.bin"
        case .smallEn: return "ggml-small.en.bin"
        case .mediumEn: return "ggml-medium.en.bin"
        case .largeV3Turbo: return "ggml-large-v3-turbo.bin"
        }
    }

    var approxSizeLabel: String {
        switch self {
        case .baseEn: return "~141 MB"
        case .smallEn: return "~466 MB"
        case .mediumEn: return "~1.5 GB"
        case .largeV3Turbo: return "~1.6 GB"
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }
}

enum WhisperModelInstallPhase: Equatable {
    case notInstalled(tier: WhisperModelTier)
    case downloading(tier: WhisperModelTier, progress: Double)
    case ready(tier: WhisperModelTier)
    case failed(message: String)
}

final class WhisperModelInstaller: NSObject, ObservableObject {
    static let shared = WhisperModelInstaller()

    @Published private(set) var phase: WhisperModelInstallPhase = .notInstalled(tier: .baseEn)
    @Published private(set) var selectedTier: WhisperModelTier = .baseEn

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private var activeTask: URLSessionDownloadTask?
    private var activeTier: WhisperModelTier?

    private override init() {
        super.init()
        selectedTier = WhisperModelTier(rawValue: DictationProviderPolicy.whisperModelTier) ?? .baseEn
        refreshState()
    }

    func setTier(_ tier: WhisperModelTier) {
        selectedTier = tier
        DictationProviderPolicy.whisperModelTier = tier.rawValue
        refreshState()
    }

    var localModelURL: URL { localModelURL(for: selectedTier) }

    func localModelURL(for tier: WhisperModelTier) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return root
            .appendingPathComponent(AppStoragePaths.canonicalAppSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("whisper", isDirectory: true)
            .appendingPathComponent(tier.fileName)
    }

    func refreshState() {
        let tier = selectedTier
        let path = localModelURL(for: tier).path
        if FileManager.default.fileExists(atPath: path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64,
           size > 10_000_000 {
            DictationProviderPolicy.whisperModelPath = path
            phase = .ready(tier: tier)
            return
        }
        phase = .notInstalled(tier: tier)
    }

    func downloadSelectedModel() {
        downloadModel(for: selectedTier)
    }

    func downloadModel(for tier: WhisperModelTier) {
        if case .downloading = phase { return }

        let destination = localModelURL(for: tier)

        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            phase = .failed(message: "Cannot create Whisper model directory: \(error.localizedDescription)")
            return
        }

        let task = session.downloadTask(with: tier.downloadURL)
        activeTask = task
        activeTier = tier
        phase = .downloading(tier: tier, progress: 0)
        task.resume()
        whisperInstallerLogger.info("Started Whisper model download tier=\(tier.rawValue, privacy: .public)")
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        activeTier = nil
        refreshState()
    }
}

extension WhisperModelInstaller: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = max(totalBytesExpectedToWrite, 1)
        let progress = min(max(Double(totalBytesWritten) / Double(expected), 0), 1)
        DispatchQueue.main.async {
            guard let tier = self.activeTier else { return }
            self.phase = .downloading(tier: tier, progress: progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let tier = activeTier else { return }
            let destination = localModelURL(for: tier)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            DictationProviderPolicy.whisperModelPath = destination.path
            DictationProviderPolicy.whisperModelTier = tier.rawValue
            DispatchQueue.main.async {
                self.phase = .ready(tier: tier)
                NotificationCenter.default.post(name: Notification.Name("sttProviderDidChange"), object: nil)
            }
            whisperInstallerLogger.info("Whisper model download completed tier=\(tier.rawValue, privacy: .public)")
        } catch {
            DispatchQueue.main.async {
                self.phase = .failed(message: "Failed to store Whisper model: \(error.localizedDescription)")
            }
        }

        activeTask = nil
        activeTier = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        DispatchQueue.main.async {
            self.phase = .failed(message: "Whisper model download failed: \(error.localizedDescription)")
        }
        activeTask = nil
        activeTier = nil
    }
}
