import AVFoundation
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "AudioCapture")

/// Captures raw audio from the default input device and streams PCM buffers
/// to a consumer (typically an STTProvider).
final class AudioCaptureService {

    // MARK: - Public types

    typealias BufferHandler = (AVAudioPCMBuffer, AVAudioTime) -> Void

    enum InterruptionReason: String {
        case engineConfigurationChanged = "engineConfigurationChanged"
        case defaultInputDeviceChanged = "defaultInputDeviceChanged"
    }

    // MARK: - Public callbacks

    var onBuffer: BufferHandler?
    var onError: ((Error) -> Void)?
    /// Normalized input amplitude (0...1), computed from converted mono PCM.
    var onAudioLevel: ((Float) -> Void)?

    /// Called on main queue when capture is interrupted by audio engine
    /// reconfiguration or input-device changes.
    var onInterruption: ((InterruptionReason) -> Void)?

    // MARK: - Configuration

    var desiredSampleRate: Double = 16_000
    var desiredChannelCount: AVAudioChannelCount = 1

    // MARK: - Private state

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning = false

    private var engineConfigObserver: NSObjectProtocol?
    private var defaultInputDeviceListenerInstalled = false
    private var defaultInputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "com.visperflow.audio-listeners", qos: .utility)

    // MARK: - Lifecycle

    deinit {
        unregisterInterruptionObservers()
    }

    static func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func start() throws {
        guard !isRunning else { return }

        let authStatus = Self.microphoneAuthorizationStatus()
        guard authStatus == .authorized else {
            logger.error("Microphone access not authorized (status: \(authStatus.rawValue))")
            throw AudioCaptureError.microphonePermissionDenied
        }
        logger.info("Microphone authorized, starting capture")

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard let captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: desiredSampleRate,
            channels: desiredChannelCount,
            interleaved: false
        ) else {
            throw AudioCaptureError.unsupportedFormat
        }

        guard hardwareFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        guard let audioConverter = AVAudioConverter(from: hardwareFormat, to: captureFormat) else {
            throw AudioCaptureError.conversionFailed
        }
        self.converter = audioConverter

        registerInterruptionObservers()

        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(hardwareFormat.sampleRate * 0.1)

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

            if let level = Self.normalizedLevel(from: convertedBuffer) {
                self.onAudioLevel?(level)
            }
            self.onBuffer?(convertedBuffer, time)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else {
            unregisterInterruptionObservers()
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
        unregisterInterruptionObservers()
    }

    // MARK: - Interruption observers

    private func registerInterruptionObservers() {
        if engineConfigObserver == nil {
            engineConfigObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                self?.handleInterruption(.engineConfigurationChanged)
            }
        }

        installDefaultInputDeviceListenerIfNeeded()
    }

    private func unregisterInterruptionObservers() {
        if let engineConfigObserver {
            NotificationCenter.default.removeObserver(engineConfigObserver)
            self.engineConfigObserver = nil
        }
        removeDefaultInputDeviceListenerIfNeeded()
    }

    private func handleInterruption(_ reason: InterruptionReason) {
        guard isRunning else { return }

        logger.warning("Audio interruption detected: \(reason.rawValue, privacy: .public)")
        stop()
        DispatchQueue.main.async { [onInterruption] in
            onInterruption?(reason)
        }
    }

    private func installDefaultInputDeviceListenerIfNeeded() {
        guard !defaultInputDeviceListenerInstalled else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleInterruption(.defaultInputDeviceChanged)
        }
        defaultInputDeviceListenerBlock = listener

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            listener
        )

        if status == noErr {
            defaultInputDeviceListenerInstalled = true
        } else {
            defaultInputDeviceListenerBlock = nil
            logger.error("Failed to install default-input listener (status=\(status))")
        }
    }

    private func removeDefaultInputDeviceListenerIfNeeded() {
        guard defaultInputDeviceListenerInstalled else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard let listener = defaultInputDeviceListenerBlock else {
            defaultInputDeviceListenerInstalled = false
            return
        }

        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            listener
        )

        if status != noErr {
            logger.error("Failed to remove default-input listener (status=\(status))")
        }

        defaultInputDeviceListenerInstalled = false
        defaultInputDeviceListenerBlock = nil
    }

    private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float? {
        guard let data = buffer.floatChannelData?[0] else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = data[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameCount))
        // Map ~-50 dB...0 dB RMS into 0...1 for responsive UI motion.
        let db = 20 * log10(max(rms, 0.000_01))
        let normalized = (db + 50) / 50
        return min(max(normalized, 0), 1)
    }
}

// MARK: - Errors

enum AudioCaptureError: Error, LocalizedError {
    case unsupportedFormat
    case noInputDevice
    case interrupted
    case conversionFailed
    case microphonePermissionDenied

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
        case .microphonePermissionDenied:
            return "Microphone access denied — grant permission in System Settings → Privacy & Security → Microphone."
        }
    }
}
