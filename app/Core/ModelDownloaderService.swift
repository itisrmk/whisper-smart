import Foundation

/// Coordinates downloading of model files for local STT providers.
///
/// Currently a stub that simulates download progress.
/// TODO: Replace with real URLSession-based downloader once model
///       hosting URLs are finalized.
final class ModelDownloaderService {

    static let shared = ModelDownloaderService()

    private var activeTasks: [String: DispatchWorkItem] = [:]

    private init() {}

    // MARK: - Public

    /// Starts downloading (or simulates downloading) the given variant,
    /// driving transitions on the provided state machine.
    func download(variant: ModelVariant, state: ModelDownloadState) {
        // Already on disk — just sync state.
        if variant.isDownloaded {
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
    }

    // MARK: - Stub simulation

    private func startDownload(variant: ModelVariant, state: ModelDownloadState) {
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
                        // Ensure the parent directory exists.
                        let dir = variant.localURL.deletingLastPathComponent()
                        try? FileManager.default.createDirectory(
                            at: dir,
                            withIntermediateDirectories: true
                        )
                        // Write a placeholder file so `isDownloaded` returns true.
                        FileManager.default.createFile(
                            atPath: variant.localURL.path,
                            contents: Data("stub-model".utf8)
                        )
                        state.transitionToReady()
                    }
                }
            }
        }

        activeTasks[variant.id] = work
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }
}
