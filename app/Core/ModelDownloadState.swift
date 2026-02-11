import Foundation
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "ModelDownloadState")

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
        /// Download succeeded; model file is on disk and validated.
        case ready
        /// Download failed with a human-readable message.
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .notReady

    /// The variant this state machine tracks.
    private(set) var variant: ModelVariant

    init(variant: ModelVariant) {
        self.variant = variant
        syncFromDisk()
    }

    /// Re-target this state machine to a different variant (e.g. when the user switches providers).
    func rebind(to newVariant: ModelVariant) {
        guard newVariant != variant else { return }
        variant = newVariant
        syncFromDisk()
        logger.info("Download state rebound to variant: \(newVariant.id)")
    }

    // MARK: - Transitions (called by ModelDownloaderService)

    func transitionToDownloading() {
        phase = .downloading(progress: 0)
        logger.info("Download started for \(self.variant.id)")
    }

    func updateProgress(_ fraction: Double) {
        phase = .downloading(progress: min(max(fraction, 0), 1))
    }

    func transitionToReady() {
        // Verify the file actually passes validation before declaring ready.
        if variant.isDownloaded {
            phase = .ready
            logger.info("Model ready: \(self.variant.id) — \(self.variant.validationStatus)")
        } else {
            let status = variant.validationStatus
            phase = .failed(message: "Download completed but model validation failed: \(status)")
            logger.error("Post-download validation failed for \(self.variant.id): \(status)")
        }
    }

    func transitionToFailed(message: String) {
        phase = .failed(message: message)
        logger.error("Download failed for \(self.variant.id): \(message)")
    }

    func reset() {
        syncFromDisk()
    }

    /// Deletes the on-disk model file and resets state to `.notReady`.
    func deleteModelFile() {
        guard let url = variant.localURL else { return }
        try? FileManager.default.removeItem(at: url)
        phase = .notReady
        logger.info("Deleted model file for \(self.variant.id)")
    }

    // MARK: - Private

    /// Syncs phase from on-disk state, handling incomplete/corrupt files.
    private func syncFromDisk() {
        if variant.isDownloaded {
            phase = .ready
            logger.info("Disk sync: model present and valid for \(self.variant.id)")
        } else if let url = variant.localURL,
                  FileManager.default.fileExists(atPath: url.path) {
            // File exists but failed validation — likely incomplete or corrupt.
            let status = variant.validationStatus
            phase = .failed(message: "Model file on disk is invalid: \(status)")
            logger.warning("Disk sync: file exists but invalid for \(self.variant.id): \(status)")
        } else if let sourceError = variant.downloadUnavailableReason {
            phase = .failed(message: sourceError)
            logger.warning("Disk sync: model source unavailable for \(self.variant.id): \(sourceError)")
        } else {
            phase = .notReady
        }
    }
}
