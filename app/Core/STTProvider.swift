import AVFoundation

/// A speech-to-text result delivered by an ``STTProvider``.
struct STTResult {
    /// The transcribed text for this segment.
    let text: String

    /// `true` while the provider is still refining this segment.
    /// Once `false`, the text is considered final.
    let isPartial: Bool

    /// Confidence score in 0…1 range, if the provider supplies one.
    let confidence: Double?
}

/// Errors that any STT provider may surface.
enum STTError: Error, LocalizedError {
    /// The provider could not authenticate (bad API key, expired token, etc.).
    case authenticationFailed(underlying: Error?)

    /// Network or server-side failure for cloud providers.
    case networkError(underlying: Error)

    /// The audio format fed to the provider is unsupported.
    case unsupportedAudioFormat

    /// Provider-specific error with a free-form message.
    case providerError(message: String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let err):
            return "STT authentication failed: \(err?.localizedDescription ?? "unknown")"
        case .networkError(let err):
            return "STT network error: \(err.localizedDescription)"
        case .unsupportedAudioFormat:
            return "The audio format is not supported by the STT provider."
        case .providerError(let msg):
            return "STT provider error: \(msg)"
        }
    }
}

/// Protocol that every speech-to-text backend must conform to.
///
/// Concrete implementations might include:
///   - `WhisperLocalProvider`  – on-device inference via whisper.cpp
///   - `WhisperAPIProvider`    – OpenAI Whisper REST API
///   - `AppleSpeechProvider`   – Apple's Speech framework
///
/// The protocol is intentionally thin so providers can be swapped at runtime
/// (e.g. user preference or offline fallback).
protocol STTProvider: AnyObject {

    /// Human-readable name shown in settings (e.g. "Whisper (local)").
    var displayName: String { get }

    /// Called each time the ``AudioCaptureService`` produces a new PCM buffer.
    /// Providers should accumulate or stream audio internally.
    ///
    /// - Parameters:
    ///   - buffer: Float32 PCM audio, typically 16 kHz mono.
    ///   - time:   Timestamp of the buffer in the audio timeline.
    func feedAudio(buffer: AVAudioPCMBuffer, time: AVAudioTime)

    /// Signals the provider that dictation has started.
    /// Use this to open a streaming connection or reset internal buffers.
    func beginSession() throws

    /// Signals the provider that dictation has ended.
    /// The provider should finalize any pending transcription and deliver
    /// the last result via ``onResult``.
    func endSession()

    /// Callback delivering incremental or final transcription results.
    var onResult: ((STTResult) -> Void)? { get set }

    /// Callback delivering errors during transcription.
    var onError: ((STTError) -> Void)? { get set }
}

// MARK: - Placeholder implementation (for compile-testing)

// TODO: Remove this stub once a real provider is implemented.
//       This exists solely so the project compiles without a concrete
//       STTProvider.

/// A no-op provider used during development and testing.
final class StubSTTProvider: STTProvider {
    let displayName = "Stub (no-op)"

    var onResult: ((STTResult) -> Void)?
    var onError: ((STTError) -> Void)?

    func feedAudio(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // TODO: Forward buffers to a real STT engine.
    }

    func beginSession() throws {
        // TODO: Initialize provider session.
    }

    func endSession() {
        // Deliver a placeholder result so downstream code exercises the path.
        onResult?(STTResult(text: "[stub transcription]", isPartial: false, confidence: nil))
    }
}
