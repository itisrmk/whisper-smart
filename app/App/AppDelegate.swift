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
    private lazy var initialProviderResolution = STTProviderResolver.resolve(for: STTProviderKind.loadSelection())
    private lazy var sttProvider: STTProvider = initialProviderResolution.provider
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

        // ── Startup permission diagnostics ──
        PermissionDiagnostics.logAll()

        menuBar.install()
        bubblePanel.show()

        publishProviderDiagnostics(initialProviderResolution.diagnostics)

        wireCallbacks()
        observeBindingChanges()
        observeProviderChanges()

        // Request all permissions in the correct order, then activate
        // the hotkey monitor once we know the permission landscape.
        PermissionDiagnostics.requestAllInOrder { [weak self] snap in
            guard let self else { return }
            PermissionDiagnostics.logAll()

            if snap.accessibility.isUsable {
                self.stateMachine.activate()
            } else {
                logger.warning("Accessibility not granted at launch — hotkey monitor deferred")
                self.bubbleState.transition(
                    to: .error,
                    errorDetail: "Accessibility permission required. Grant access in System Settings → Privacy & Security → Accessibility, then use Retry Hotkey Monitor from the menu."
                )
                self.menuBar.updateIcon(for: .error)
                self.menuBar.updateErrorDetail("Accessibility permission not granted")
                // Schedule a retry: accessibility may be granted after the user
                // clicks Allow in System Settings.
                self.scheduleAccessibilityRetry()
            }
        }
    }

    /// Periodically checks if Accessibility was granted after the initial
    /// prompt. Retries hotkey monitor start once permission appears.
    private func scheduleAccessibilityRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            if PermissionDiagnostics.accessibilityStatus().isUsable {
                logger.info("Accessibility permission now granted — starting hotkey monitor")
                self.retryHotkeyMonitor()
            } else if case .error = self.stateMachine.state {
                // Still waiting — keep polling
                self.scheduleAccessibilityRetry()
            }
        }
    }

    /// Public entry point for manually retrying the hotkey monitor
    /// (e.g. from a menu item after granting Accessibility).
    func retryHotkeyMonitor() {
        let snap = PermissionDiagnostics.snapshot()
        if snap.accessibility.isUsable {
            stateMachine.deactivate()
            stateMachine.activate()
            logger.info("Hotkey monitor retry triggered (accessibility=\(snap.accessibility.rawValue))")
        } else {
            let msg = "Accessibility permission still missing. Grant access in System Settings → Privacy & Security → Accessibility."
            bubbleState.transition(to: .error, errorDetail: msg)
            menuBar.updateIcon(for: .error)
            menuBar.updateErrorDetail(msg)
        }
    }

    /// Runs a one-shot recording session without the hotkey.
    /// This is the recovery path when the hotkey monitor cannot start.
    func runOneShotRecording() {
        stateMachine.startOneShotRecording()
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
            let detail = self.errorDetail(for: coreState)
            self.bubbleState.transition(to: uiState, errorDetail: detail)
            self.menuBar.updateIcon(for: uiState)
            if let detail {
                self.menuBar.updateErrorDetail(detail)
            }
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

        menuBar.onRetryHotkeyMonitor = { [weak self] in
            self?.retryHotkeyMonitor()
        }

        menuBar.onOneShotRecording = { [weak self] in
            self?.stateMachine.startOneShotRecording()
        }

        menuBar.onStopOneShotRecording = { [weak self] in
            self?.stateMachine.stopOneShotRecording()
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
            logger.info("Provider changed in settings to kind: \(kind.rawValue, privacy: .public)")
            let resolution = STTProviderResolver.resolve(for: kind)
            self.publishProviderDiagnostics(resolution.diagnostics)
            self.sttProvider = resolution.provider
            logger.info("Replacing state-machine provider with: \(self.sttProvider.displayName, privacy: .public)")
            self.stateMachine.replaceProvider(self.sttProvider)
        }
    }

    private func publishProviderDiagnostics(_ diagnostics: ProviderRuntimeDiagnostics) {
        ProviderRuntimeDiagnosticsStore.shared.publish(diagnostics)
        menuBar.updateProviderDiagnostics(diagnostics)

        logger.info(
            "Provider diagnostics health=\(diagnostics.healthLevel.rawValue, privacy: .public) requested=\(diagnostics.requestedKind.rawValue, privacy: .public) effective=\(diagnostics.effectiveKind.rawValue, privacy: .public)"
        )

        if let fallbackReason = diagnostics.fallbackReason {
            logger.warning("Provider fallback reason: \(fallbackReason, privacy: .public)")
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

    /// Returns the error detail string when core state is `.error`, nil otherwise.
    private func errorDetail(for state: DictationStateMachine.State) -> String? {
        if case .error(let msg) = state { return msg }
        return nil
    }
}
