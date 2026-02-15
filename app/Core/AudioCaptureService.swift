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
    /// Specific input device UID to use. If nil or empty, uses system default.
    var inputDeviceUID: String?

    // MARK: - Private state

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning = false

    private var engineConfigObserver: NSObjectProtocol?
    private var defaultInputDeviceListenerInstalled = false
    private var defaultInputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "com.visperflow.audio-listeners", qos: .utility)
    /// Saved original default device UID to restore after capture
    private var originalDefaultDeviceUID: String?

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

        // Resolve input node and format
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        // If a specific device is selected, try to configure the engine to use it
        if let deviceUID = inputDeviceUID, !deviceUID.isEmpty {
            if let deviceID = findAudioDeviceID(byUID: deviceUID) {
                // Save the current default device to restore later
                originalDefaultDeviceUID = getDefaultInputDeviceUID()

                // Configure the input node to use the specific device
                var deviceIDValue = deviceID

                // Set the default input device for the system (temporarily)
                var propertyAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )

                let status = AudioObjectSetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &propertyAddress,
                    0,
                    nil,
                    UInt32(MemoryLayout<AudioDeviceID>.size),
                    &deviceIDValue
                )

                if status == noErr {
                    logger.info("Successfully set input device to: \(deviceUID, privacy: .public)")
                } else {
                    logger.warning("Failed to set input device, using system default: \(status)")
                }
            } else {
                logger.warning("Selected device UID not found: \(deviceUID, privacy: .public), using system default")
            }
        }

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

        // Restore the original default input device if we changed it
        if let originalUID = originalDefaultDeviceUID,
           let deviceID = findAudioDeviceID(byUID: originalUID) {
            var deviceIDValue = deviceID
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &deviceIDValue
            )
            originalDefaultDeviceUID = nil
        }

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

    private func findAudioDeviceID(byUID uid: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return nil }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return nil }

        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var deviceUID: CFString?
            var uidSize = UInt32(MemoryLayout<CFString?>.size)

            status = withUnsafeMutablePointer(to: &deviceUID) { pointer in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, pointer)
            }

            if status == noErr, let deviceUID, (deviceUID as String) == uid {
                return deviceID
            }
        }

        return nil
    }

    private func getDefaultInputDeviceUID() -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceUID: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = withUnsafeMutablePointer(to: &deviceUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                &dataSize,
                pointer
            )
        }

        guard status == noErr, let deviceUID else { return nil }
        return deviceUID as String
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
    case deviceNotFound

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
        case .deviceNotFound:
            return "Selected audio input device not found. Using system default."
        }
    }
}

// MARK: - Audio Input Device

/// Represents an available audio input device.
struct AudioInputDevice: Identifiable, Hashable {
    let id: String  // UID
    let name: String
    let isDefault: Bool

    static func == (lhs: AudioInputDevice, rhs: AudioInputDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Helper to enumerate available audio input devices.
enum AudioDeviceManager {
    /// Returns all available audio input devices.
    static func availableInputDevices() -> [AudioInputDevice] {
        var devices: [AudioInputDevice] = []

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return [] }

        // Get default input device UID
        var defaultDeviceUIDCF: CFString?
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultUIDSize = UInt32(MemoryLayout<CFString?>.size)
        _ = withUnsafeMutablePointer(to: &defaultDeviceUIDCF) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultAddress,
                0,
                nil,
                &defaultUIDSize,
                pointer
            )
        }
        let defaultDeviceUID = (defaultDeviceUIDCF as String?) ?? ""

        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var inputSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize)

            guard status == noErr, inputSize > 0 else { continue }

            let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPointer.deallocate() }

            status = AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &inputSize, bufferListPointer)

            guard status == noErr else { continue }

            let bufferList = bufferListPointer.pointee
            var hasInputChannels = false
            if bufferList.mNumberBuffers > 0 {
                let buffer = bufferList.mBuffers
                if buffer.mNumberChannels > 0 {
                    hasInputChannels = true
                }
            }

            guard hasInputChannels else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var name: CFString?
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            status = withUnsafeMutablePointer(to: &name) { pointer in
                AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, pointer)
            }

            guard status == noErr, let name else { continue }

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var uid: CFString?
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            status = withUnsafeMutablePointer(to: &uid) { pointer in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, pointer)
            }

            guard status == noErr, let uid else { continue }

            let deviceUID = uid as String
            let deviceName = name as String

            devices.append(AudioInputDevice(
                id: deviceUID,
                name: deviceName,
                isDefault: deviceUID == defaultDeviceUID
            ))
        }

        // Sort: default first, then alphabetical
        return devices.sorted { d1, d2 in
            if d1.isDefault { return true }
            if d2.isDefault { return false }
            return d1.name.localizedCaseInsensitiveCompare(d2.name) == .orderedAscending
        }
    }
}
