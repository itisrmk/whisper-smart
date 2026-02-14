import Foundation
import SwiftUI

struct TTSModelPlaceholderOption {
    let id: String
    let displayName: String
    let modelCardURL: URL
    let previewAssetURL: URL
    let relativePreviewPath: String

    static let qwen3CustomVoice = TTSModelPlaceholderOption(
        id: "qwen3_tts_12hz_1_7b_custom_voice",
        displayName: "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
        modelCardURL: URL(string: "https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice")!,
        previewAssetURL: URL(string: "https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice/raw/main/README.md")!,
        relativePreviewPath: "tts/qwen3-tts-12hz-1.7b-customvoice/README.md"
    )
}

enum TTSPlaceholderDownloadPhase: Equatable {
    case idle
    case downloading
    case ready(localPath: String)
    case failed(message: String)
}

@MainActor
final class TTSModelPlaceholderDownloader: ObservableObject {
    static let shared = TTSModelPlaceholderDownloader()

    @Published private(set) var phase: TTSPlaceholderDownloadPhase = .idle

    private init() {
        refresh()
    }

    func refresh() {
        guard let localURL = AppStoragePaths.resolvedModelURL(relativePath: TTSModelPlaceholderOption.qwen3CustomVoice.relativePreviewPath) else {
            phase = .failed(message: "Application Support path unavailable.")
            return
        }

        if FileManager.default.fileExists(atPath: localURL.path) {
            phase = .ready(localPath: localURL.path)
        } else {
            phase = .idle
        }
    }

    func downloadPreviewAsset() {
        phase = .downloading

        Task {
            do {
                let option = TTSModelPlaceholderOption.qwen3CustomVoice
                let (data, _) = try await URLSession.shared.data(from: option.previewAssetURL)

                guard let destinationURL = AppStoragePaths.resolvedModelURL(relativePath: option.relativePreviewPath) else {
                    phase = .failed(message: "Application Support path unavailable.")
                    return
                }

                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destinationURL, options: .atomic)

                phase = .ready(localPath: destinationURL.path)
            } catch {
                phase = .failed(message: "Preview asset download failed: \(error.localizedDescription)")
            }
        }
    }
}
