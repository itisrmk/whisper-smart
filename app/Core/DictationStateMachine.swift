import Foundation
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "DictationSM")

/// Central coordinator that ties together hotkey detection, audio capture,
/// speech-to-text, and text injection into a single dictation lifecycle.
///
/// ## State diagram
/// ```
///  ┌──────┐  hold started   ┌───────────┐  hold ended   ┌──────────────┐
///  │ Idle │ ───────────────▶ │ Recording │ ────────────▶ │ Transcribing │
///  └──────┘                  └───────────┘               └──────┬───────┘
///      ▲                                                        │
///      │              result received / error                   │
///      └────────────────────────────────────────────────────────┘
/// ```
final class DictationStateMachine {

    // MARK: - State

    enum State: Equatable {
        /// Waiting for the user to press-and-hold the hotkey.
        case idle
        /// Hotkey is held; audio is being captured and fed to the STT provider.
        case recording
        /// Hotkey released; waiting for the STT provider to deliver final text.
        case transcribing
        /// A non-recoverable error occurred; UI should display a message.
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.recording, .recording), (.transcribing, .transcribing):
                return true
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }

        var isError: Bool {
            if case .error = self { return true }
            return false
        }
    }

    /// The machine's current state. Observable by the UI layer.
    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    // MARK: - Callbacks

    /// Notifies observers (typically the UI) whenever the state changes.
    var onStateChange: ((State) -> Void)?

    // MARK: - Dependencies

    private let hotkeyMonitor: HotkeyMonitor
    private let audioCapture: AudioCaptureService
    private var sttProvider: STTProvider
    private let injector: ClipboardInjector

    // MARK: - Init

    init(
        hotkeyMonitor: HotkeyMonitor,
        audioCapture: AudioCaptureService,
        sttProvider: STTProvider,
        injector: ClipboardInjector
    ) {
        self.hotkeyMonitor = hotkeyMonitor
        self.audioCapture  = audioCapture
        self.sttProvider   = sttProvider
        self.injector      = injector

        wireCallbacks()
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        // Hotkey hold started → begin recording
        hotkeyMonitor.onHoldStarted = { [weak self] in
            self?.handleHoldStarted()
        }

        // Hotkey released → stop recording, begin transcription
        hotkeyMonitor.onHoldEnded = { [weak self] in
            self?.handleHoldEnded()
        }

        // Event tap creation failed → surface to UI
        hotkeyMonitor.onStartFailed = { [weak self] error in
            logger.error("Hotkey monitor start failed: \(error.localizedDescription)")
            self?.transition(to: .error(error.localizedDescription))
        }

        // Audio buffer → feed to STT
        audioCapture.onBuffer = { [weak self] buffer, time in
            self?.sttProvider.feedAudio(buffer: buffer, time: time)
        }

        // Audio error → surface
        audioCapture.onError = { [weak self] error in
            DispatchQueue.main.async {
                logger.error("Audio capture error: \(error.localizedDescription)")
                self?.transition(to: .error(error.localizedDescription))
            }
        }

        wireSTTCallbacks(for: sttProvider)
    }

    private func wireSTTCallbacks(for provider: STTProvider) {
        // STT result → inject text
        provider.onResult = { [weak self, weak provider] result in
            DispatchQueue.main.async {
                guard let self, let provider else { return }
                guard self.sttProvider === provider else {
                    logger.warning("Ignoring STT result from stale provider: \(provider.displayName, privacy: .public)")
                    return
                }
                logger.info("STT result received from provider \(provider.displayName, privacy: .public) (partial=\(result.isPartial), len=\(result.text.count))")
                self.handleSTTResult(result)
            }
        }

        // STT error → surface
        provider.onError = { [weak self, weak provider] error in
            DispatchQueue.main.async {
                guard let self, let provider else { return }
                guard self.sttProvider === provider else {
                    logger.warning("Ignoring STT error from stale provider: \(provider.displayName, privacy: .public)")
                    return
                }
                logger.error("STT provider error from \(provider.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.transition(to: .error(error.localizedDescription))
            }
        }
    }

    private func clearSTTCallbacks(for provider: STTProvider) {
        provider.onResult = nil
        provider.onError = nil
    }

    // MARK: - Lifecycle

    /// Call once at app launch to start monitoring the hotkey.
    func activate() {
        logger.info("Activating dictation state machine")
        hotkeyMonitor.start()
    }

    /// Call at app termination or when disabling dictation.
    func deactivate() {
        logger.info("Deactivating dictation state machine (current state: \(String(describing: self.state)))")
        hotkeyMonitor.stop()
        audioCapture.stop()
        // Only end the session if we were actively using the provider.
        if state == .recording || state == .transcribing {
            sttProvider.endSession()
        }
        transition(to: .idle)
    }

    /// Hot-swap the STT provider immediately (e.g. user changed provider in Settings).
    /// If a session was in-flight or the machine was in an error state, this
    /// method force-resets the machine to `.idle` so the next hotkey hold can
    /// start with the new provider.
    func replaceProvider(_ newProvider: STTProvider) {
        let oldProvider = sttProvider
        let oldProviderName = oldProvider.displayName
        let newProviderName = newProvider.displayName
        let priorState = state
        let isSameInstance = (oldProvider === newProvider)

        logger.info("Replacing STT provider \(oldProviderName, privacy: .public) → \(newProviderName, privacy: .public) (state=\(String(describing: priorState), privacy: .public))")

        if isSameInstance {
            if priorState != .idle {
                logger.info("Provider unchanged; resetting state to idle from \(String(describing: priorState), privacy: .public)")
                transition(to: .idle)
            }
            return
        }

        if priorState == .recording {
            audioCapture.stop()
            oldProvider.endSession()
        } else if priorState == .transcribing {
            oldProvider.endSession()
        }

        clearSTTCallbacks(for: oldProvider)
        sttProvider = newProvider

        wireSTTCallbacks(for: newProvider)

        if priorState != .idle {
            transition(to: .idle)
        }
    }

    /// Starts a one-shot recording session bypassing the hotkey monitor.
    /// Used as a recovery path when the hotkey event tap cannot be created
    /// (e.g. Accessibility permission missing for unsigned binaries).
    ///
    /// The caller is responsible for calling `stopOneShotRecording()` to end it.
    func startOneShotRecording() {
        guard state == .idle || state.isError else {
            logger.warning("One-shot recording: not idle/error, ignoring (state=\(String(describing: self.state)))")
            return
        }

        // Reset error state so we can attempt recording
        if state.isError {
            transition(to: .idle)
        }

        handleHoldStarted()
    }

    /// Ends a one-shot recording session (simulates hotkey release).
    func stopOneShotRecording() {
        handleHoldEnded()
    }

    // MARK: - State transitions

    private func handleHoldStarted() {
        guard state == .idle else { return }

        // Pre-flight: check microphone permission before attempting capture.
        let micStatus = AudioCaptureService.microphoneAuthorizationStatus()
        if micStatus == .notDetermined {
            logger.info("Microphone permission not yet determined — requesting")
            AudioCaptureService.requestMicrophoneAccess { [weak self] granted in
                if granted {
                    logger.info("Microphone permission granted")
                    self?.beginRecordingSession()
                } else {
                    logger.error("Microphone permission denied by user")
                    self?.transition(to: .error(AudioCaptureError.microphonePermissionDenied.localizedDescription))
                }
            }
            return
        }

        beginRecordingSession()
    }

    private func beginRecordingSession() {
        guard state == .idle else { return }

        let providerName = sttProvider.displayName
        var didBeginSTTSession = false

        do {
            logger.info("Starting recording session with provider: \(providerName, privacy: .public)")
            try sttProvider.beginSession()
            didBeginSTTSession = true
            try audioCapture.start()
            logger.info("Recording session started with provider: \(providerName, privacy: .public)")
            transition(to: .recording)
        } catch {
            if didBeginSTTSession {
                sttProvider.endSession()
            }
            logger.error("Failed to start recording with provider \(providerName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            transition(to: .error(error.localizedDescription))
        }
    }

    private func handleHoldEnded() {
        guard state == .recording else { return }

        audioCapture.stop()
        // Transition to .transcribing BEFORE endSession() so that synchronous
        // result delivery (e.g. StubSTTProvider) finds the machine in the
        // correct state.
        transition(to: .transcribing)
        sttProvider.endSession()
    }

    private func handleSTTResult(_ result: STTResult) {
        guard state == .transcribing || state == .recording else {
            logger.warning("STT result arrived in unexpected state \(String(describing: self.state)), ignoring")
            return
        }

        if !result.isPartial {
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                logger.info("Injecting transcription (\(trimmed.count) chars)")
                injector.inject(text: trimmed)
            } else {
                logger.info("Transcription empty after trim, skipping injection")
            }
            transition(to: .idle)
        }
        // TODO: Surface partial results to the UI overlay so the user
        //       can see live transcription while still holding the key.
    }

    private func transition(to newState: State) {
        logger.info("State transition: \(String(describing: self.state)) → \(String(describing: newState))")
        state = newState
    }
}
