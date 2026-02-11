import Foundation

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

        // Audio buffer → feed to STT
        audioCapture.onBuffer = { [weak self] buffer, time in
            self?.sttProvider.feedAudio(buffer: buffer, time: time)
        }

        // Audio error → surface
        audioCapture.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.transition(to: .error(error.localizedDescription))
            }
        }

        wireSTTCallbacks()
    }

    private func wireSTTCallbacks() {
        // STT result → inject text
        sttProvider.onResult = { [weak self] result in
            DispatchQueue.main.async {
                self?.handleSTTResult(result)
            }
        }

        // STT error → surface
        sttProvider.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.transition(to: .error(error.localizedDescription))
            }
        }
    }

    // MARK: - Lifecycle

    /// Call once at app launch to start monitoring the hotkey.
    func activate() {
        hotkeyMonitor.start()
    }

    /// Call at app termination or when disabling dictation.
    func deactivate() {
        hotkeyMonitor.stop()
        audioCapture.stop()
        sttProvider.endSession()
        transition(to: .idle)
    }

    /// Hot-swap the STT provider while idle (e.g. user changed provider in Settings).
    func replaceProvider(_ newProvider: STTProvider) {
        guard state == .idle else { return }
        sttProvider = newProvider
        wireSTTCallbacks()
    }

    // MARK: - State transitions

    private func handleHoldStarted() {
        guard state == .idle else { return }

        do {
            try sttProvider.beginSession()
            try audioCapture.start()
            transition(to: .recording)
        } catch {
            transition(to: .error(error.localizedDescription))
        }
    }

    private func handleHoldEnded() {
        guard state == .recording else { return }

        audioCapture.stop()
        sttProvider.endSession()
        transition(to: .transcribing)
    }

    private func handleSTTResult(_ result: STTResult) {
        guard state == .transcribing || state == .recording else { return }

        if !result.isPartial {
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                injector.inject(text: trimmed)
            }
            transition(to: .idle)
        }
        // TODO: Surface partial results to the UI overlay so the user
        //       can see live transcription while still holding the key.
    }

    private func transition(to newState: State) {
        state = newState
    }
}
