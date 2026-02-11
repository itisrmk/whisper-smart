import AVFoundation

/// Stub STT provider for NVIDIA Parakeet.
///
/// Today this behaves identically to `StubSTTProvider` — it delivers
/// a fixed placeholder result. Once the ONNX Runtime integration is
/// wired up, this class will load the Parakeet model from disk and
/// run real inference.
final class ParakeetSTTProvider: STTProvider {
    let displayName = "NVIDIA Parakeet (local)"

    var onResult: ((STTResult) -> Void)?
    var onError: ((STTError) -> Void)?

    private let variant: ModelVariant

    init(variant: ModelVariant = .parakeetCTC06B) {
        self.variant = variant
    }

    func feedAudio(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // TODO: Accumulate PCM buffers for batch inference.
    }

    func beginSession() throws {
        guard variant.isDownloaded else {
            throw STTError.providerError(message: "Parakeet model not downloaded. Please download it in Settings → Provider.")
        }
        // TODO: Load ONNX model from variant.localURL.
    }

    func endSession() {
        // Deliver a placeholder result (same as Stub for now).
        onResult?(STTResult(text: "[parakeet stub transcription]", isPartial: false, confidence: nil))
    }
}
