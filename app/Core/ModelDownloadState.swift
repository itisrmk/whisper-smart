import Foundation

/// Observable state machine tracking the download lifecycle of a local model.
///
/// ## State diagram
/// ```
///  ┌──────────┐  start   ┌─────────────┐  finish  ┌────────────┐
///  │ notReady │ ────────▶ │ downloading │ ───────▶ │   ready    │
///  └──────────┘           └──────┬──────┘          └────────────┘
///       ▲                        │ error                ▲
///       │  retry                 ▼                      │
///       └────────────── ┌────────────┐  retry + ok ─────┘
///                       │   failed   │
///                       └────────────┘
/// ```
final class ModelDownloadState: ObservableObject {

    enum Phase: Equatable {
        /// No model file present; download hasn't been attempted.
        case notReady
        /// Download in progress; `progress` is 0…1.
        case downloading(progress: Double)
        /// Download succeeded; model file is on disk.
        case ready
        /// Download failed with a human-readable message.
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .notReady

    /// The variant this state machine tracks.
    let variant: ModelVariant

    init(variant: ModelVariant) {
        self.variant = variant
        // Seed phase from disk state.
        if variant.isDownloaded {
            phase = .ready
        }
    }

    // MARK: - Transitions (called by ModelDownloaderService)

    func transitionToDownloading() {
        phase = .downloading(progress: 0)
    }

    func updateProgress(_ fraction: Double) {
        phase = .downloading(progress: min(max(fraction, 0), 1))
    }

    func transitionToReady() {
        phase = .ready
    }

    func transitionToFailed(message: String) {
        phase = .failed(message: message)
    }

    func reset() {
        phase = variant.isDownloaded ? .ready : .notReady
    }
}
