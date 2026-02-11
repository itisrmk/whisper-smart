import AppKit
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "AppDelegate")

/// The NSApplicationDelegate that wires together the menu bar,
/// floating bubble, settings window, and the core dictation pipeline.
///
/// Owns the `DictationStateMachine` and bridges its state changes
/// to the UI layer through `BubbleStateSubject`.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - UI

    private let bubbleState = BubbleStateSubject()

    private lazy var menuBar = MenuBarController(stateSubject: bubbleState)
    private lazy var bubblePanel = BubblePanelController(stateSubject: bubbleState)
    private lazy var settingsWindow = SettingsWindowController()

    // MARK: - Core

    private lazy var hotkeyMonitor = HotkeyMonitor(binding: HotkeyBinding.load())
    private lazy var audioCapture = AudioCaptureService()
    private lazy var sttProvider: STTProvider = Self.makeProvider(for: STTProviderKind.loadSelection())
    private lazy var injector = ClipboardInjector()

    private lazy var stateMachine = DictationStateMachine(
        hotkeyMonitor: hotkeyMonitor,
        audioCapture: audioCapture,
        sttProvider: sttProvider,
        injector: injector
    )

    private var bindingObserver: NSObjectProtocol?
    private var providerObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon
        NSApp.setActivationPolicy(.accessory)

        // Proactively prompt for Accessibility permission if not yet granted.
        // This surfaces the system dialog early rather than failing silently
        // when the event tap is first installed.
        if !HotkeyMonitor.checkAccessibilityTrust(promptIfNeeded: true) {
            logger.warning("Accessibility trust not yet granted — hotkey monitoring may fail until approved")
        }

        // Pre-request microphone permission so it's ready when the user
        // first holds the hotkey (avoids a delay on first dictation).
        if AudioCaptureService.microphoneAuthorizationStatus() == .notDetermined {
            AudioCaptureService.requestMicrophoneAccess { granted in
                logger.info("Microphone permission prompt result: \(granted ? "granted" : "denied")")
            }
        }

        // Pre-request speech recognition permission for Apple Speech provider.
        if AppleSpeechSTTProvider.authorizationStatus() == .notDetermined {
            AppleSpeechSTTProvider.requestAuthorization { status in
                logger.info("Speech recognition permission result: \(status.rawValue)")
            }
        }

        menuBar.install()
        bubblePanel.show()

        wireCallbacks()
        observeBindingChanges()
        observeProviderChanges()
        stateMachine.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stateMachine.deactivate()
        if let observer = bindingObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = providerObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        // Bridge DictationStateMachine.State → BubbleState for UI
        stateMachine.onStateChange = { [weak self] coreState in
            guard let self else { return }
            let uiState = self.mapCoreState(coreState)
            self.bubbleState.transition(to: uiState)
            self.menuBar.updateIcon(for: uiState)
        }

        // Menu bar "Start/Stop Dictation" toggles the state machine
        menuBar.onToggleDictation = { [weak self] in
            guard let self else { return }
            if self.stateMachine.state == .idle {
                // Manually trigger a hold-start for menu-driven activation.
                // In normal use the hotkey monitor drives this.
                self.stateMachine.activate()
            } else {
                self.stateMachine.deactivate()
            }
        }

        menuBar.onOpenSettings = { [weak self] in
            self?.settingsWindow.showSettings()
        }

        menuBar.onQuit = {
            NSApp.terminate(nil)
        }

        bubbleState.onTap = { [weak self] in
            self?.menuBar.onToggleDictation?()
        }
    }

    /// Listens for `.hotkeyBindingDidChange` from Settings and hot-swaps
    /// the monitor's binding without restarting the state machine.
    private func observeBindingChanges() {
        bindingObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyBindingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let data = notification.userInfo?["binding"] as? Data,
                  let binding = HotkeyBinding.fromUserInfo(data) else {
                logger.warning("hotkeyBindingDidChange: failed to decode binding from userInfo")
                return
            }
            logger.info("Hotkey binding updated to: \(binding.displayString)")
            self?.hotkeyMonitor.updateBinding(binding)
        }
    }

    /// Listens for `.sttProviderDidChange` from Settings and rebuilds
    /// the state machine with the newly selected provider.
    private func observeProviderChanges() {
        providerObserver = NotificationCenter.default.addObserver(
            forName: .sttProviderDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let kind = STTProviderKind.loadSelection()
            logger.info("Provider changed to: \(kind.rawValue)")
            self.sttProvider = Self.makeProvider(for: kind)
            self.stateMachine.replaceProvider(self.sttProvider)
        }
    }

    /// Factory that returns the concrete ``STTProvider`` for a given kind.
    private static func makeProvider(for kind: STTProviderKind) -> STTProvider {
        switch kind {
        case .appleSpeech:
            logger.info("Creating AppleSpeechSTTProvider")
            return AppleSpeechSTTProvider()
        case .parakeet:
            guard let variant = kind.defaultVariant else {
                logger.error("No model variant available for \(kind.rawValue) — falling back to Apple Speech")
                return AppleSpeechSTTProvider()
            }
            logger.info("Creating ParakeetSTTProvider (experimental), model status: \(variant.validationStatus)")
            return ParakeetSTTProvider(variant: variant)
        case .whisper:
            logger.warning("Whisper not yet implemented — falling back to Apple Speech")
            return AppleSpeechSTTProvider()
        case .openaiAPI:
            logger.warning("OpenAI API not yet implemented — falling back to Apple Speech")
            return AppleSpeechSTTProvider()
        case .stub:
            logger.info("Creating StubSTTProvider (testing only)")
            return StubSTTProvider()
        }
    }

    // MARK: - State Mapping

    /// Maps the core `DictationStateMachine.State` to the UI `BubbleState`.
    private func mapCoreState(_ state: DictationStateMachine.State) -> BubbleState {
        switch state {
        case .idle:         return .idle
        case .recording:    return .listening
        case .transcribing: return .transcribing
        case .error:        return .error
        }
    }
}
