import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "ParakeetSTT")

/// STT provider for NVIDIA Parakeet.
///
/// Today this delivers a fixed placeholder result. Once the ONNX Runtime
/// integration is wired up, this class will load the Parakeet model from
/// disk and run real inference.
final class ParakeetSTTProvider: STTProvider {
    let displayName = "NVIDIA Parakeet (local)"

    var onResult: ((STTResult) -> Void)?
    var onError: ((STTError) -> Void)?

    private let variant: ModelVariant
    private var sessionActive = false

    init(variant: ModelVariant = .parakeetCTC06B) {
        self.variant = variant
        logger.info("ParakeetSTTProvider initialized with variant: \(variant.id)")
    }

    func feedAudio(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // TODO: Accumulate PCM buffers for batch inference.
    }

    func beginSession() throws {
        // Validate the model file exists and passes integrity checks.
        guard let modelURL = variant.localURL else {
            throw STTError.providerError(
                message: "Cannot resolve model path. Application Support directory unavailable."
            )
        }

        guard variant.isDownloaded else {
            let status = variant.validationStatus
            logger.error("Model not ready at beginSession: \(status), path: \(modelURL.path)")
            throw STTError.providerError(
                message: "Parakeet model not ready (\(status)). Download it in Settings → Provider."
            )
        }

        logger.info("Parakeet session started, model at: \(modelURL.path)")
        sessionActive = true
        // TODO: Load ONNX model from modelURL for real inference.
    }

    func endSession() {
        defer { sessionActive = false }
        logger.info("Parakeet session ended")
        // Deliver a placeholder result (same as Stub for now).
        onResult?(STTResult(text: "[parakeet stub transcription]", isPartial: false, confidence: nil))
    }
}
