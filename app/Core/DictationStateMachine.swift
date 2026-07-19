import Foundation
import CoreGraphics
import AVFoundation
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
        /// Final transcript completed and injected; shown briefly before idle.
        case success
        /// A non-recoverable error occurred; UI should display a message.
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.recording, .recording), (.transcribing, .transcribing), (.success, .success):
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
    /// Streaming microphone level (0...1) while recording.
    var onAudioLevelChange: ((CGFloat) -> Void)?
    /// Streaming transcript text (partial + final) during recording/transcribing.
    var onTranscriptChange: ((String) -> Void)?

    // MARK: - Dependencies

    private let hotkeyMonitor: HotkeyMonitoring
    private let audioCapture: AudioCapturing
    private var sttProvider: STTProvider
    private let injector: TextInjecting
    private let postProcessingPipeline: TranscriptPostProcessingPipeline
    private let commandModeRouter: CommandModeRouter
    private let microphoneAuthorizationStatus: () -> AVAuthorizationStatus
    private let requestMicrophoneAccess: (@escaping (Bool) -> Void) -> Void

    /// Timeout work item for the transcribing state. Actual timeout is derived
    /// from the active provider (`sttProvider.transcriptionTimeout`).
    private var transcribingTimeoutWork: DispatchWorkItem?
    private let successDisplayDuration: TimeInterval = 0.45
    private var successResetWork: DispatchWorkItem?
    private var oneShotModePendingStart = false
    private var oneShotModeActive = false
    /// True while the first-run microphone permission dialog is up. If the
    /// user releases the hotkey (or cancels) before answering, the granted
    /// callback must not start a recording nobody can stop.
    private var pendingPermissionRecordingStart = false
    private var silenceAutoStopWork: DispatchWorkItem?
    private var lastDetectedSpeechAt: Date?
    private var detectedSpeechInCurrentRecording = false
    private var sessionStartedAt: Date?
    private var transcribingStartedAt: Date?
    /// True while audio is being captured speculatively between key-down and
    /// hold confirmation (state stays `.idle`, no UI). The confirmed hold
    /// adopts this capture so the first ~300ms of speech isn't lost; an
    /// abandoned tap discards it silently.
    private var speculativeCaptureActive = false
    private var speculativeCaptureStartedAt: Date?

    /// Explicit retry policy: this state machine does not auto-retry failed
    /// dictation sessions. Users must explicitly initiate a new recording.
    private let automaticRetryEnabled = false

    // MARK: - Init

    init(
        hotkeyMonitor: HotkeyMonitoring,
        audioCapture: AudioCapturing,
        sttProvider: STTProvider,
        injector: TextInjecting,
        postProcessingPipeline: TranscriptPostProcessingPipeline,
        commandModeRouter: CommandModeRouter,
        microphoneAuthorizationStatus: @escaping () -> AVAuthorizationStatus = { AudioCaptureService.microphoneAuthorizationStatus() },
        requestMicrophoneAccess: @escaping (@escaping (Bool) -> Void) -> Void = { completion in
            AudioCaptureService.requestMicrophoneAccess(completion: completion)
        }
    ) {
        self.hotkeyMonitor = hotkeyMonitor
        self.audioCapture  = audioCapture
        self.sttProvider   = sttProvider
        self.injector      = injector
        self.postProcessingPipeline = postProcessingPipeline
        self.commandModeRouter = commandModeRouter
        self.microphoneAuthorizationStatus = microphoneAuthorizationStatus
        self.requestMicrophoneAccess = requestMicrophoneAccess

        wireCallbacks()
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        // Key-down (hold not yet confirmed) → start capturing speculatively
        hotkeyMonitor.onPressBegan = { [weak self] in
            self?.handlePressBegan()
        }

        // Tap released before the hold threshold → discard speculative capture
        hotkeyMonitor.onPressAbandoned = { [weak self] in
            self?.handlePressAbandoned()
        }

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

        // Audio levels arrive on the audio engine thread; hop to main so
        // speech-detection state and UI observers are only touched from the
        // same queue as the rest of the state machine.
        audioCapture.onAudioLevel = { [weak self] level in
            DispatchQueue.main.async {
                guard let self else { return }
                self.onAudioLevelChange?(CGFloat(level))
                self.handleAudioLevel(level)
            }
        }

        // Audio error → surface
        audioCapture.onError = { [weak self] error in
            DispatchQueue.main.async {
                logger.error("Audio capture error: \(error.localizedDescription)")
                self?.recoverFromCaptureFailure(message: error.localizedDescription)
            }
        }

        audioCapture.onInterruption = { [weak self] reason in
            DispatchQueue.main.async {
                self?.handleAudioInterruption(reason)
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
                self.cancelTranscribingTimeout()
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
        discardSpeculativeCapture()
        audioCapture.stop()
        cancelTranscribingTimeout()
        cancelSuccessReset()
        cancelSilenceAutoStopWatchdog()
        // Only end the session if we were actively using the provider.
        if state == .recording || state == .transcribing {
            sttProvider.endSession()
        }
        onAudioLevelChange?(0)
        onTranscriptChange?("")
        detectedSpeechInCurrentRecording = false
        pendingPermissionRecordingStart = false
        sessionStartedAt = nil
        transcribingStartedAt = nil
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

        cancelTranscribingTimeout()
        cancelSuccessReset()
        cancelSilenceAutoStopWatchdog()
        discardSpeculativeCapture()
        oneShotModeActive = false
        oneShotModePendingStart = false
        pendingPermissionRecordingStart = false
        detectedSpeechInCurrentRecording = false

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
        guard state == .idle || state == .success || state.isError else {
            logger.warning("One-shot recording: not idle/success/error, ignoring (state=\(String(describing: self.state)))")
            return
        }

        // Reset terminal states so we can attempt recording
        if state == .success || state.isError {
            transition(to: .idle)
        }

        onTranscriptChange?("")
        oneShotModePendingStart = true
        handleHoldStarted()
    }

    /// Ends a one-shot recording session (simulates hotkey release).
    func stopOneShotRecording() {
        oneShotModePendingStart = false
        handleHoldEnded()
    }

    // MARK: - State transitions

    /// Key-down before the hold threshold: start the mic now so speech
    /// spoken during the confirmation window is captured. No state
    /// transition and no UI — an abandoned tap must be invisible.
    private func handlePressBegan() {
        guard state == .idle, !speculativeCaptureActive else { return }
        guard microphoneAuthorizationStatus() == .authorized else { return }

        audioCapture.inputDeviceUID = DictationWorkflowSettings.selectedInputDeviceUID
        do {
            try sttProvider.beginSession()
            try audioCapture.start()
            speculativeCaptureActive = true
            speculativeCaptureStartedAt = Date()
            logger.info("Speculative capture started (awaiting hold confirmation)")
        } catch {
            // Best-effort: the confirmed hold retries via the normal path and
            // surfaces errors properly there.
            logger.info("Speculative capture unavailable: \(error.localizedDescription, privacy: .public)")
            sttProvider.cancelSession()
            audioCapture.stop()
        }
    }

    private func handlePressAbandoned() {
        guard speculativeCaptureActive else { return }
        logger.info("Press abandoned before hold threshold — discarding speculative capture")
        discardSpeculativeCapture()
    }

    private func discardSpeculativeCapture() {
        guard speculativeCaptureActive else { return }
        speculativeCaptureActive = false
        speculativeCaptureStartedAt = nil
        detectedSpeechInCurrentRecording = false
        audioCapture.stop()
        sttProvider.cancelSession()
    }

    private func handleHoldStarted() {
        if state == .success {
            cancelSuccessReset()
            transition(to: .idle)
        }
        if state.isError {
            logger.info("Hold-start received in error state — recovering to idle before recording")
            transition(to: .idle)
        }
        if state == .transcribing {
            // A new hold while the previous transcription is still running
            // means the user wants to dictate again NOW. Cancel the in-flight
            // session instead of silently swallowing the hotkey press.
            logger.info("Hold-start during transcribing — cancelling in-flight transcription")
            cancelInFlightTranscription()
        }
        if state == .recording {
            // A release lost to a tap reset/reinstall can orphan `.recording`;
            // without this branch the press is silently swallowed and only the
            // second press works. Recover and start fresh.
            logger.warning("Hold-start received while already recording — recovering orphaned session")
            cancelSilenceAutoStopWatchdog()
            oneShotModeActive = false
            detectedSpeechInCurrentRecording = false
            audioCapture.stop()
            sttProvider.cancelSession()
            sessionStartedAt = nil
            transcribingStartedAt = nil
            transition(to: .idle)
        }
        guard state == .idle else { return }

        // Pre-flight: check microphone permission before attempting capture.
        let micStatus = microphoneAuthorizationStatus()
        if micStatus == .notDetermined {
            logger.info("Microphone permission not yet determined — requesting")
            pendingPermissionRecordingStart = true
            requestMicrophoneAccess { [weak self] granted in
                guard let self else { return }
                // Released the hotkey (or session was reset) while the dialog
                // was up — do not start a recording nothing will stop.
                guard self.pendingPermissionRecordingStart else {
                    logger.info("Microphone permission resolved after hold ended — not starting recording")
                    return
                }
                self.pendingPermissionRecordingStart = false
                if granted {
                    logger.info("Microphone permission granted")
                    self.beginRecordingSession()
                } else {
                    logger.error("Microphone permission denied by user")
                    self.oneShotModePendingStart = false
                    self.transition(to: .error(AudioCaptureError.microphonePermissionDenied.localizedDescription))
                }
            }
            return
        }

        beginRecordingSession()
    }

    /// Aborts a transcription that is still waiting on the STT provider and
    /// returns the machine to `.idle` so a new recording can start.
    private func cancelInFlightTranscription() {
        cancelTranscribingTimeout()
        sttProvider.cancelSession()
        sessionStartedAt = nil
        transcribingStartedAt = nil
        onTranscriptChange?("")
        transition(to: .idle)
    }

    private func beginRecordingSession() {
        guard state == .idle else { return }

        let providerName = sttProvider.displayName
        var didBeginSTTSession = false
        onTranscriptChange?("")

        // Adopt a speculative capture started at key-down: the mic and STT
        // session are already running with the leading audio in the buffer.
        if speculativeCaptureActive {
            let startedAt = speculativeCaptureStartedAt ?? Date()
            speculativeCaptureActive = false
            speculativeCaptureStartedAt = nil
            oneShotModeActive = oneShotModePendingStart
            oneShotModePendingStart = false
            lastDetectedSpeechAt = Date()
            if oneShotModeActive {
                scheduleSilenceAutoStopWatchdog()
            }
            sessionStartedAt = startedAt
            transcribingStartedAt = nil
            logger.info("Recording session adopted speculative capture (provider: \(providerName, privacy: .public))")
            transition(to: .recording)
            return
        }

        // Set the selected input device before starting capture
        audioCapture.inputDeviceUID = DictationWorkflowSettings.selectedInputDeviceUID

        do {
            logger.info("Starting recording session with provider: \(providerName, privacy: .public)")
            try sttProvider.beginSession()
            didBeginSTTSession = true
            try audioCapture.start()
            oneShotModeActive = oneShotModePendingStart
            oneShotModePendingStart = false
            detectedSpeechInCurrentRecording = false
            lastDetectedSpeechAt = Date()
            if oneShotModeActive {
                scheduleSilenceAutoStopWatchdog()
            }
            sessionStartedAt = Date()
            transcribingStartedAt = nil
            logger.info("Recording session started with provider: \(providerName, privacy: .public)")
            transition(to: .recording)
        } catch {
            if didBeginSTTSession {
                sttProvider.endSession()
            }
            // audioCapture.start() can fail partway (tap installed, input
            // device switched); stop() reverts that partial state.
            audioCapture.stop()
            // A failed one-shot start must not leak its pending flag into the
            // next hotkey hold (which would silently become one-shot mode and
            // auto-stop mid-hold on silence).
            oneShotModePendingStart = false
            logger.error("Failed to start recording with provider \(providerName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            transition(to: .error(error.localizedDescription))
        }
    }

    private func handleHoldEnded() {
        // Hold released while the mic permission dialog was still open:
        // cancel the deferred start instead of leaving it to fire later.
        if pendingPermissionRecordingStart {
            logger.info("Hold ended while awaiting microphone permission — cancelling deferred start")
            pendingPermissionRecordingStart = false
            oneShotModePendingStart = false
            return
        }

        guard state == .recording else { return }

        cancelSilenceAutoStopWatchdog()
        let hadSpeech = detectedSpeechInCurrentRecording
        oneShotModeActive = false
        detectedSpeechInCurrentRecording = false

        audioCapture.stop()
        if let sessionStartedAt {
            let recordMs = Int(Date().timeIntervalSince(sessionStartedAt) * 1000)
            logger.info("Dictation timing: recordingDurationMs=\(recordMs)")
        }

        // If no speech was detected at all, skip transcription entirely.
        // Sending silent audio to the STT provider wastes time and produces
        // no useful output.
        if !hadSpeech {
            logger.info("No speech detected during recording — skipping transcription")
            sttProvider.endSession()
            sessionStartedAt = nil
            transcribingStartedAt = nil
            transition(to: .idle)
            return
        }

        // Transition to .transcribing BEFORE endSession() so that synchronous
        // result delivery (e.g. StubSTTProvider) finds the machine in the
        // correct state.
        transcribingStartedAt = Date()
        transition(to: .transcribing)
        scheduleTranscribingTimeout()
        sttProvider.endSession()
    }

    private func handleSTTResult(_ result: STTResult) {
        guard state == .transcribing || state == .recording else {
            logger.warning("STT result arrived in unexpected state \(String(describing: self.state)), ignoring")
            return
        }

        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let processed = postProcessingPipeline.process(trimmed, isFinal: !result.isPartial)
        onTranscriptChange?(processed)

        if !result.isPartial {
            // A provider can finalize while we are still in .recording (e.g.
            // Apple Speech hitting its recognition limit). Shut capture down
            // so the mic doesn't stay hot after we transition to success.
            if state == .recording {
                cancelSilenceAutoStopWatchdog()
                oneShotModeActive = false
                detectedSpeechInCurrentRecording = false
                audioCapture.stop()
            }
            cancelTranscribingTimeout()
            let finalAt = Date()
            if let transcribingStartedAt {
                let sttMs = Int(finalAt.timeIntervalSince(transcribingStartedAt) * 1000)
                logger.info("Dictation timing: transcribingDurationMs=\(sttMs)")
            }
            if let sessionStartedAt {
                let totalMs = Int(finalAt.timeIntervalSince(sessionStartedAt) * 1000)
                logger.info("Dictation timing: endToEndMs=\(totalMs)")
            }

            let routingDecision = commandModeRouter.route(text: processed, isFinal: true)
            if !routingDecision.textForInjection.isEmpty {
                if routingDecision.mode == .commandCandidate {
                    logger.info("Command-mode scaffold matched candidate; using passthrough injection for now")
                }
                logger.info("Injecting transcription (\(routingDecision.textForInjection.count) chars)")
                injector.inject(text: routingDecision.textForInjection)
            } else {
                logger.info("Transcription empty after post-processing/routing, skipping injection")
            }
            sessionStartedAt = nil
            transcribingStartedAt = nil
            transition(to: .success)
            scheduleSuccessReset()
        }
    }

    private func handleAudioLevel(_ level: Float) {
        // Speech during the speculative window (before the hold confirms)
        // counts too — it's the same recording once adopted.
        guard state == .recording || speculativeCaptureActive else { return }
        if level >= 0.08 {
            detectedSpeechInCurrentRecording = true
            lastDetectedSpeechAt = Date()
        }
    }

    private func scheduleSilenceAutoStopWatchdog() {
        cancelSilenceAutoStopWatchdog()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.state == .recording, self.oneShotModeActive else { return }

            let now = Date()
            let lastVoice = self.lastDetectedSpeechAt ?? now
            let elapsed = now.timeIntervalSince(lastVoice)
            let baseTimeout = DictationWorkflowSettings.silenceTimeoutSeconds
            let timeout: TimeInterval
            if self.detectedSpeechInCurrentRecording {
                timeout = baseTimeout
            } else {
                // Faster endpoint when no speech has been detected at all.
                timeout = min(baseTimeout, max(0.45, baseTimeout * 0.7))
            }

            if elapsed >= timeout {
                logger.info("One-shot silence timeout reached (\(elapsed)s >= \(timeout)s, detectedSpeech=\(self.detectedSpeechInCurrentRecording)); auto-stopping recording")
                self.handleHoldEnded()
            } else {
                self.scheduleSilenceAutoStopWatchdog()
            }
        }

        silenceAutoStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
    }

    private func cancelSilenceAutoStopWatchdog() {
        silenceAutoStopWork?.cancel()
        silenceAutoStopWork = nil
    }

    private func handleAudioInterruption(_ reason: AudioCaptureService.InterruptionReason) {
        logger.warning("Handling audio interruption reason=\(reason.rawValue, privacy: .public) state=\(String(describing: self.state), privacy: .public)")
        let message: String
        switch reason {
        case .engineConfigurationChanged:
            message = "Audio capture was interrupted by a system audio reconfiguration. Dictation stopped safely. Press Start Dictation to retry."
        case .defaultInputDeviceChanged:
            message = "Input device changed while recording. Dictation stopped safely. Press Start Dictation to retry with the new microphone."
        }
        recoverFromCaptureFailure(message: message)
    }

    private func recoverFromCaptureFailure(message: String) {
        cancelTranscribingTimeout()
        cancelSuccessReset()
        cancelSilenceAutoStopWatchdog()
        discardSpeculativeCapture()
        oneShotModeActive = false
        oneShotModePendingStart = false
        pendingPermissionRecordingStart = false
        detectedSpeechInCurrentRecording = false
        sessionStartedAt = nil
        transcribingStartedAt = nil

        if state == .recording || state == .transcribing {
            sttProvider.endSession()
        }

        if automaticRetryEnabled {
            logger.warning("Automatic retry is enabled, but this build should not use automatic retries")
        }

        transition(to: .error(message))
    }

    private func transition(to newState: State) {
        if newState != .success {
            cancelSuccessReset()
        }
        logger.log("State transition: \(String(describing: self.state)) → \(String(describing: newState))")
        state = newState
    }

    private func scheduleSuccessReset() {
        cancelSuccessReset()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .success else { return }
            self.transition(to: .idle)
        }
        successResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + successDisplayDuration, execute: work)
    }

    private func cancelSuccessReset() {
        successResetWork?.cancel()
        successResetWork = nil
    }

    // MARK: - Transcribing Timeout

    private func scheduleTranscribingTimeout() {
        cancelTranscribingTimeout()
        let timeout = max(10, sttProvider.transcriptionTimeout)
        let providerName = sttProvider.displayName
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .transcribing else { return }
            logger.error("Transcribing timeout (\(timeout)s) for provider \(providerName, privacy: .public) — STT provider did not respond, recovering to error")
            // Cancel the hung session so the provider's in-flight flag clears;
            // otherwise the next beginSession throws ("still running") and the
            // hotkey appears dead until the stale request finally lands.
            self.sttProvider.cancelSession()
            self.transition(to: .error("Transcription timed out while using \(providerName). Please try again."))
        }
        transcribingTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func cancelTranscribingTimeout() {
        transcribingTimeoutWork?.cancel()
        transcribingTimeoutWork = nil
    }
}
