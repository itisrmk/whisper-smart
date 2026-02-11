import Foundation
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "ModelDownloader")

/// Coordinates downloading of model files for local STT providers.
///
/// Currently a stub that simulates download progress and writes a placeholder file.
/// TODO: Replace with real URLSession-based downloader once model hosting URLs are finalized.
final class ModelDownloaderService {

    static let shared = ModelDownloaderService()

    private var activeTasks: [String: DispatchWorkItem] = [:]

    private init() {}

    // MARK: - Public

    /// Starts downloading (or simulates downloading) the given variant,
    /// driving transitions on the provided state machine.
    func download(variant: ModelVariant, state: ModelDownloadState) {
        // Already on disk and valid — just sync state.
        if variant.isDownloaded {
            logger.info("Model already downloaded and valid: \(variant.id)")
            state.transitionToReady()
            return
        }
        switch state.phase {
        case .downloading, .ready:
            return // already in progress or done
        case .notReady, .failed:
            startDownload(variant: variant, state: state)
        }
    }

    /// Cancels an in-progress download.
    func cancel(variant: ModelVariant, state: ModelDownloadState) {
        activeTasks[variant.id]?.cancel()
        activeTasks.removeValue(forKey: variant.id)
        state.reset()
        logger.info("Download cancelled for \(variant.id)")
    }

    // MARK: - Stub simulation

    private func startDownload(variant: ModelVariant, state: ModelDownloadState) {
        guard let modelURL = variant.localURL else {
            state.transitionToFailed(message: "Cannot resolve model storage path. Check disk permissions.")
            return
        }

        state.transitionToDownloading()

        // Simulate progress over ~2 seconds in 10 steps.
        let steps = 10
        let interval: TimeInterval = 0.2
        let work = DispatchWorkItem { [weak state] in
            for i in 1...steps {
                guard let state = state else { return }
                Thread.sleep(forTimeInterval: interval)
                DispatchQueue.main.async {
                    if i < steps {
                        state.updateProgress(Double(i) / Double(steps))
                    } else {
                        // Write the stub model file to disk.
                        let writeError = Self.writeStubModel(to: modelURL, variant: variant)
                        if let error = writeError {
                            state.transitionToFailed(message: error)
                        } else {
                            // transitionToReady performs its own validation.
                            state.transitionToReady()
                        }
                    }
                }
            }
        }

        activeTasks[variant.id] = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }

    /// Writes a placeholder model file. Returns an error message on failure, nil on success.
    private static func writeStubModel(to url: URL, variant: ModelVariant) -> String? {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create model directory at \(dir.path): \(error.localizedDescription)")
            return "Failed to create model directory: \(error.localizedDescription)"
        }

        // Write enough bytes to pass minimumValidBytes validation.
        let stubData = Data(repeating: 0, count: max(Int(variant.minimumValidBytes), 2048))
        guard FileManager.default.createFile(atPath: url.path, contents: stubData) else {
            logger.error("Failed to write model file at \(url.path)")
            return "Failed to write model file to disk. Check available space."
        }

        logger.info("Stub model written to \(url.path) (\(stubData.count) bytes)")
        return nil
    }
}
