import AVFoundation

/// Captures raw audio from the default input device and streams PCM buffers
/// to a consumer (typically an STTProvider).
///
/// The service wraps AVAudioEngine and exposes a simple start/stop API.
/// Callers receive audio via the `onBuffer` callback.
final class AudioCaptureService {

    // MARK: - Public types

    /// Delivers a buffer of PCM audio captured from the microphone.
    typealias BufferHandler = (AVAudioPCMBuffer, AVAudioTime) -> Void

    // MARK: - Public callbacks

    /// Called on the audio-engine's real-time thread each time a new buffer
    /// is available. Keep work minimal here—copy the buffer off-thread for
    /// heavier processing.
    var onBuffer: BufferHandler?

    /// Called on the main queue when an error occurs (e.g. device disconnected).
    var onError: ((Error) -> Void)?

    // MARK: - Configuration

    /// Desired sample rate for capture. Whisper expects 16 kHz mono.
    var desiredSampleRate: Double = 16_000

    /// Number of channels (mono = 1).
    var desiredChannelCount: AVAudioChannelCount = 1

    // MARK: - Private state

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning = false

    // MARK: - Lifecycle

    /// Requests microphone permission, configures the audio engine, installs
    /// a tap on the input node, and starts capture.
    ///
    /// - Throws: If the audio session cannot be configured or the engine
    ///           fails to start.
    func start() throws {
        guard !isRunning else { return }

        // TODO: Check & request microphone permission before proceeding.
        //       AVCaptureDevice.requestAccess(for: .audio) is async; consider
        //       making this method async or adding a permission-check step
        //       to the DictationStateMachine.

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        // Build a format that matches what the STT provider expects.
        guard let captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: desiredSampleRate,
            channels: desiredChannelCount,
            interleaved: false
        ) else {
            throw AudioCaptureError.unsupportedFormat
        }

        // Validate that the hardware format has at least one channel.
        guard hardwareFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        // Build a converter from the hardware format to the desired STT format.
        // Installing the tap with the hardware format avoids the
        // "Input HW format and tap format not matching" crash.
        guard let audioConverter = AVAudioConverter(from: hardwareFormat, to: captureFormat) else {
            throw AudioCaptureError.conversionFailed
        }
        self.converter = audioConverter

        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(hardwareFormat.sampleRate * 0.1) // ~100 ms

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) { [weak self] buffer, time in
            guard let self = self, let converter = self.converter else { return }

            let ratio = captureFormat.sampleRate / hardwareFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: outputFrameCapacity) else { return }

            var error: NSError?
            var hasData = true
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if hasData {
                    hasData = false
                    outStatus.pointee = .haveData
                    return buffer
                }
                outStatus.pointee = .noDataNow
                return nil
            }

            if let error = error {
                let reportError = self.onError
                DispatchQueue.main.async { reportError?(error) }
                return
            }

            self.onBuffer?(convertedBuffer, time)
        }

        engine.prepare()
        try engine.start()
        isRunning = true

        // TODO: On macOS, AVAudioSession is unavailable. Monitor device
        //       changes via CoreAudio's AudioObjectAddPropertyListener on
        //       kAudioHardwarePropertyDefaultInputDevice to detect mic
        //       disconnects / switches and notify the state machine.
    }

    /// Stops the audio engine and removes the input tap.
    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
    }
}

// MARK: - Errors

enum AudioCaptureError: Error, LocalizedError {
    case unsupportedFormat
    case noInputDevice
    case interrupted
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "The requested audio format is not supported by the hardware."
        case .noInputDevice:
            return "No audio input device is available."
        case .interrupted:
            return "Audio capture was interrupted by the system."
        case .conversionFailed:
            return "Failed to create audio format converter."
        }
    }
}
