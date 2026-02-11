import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "ParakeetSTT")

/// STT provider for NVIDIA Parakeet (experimental).
///
/// ONNX Runtime inference is not yet implemented. Selecting this provider
/// will report an actionable error directing the user to choose Apple Speech
/// or wait for a future release.
final class ParakeetSTTProvider: STTProvider {
    let displayName = "NVIDIA Parakeet (experimental)"

    var onResult: ((STTResult) -> Void)?
    var onError: ((STTError) -> Void)?

    private let variant: ModelVariant
    private var sessionActive = false

    init(variant: ModelVariant = .parakeetCTC06B) {
        self.variant = variant
        logger.info("ParakeetSTTProvider initialized with variant: \(variant.id)")
    }

    func feedAudio(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // TODO: Accumulate PCM buffers for batch inference once ONNX Runtime is integrated.
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

        // ONNX inference not yet wired — fail with actionable message.
        throw STTError.providerError(
            message: "Parakeet inference is not yet implemented (experimental). Use Apple Speech for real transcription."
        )
    }

    func endSession() {
        guard sessionActive else {
            logger.warning("endSession called but no session was active — ignoring")
            return
        }
        sessionActive = false
        logger.info("Parakeet session ended")
        // No placeholder output — real inference not implemented.
        onError?(.providerError(message: "Parakeet session ended without inference (not implemented)."))
    }
}
