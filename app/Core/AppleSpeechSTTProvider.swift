import AVFoundation
import Speech
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "AppleSpeechSTT")

/// Real STT provider backed by Apple's Speech framework.
///
/// Uses `SFSpeechRecognizer` with an `SFSpeechAudioBufferRecognitionRequest`
/// to perform on-device (or hybrid) speech recognition. Buffers from
/// `AudioCaptureService` are appended directly to the recognition request.
final class AppleSpeechSTTProvider: STTProvider {
    let displayName = "Apple Speech (on-device)"

    var onResult: ((STTResult) -> Void)?
    var onError: ((STTError) -> Void)?

    private let recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionActive = false

    init(locale: Locale = .current) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        logger.info("AppleSpeechSTTProvider initialized with locale: \(locale.identifier)")
    }

    // MARK: - Permission helpers

    /// Current authorization status for speech recognition.
    static func authorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// Request speech recognition authorization. Calls completion on main queue.
    static func requestAuthorization(completion: @escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status) }
        }
    }

    // MARK: - STTProvider

    func beginSession() throws {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw STTError.providerError(
                message: "Speech recognizer unavailable. Check that the language is supported and the device has internet for first use."
            )
        }

        let authStatus = SFSpeechRecognizer.authorizationStatus()
        guard authStatus == .authorized else {
            throw STTError.providerError(
                message: "Speech recognition not authorized (status: \(authStatus.rawValue)). Grant permission in System Settings → Privacy & Security → Speech Recognition."
            )
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        // Prefer on-device recognition when available (macOS 13+/iOS 13+).
        if #available(macOS 13, *) {
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        }
        request.shouldReportPartialResults = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                // Ignore cancellation errors when we intentionally stopped.
                let nsError = error as NSError
                if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                    // "kAFAssistantErrorDomain 216" = request cancelled, expected on endSession.
                    return
                }
                if !self.sessionActive {
                    return
                }
                logger.error("Recognition error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onError?(.providerError(message: error.localizedDescription))
                }
                return
            }

            guard let result = result else { return }

            let text = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            let confidence: Double? = result.bestTranscription.segments.last.map {
                Double($0.confidence)
            }

            logger.info("Recognition result (final=\(isFinal), len=\(text.count))")

            DispatchQueue.main.async {
                self.onResult?(STTResult(
                    text: text,
                    isPartial: !isFinal,
                    confidence: confidence
                ))
            }
        }

        recognitionRequest = request
        sessionActive = true
        logger.info("Apple Speech session started")
    }

    func feedAudio(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        recognitionRequest?.append(buffer)
    }

    func endSession() {
        guard sessionActive else {
            logger.warning("endSession called but no session was active — ignoring")
            return
        }
        sessionActive = false

        // Signal end of audio; the recognition task will deliver a final result.
        recognitionRequest?.endAudio()
        logger.info("Apple Speech session ended, waiting for final result")
    }
}
