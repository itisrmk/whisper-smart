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
    private lazy var topCenterOverlayPanel = TopCenterOverlayPanelController(stateSubject: bubbleState)
    private lazy var settingsWindow = SettingsWindowController()

    // MARK: - Core

    private lazy var hotkeyMonitor = HotkeyMonitor(binding: HotkeyBinding.load())
    private lazy var audioCapture = AudioCaptureService()
    private lazy var initialProviderResolution = STTProviderResolver.resolve(for: STTProviderKind.loadSelection())
    private lazy var sttProvider: STTProvider = initialProviderResolution.provider
    private lazy var injector = ClipboardInjector()
    private lazy var postProcessingPipeline = TranscriptPostProcessingPipeline(
        processors: [
            VoiceCommandFormattingProcessor(),
            BaselineFillerWordTrimmer(),
            BaselineSpacingAndPunctuationNormalizer(),
            SmartSentenceCasingProcessor(),
            CorrectionDictionaryProcessor(),
            SnippetExpansionProcessor(),
            AppStyleProfileProcessor(),
            DeveloperDictationProcessor(),
        ],
        isEnabled: { DictationFeatureFlags.postProcessingPipelineEnabled }
    )
    private lazy var commandModeRouter = FeatureFlaggedCommandModeRouter(
        isEnabled: { DictationFeatureFlags.commandModeScaffoldEnabled }
    )

    private lazy var stateMachine = DictationStateMachine(
        hotkeyMonitor: hotkeyMonitor,
        audioCapture: audioCapture,
        sttProvider: sttProvider,
        injector: injector,
        postProcessingPipeline: postProcessingPipeline,
        commandModeRouter: commandModeRouter
    )

    private var bindingObserver: NSObjectProtocol?
    private var providerObserver: NSObjectProtocol?
    private var parakeetBootstrapObserver: NSObjectProtocol?
    private var parakeetModelSourceObserver: NSObjectProtocol?
    private var modelDownloadObserver: NSObjectProtocol?
    private var transcriptLogObserver: NSObjectProtocol?
    private var userDefaultsObserver: NSObjectProtocol?

    private let recordingSoundPlayer = RecordingSoundPlayer.shared
    private var previousCoreState: DictationStateMachine.State = .idle

    private var accessibilityRetryWork: DispatchWorkItem?
    private var accessibilityRetryAttempt = 0
    private let accessibilityRetryDelay: TimeInterval = 2.5
    private var pendingHotkeyBootstrap = false

    private var recordStartAt: Date?
    private var transcribeStartAt: Date?
    private var recordingDurationMsForLog: Int?
    private var latestTranscriptForLog: String = ""
    private var activeAppNameForLog: String = "Unknown"
    private var activeProviderNameForLog: String = ""
    private var usesProviderFallback = false
    private var healthBadgeLabel = ""
    private var activityBadgeLabel = ""
    private var deferredProviderRefresh = false
    private var lastObservedParakeetModelReady: Bool?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon
        NSApp.setActivationPolicy(.accessory)

        // ── Startup permission diagnostics ──
        PermissionDiagnostics.logAll()

        // ── Initialize update manager ──
        UpdateManager.start()

        menuBar.install()
        menuBar.updateDictationAction(for: stateMachine.state)
        updateBubbleVisibility(for: stateMachine.state)

        publishProviderDiagnostics(initialProviderResolution.diagnostics)

        wireCallbacks()
        observeBindingChanges()
        observeProviderChanges()
        observeParakeetBootstrapChanges()
        observeParakeetModelSourceChanges()
        observeModelDownloadChanges()
        observeTranscriptLogActions()
        observeOverlaySettingsChanges()

        if ProductOnboardingPreferences.shouldPresentOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.settingsWindow.showSettings(initialTabRawValue: "general", forceOnboarding: true)
            }
        }

        // Bootstrap hotkey monitoring immediately when possible so users can
        // dictate right away. Permission prompts continue in parallel.
        ensureHotkeyMonitorReady(source: "launch")

        // Request permissions in the background. Completion refreshes readiness
        // state but does not gate hotkey startup.
        PermissionDiagnostics.requestAllInOrder(
            requestSpeechRecognition: shouldRequestSpeechPermissionAtLaunch()
        ) { [weak self] snap in
            guard let self else { return }
            PermissionDiagnostics.logAll()
            if !snap.accessibility.isUsable {
                self.presentAccessibilityGuidance()
            }
            self.ensureHotkeyMonitorReady(source: "permissions-completed")
        }
    }

    /// Ensures global hotkey monitoring is active whenever Accessibility is
    /// available. This is safe to call repeatedly.
    private func ensureHotkeyMonitorReady(source: String) {
        guard PermissionDiagnostics.accessibilityStatus().isUsable else {
            pendingHotkeyBootstrap = true
            presentAccessibilityGuidance()
            scheduleAccessibilityRetry()
            return
        }

        switch stateMachine.state {
        case .recording, .transcribing:
            // Do not interrupt active capture/transcribe sessions.
            pendingHotkeyBootstrap = true
            scheduleAccessibilityRetry()
            return
        case .idle, .success, .error:
            break
        }

        if hotkeyMonitor.isRunning {
            pendingHotkeyBootstrap = false
            accessibilityRetryAttempt = 0
            menuBar.updateHotkeyRecoveryAvailability(false)
            return
        }

        retryHotkeyMonitor(source: source)
    }

    /// Periodically checks if Accessibility was granted after the initial
    /// prompt and self-heals hotkey monitoring once it appears.
    private func scheduleAccessibilityRetry() {
        guard pendingHotkeyBootstrap else { return }
        guard accessibilityRetryWork == nil else { return }

        accessibilityRetryAttempt += 1
        let attempt = accessibilityRetryAttempt
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.accessibilityRetryWork = nil

            if PermissionDiagnostics.accessibilityStatus().isUsable {
                logger.info("Accessibility permission granted during auto-retry attempt \(attempt)")
                self.retryHotkeyMonitor(source: "auto")
            } else if self.pendingHotkeyBootstrap {
                self.scheduleAccessibilityRetry()
            }
        }

        accessibilityRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + accessibilityRetryDelay, execute: work)
    }

    /// Public entry point for manually retrying the hotkey monitor
    /// (e.g. from a menu item after granting Accessibility).
    func retryHotkeyMonitor(source: String = "manual") {
        accessibilityRetryWork?.cancel()
        accessibilityRetryWork = nil

        let snap = PermissionDiagnostics.snapshot()
        guard snap.accessibility.isUsable else {
            pendingHotkeyBootstrap = true
            presentAccessibilityGuidance()
            scheduleAccessibilityRetry()
            logger.info("Hotkey monitor retry skipped source=\(source, privacy: .public); accessibility missing")
            return
        }

        switch stateMachine.state {
        case .recording, .transcribing:
            pendingHotkeyBootstrap = true
            scheduleAccessibilityRetry()
            logger.info("Hotkey monitor retry deferred source=\(source, privacy: .public); session active")
            return
        case .idle, .success, .error:
            break
        }

        if hotkeyMonitor.isRunning {
            pendingHotkeyBootstrap = false
            accessibilityRetryAttempt = 0
            menuBar.updateHotkeyRecoveryAvailability(false)
            logger.info("Hotkey monitor already active source=\(source, privacy: .public)")
            return
        }

        stateMachine.deactivate()
        stateMachine.activate()
        pendingHotkeyBootstrap = false
        accessibilityRetryAttempt = 0
        menuBar.updateHotkeyRecoveryAvailability(false)
        logger.info("Hotkey monitor retry triggered source=\(source, privacy: .public) accessibility=\(snap.accessibility.rawValue)")
    }

    private func presentAccessibilityGuidance() {
        let msg = "Accessibility permission required. Grant access in System Settings → Privacy & Security → Accessibility. Hotkey setup resumes automatically."
        bubbleState.transition(to: .error, errorDetail: msg)
        menuBar.updateIcon(for: .error)
        menuBar.updateErrorDetail(msg)
        menuBar.updateHotkeyRecoveryAvailability(true)
    }

    /// Runs a one-shot recording session without the hotkey.
    /// This is the recovery path when the hotkey monitor cannot start.
    func runOneShotRecording() {
        stateMachine.startOneShotRecording()
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityRetryWork?.cancel()
        accessibilityRetryWork = nil
        Task {
            await ParakeetProvisioningCoordinator.shared.cancelRetries()
        }
        stateMachine.deactivate()
        if let observer = bindingObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = providerObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = parakeetBootstrapObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = parakeetModelSourceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = modelDownloadObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = transcriptLogObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = userDefaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        // Bridge DictationStateMachine.State → BubbleState for UI
        stateMachine.onStateChange = { [weak self] coreState in
            guard let self else { return }
            self.playRecordingSoundsIfNeeded(next: coreState)

            let uiState = self.mapCoreState(coreState)
            let detail = self.errorDetail(for: coreState)
            self.bubbleState.transition(to: uiState, errorDetail: detail)
            self.updateBubbleVisibility(for: coreState)
            self.menuBar.updateIcon(for: uiState)
            self.menuBar.updateDictationAction(for: coreState)
            self.updateActivityBadge(for: coreState)
            let hotkeySetupIssue = self.isHotkeySetupIssue(for: coreState)
            self.menuBar.updateHotkeyRecoveryAvailability(hotkeySetupIssue)
            if let detail {
                self.menuBar.updateErrorDetail(detail)
            }

            if hotkeySetupIssue {
                self.pendingHotkeyBootstrap = true
                self.scheduleAccessibilityRetry()
            } else if self.hotkeyMonitor.isRunning {
                self.pendingHotkeyBootstrap = false
                self.accessibilityRetryAttempt = 0
            }

            self.previousCoreState = coreState

            if self.deferredProviderRefresh,
               coreState == .idle || coreState == .success || coreState.isError {
                self.deferredProviderRefresh = false
                self.refreshProviderResolution(logReason: "Applying deferred provider change after active session")
            }
        }

        stateMachine.onAudioLevelChange = { [weak self] level in
            self?.bubbleState.updateAudioLevel(level)
        }

        stateMachine.onTranscriptChange = { [weak self] text in
            self?.bubbleState.updateLiveTranscript(text)
            self?.latestTranscriptForLog = text
        }

        // Menu bar dictation action runs a one-shot dictation session so
        // the action label always matches behavior.
        menuBar.onToggleDictation = { [weak self] in
            guard let self else { return }
            switch self.stateMachine.state {
            case .recording:
                self.stateMachine.stopOneShotRecording()
            case .idle, .success, .error:
                self.stateMachine.startOneShotRecording()
            case .transcribing:
                break
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
            if self.deferProviderRefreshIfSessionActive(reason: "Provider changed in settings") {
                return
            }
            self.refreshProviderResolution(logReason: "Provider changed in settings")

            if STTProviderKind.loadSelection() != .parakeet {
                Task {
                    await ParakeetProvisioningCoordinator.shared.cancelRetries()
                }
            }
        }
    }

    private func observeParakeetBootstrapChanges() {
        parakeetBootstrapObserver = NotificationCenter.default.addObserver(
            forName: .parakeetRuntimeBootstrapDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleParakeetBootstrapStatusChange()
        }
    }

    private func observeParakeetModelSourceChanges() {
        parakeetModelSourceObserver = NotificationCenter.default.addObserver(
            forName: .parakeetModelSourceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.deferProviderRefreshIfSessionActive(reason: "Parakeet model source changed") {
                return
            }
            self.refreshProviderResolution(logReason: "Parakeet model source changed")
        }
    }

    private func observeModelDownloadChanges() {
        modelDownloadObserver = NotificationCenter.default.addObserver(
            forName: .modelDownloadDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let variantID = notification.userInfo?["variantID"] as? String,
                  variantID == ModelVariant.parakeetCTC06B.id else {
                return
            }
            let isReady = (notification.userInfo?["isReady"] as? Bool) ?? false
            if self.lastObservedParakeetModelReady != isReady {
                self.lastObservedParakeetModelReady = isReady
                self.refreshProviderResolution(logReason: "Parakeet model download readiness changed: \(isReady)")
            }

            Task {
                await ParakeetProvisioningCoordinator.shared.handleModelDownloadEvent(
                    isReady: isReady
                )
            }
        }
    }

    private func observeTranscriptLogActions() {
        transcriptLogObserver = NotificationCenter.default.addObserver(
            forName: .transcriptLogReinsertRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let text = notification.userInfo?["text"] as? String else { return }
            self.injector.inject(text: text)
        }
    }

    private func observeOverlaySettingsChanges() {
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.updateBubbleVisibility(for: self.stateMachine.state)
        }
    }

    private func handleParakeetBootstrapStatusChange() {
        // Important: never hot-swap the provider purely because bootstrap phase
        // changed. Doing so can race with an in-flight beginSession() and cause
        // endSession() to run on a different provider instance.
        refreshProviderDiagnostics(logReason: "Parakeet runtime bootstrap status changed")
        let status = ParakeetRuntimeBootstrapManager.shared.statusSnapshot()
        Task {
            await ParakeetProvisioningCoordinator.shared.handleRuntimeBootstrapStatusChange(status)
        }
    }

    private func refreshProviderDiagnostics(logReason: String) {
        let kind = STTProviderKind.loadSelection()
        logger.info("\(logReason, privacy: .public): diagnostics-only refresh kind=\(kind.rawValue, privacy: .public)")
        let diagnostics = STTProviderResolver.diagnostics(for: kind)
        publishProviderDiagnostics(diagnostics)
    }

    private func deferProviderRefreshIfSessionActive(reason: String) -> Bool {
        let currentState = stateMachine.state
        switch currentState {
        case .recording, .transcribing:
            deferredProviderRefresh = true
            logger.warning("\(reason, privacy: .public): deferring provider refresh while state=\(String(describing: currentState), privacy: .public)")
            return true
        case .idle, .success, .error:
            return false
        }
    }

    private func refreshProviderResolution(logReason: String) {
        let kind = STTProviderKind.loadSelection()
        let priorState = stateMachine.state
        logger.info("\(logReason, privacy: .public): kind=\(kind.rawValue, privacy: .public) priorState=\(String(describing: priorState), privacy: .public)")
        let resolution = STTProviderResolver.resolve(for: kind)
        publishProviderDiagnostics(resolution.diagnostics)
        self.sttProvider = resolution.provider
        logger.info("Replacing state-machine provider with: \(self.sttProvider.displayName, privacy: .public)")
        self.stateMachine.replaceProvider(self.sttProvider)

        // A successful provider swap forces non-idle/error states back to
        // idle inside `replaceProvider`, so we intentionally avoid a second
        // replacement pass here.
    }

    private func publishProviderDiagnostics(_ diagnostics: ProviderRuntimeDiagnostics) {
        ProviderRuntimeDiagnosticsStore.shared.publish(diagnostics)
        menuBar.updateProviderDiagnostics(diagnostics)

        usesProviderFallback = diagnostics.usesFallback
        healthBadgeLabel = diagnostics.usesFallback ? "Fallback" : diagnostics.healthLevel.rawValue
        bubbleState.updateBadges(activity: activityBadgeLabel, health: healthBadgeLabel)

        logger.info(
            "Provider diagnostics health=\(diagnostics.healthLevel.rawValue, privacy: .public) requested=\(diagnostics.requestedKind.rawValue, privacy: .public) effective=\(diagnostics.effectiveKind.rawValue, privacy: .public)"
        )

        if let fallbackReason = diagnostics.fallbackReason {
            logger.warning("Provider fallback reason: \(fallbackReason, privacy: .public)")
        }
    }

    // MARK: - Bubble Badges

    private func updateActivityBadge(for state: DictationStateMachine.State) {
        let now = Date()
        switch state {
        case .recording:
            recordStartAt = now
            transcribeStartAt = nil
            recordingDurationMsForLog = nil
            latestTranscriptForLog = ""
            activeAppNameForLog = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
            // Snapshot provider name at session start so transcript logs reflect
            // the provider that actually handled this recording session.
            activeProviderNameForLog = sttProvider.displayName
            activityBadgeLabel = "REC"
            bubbleState.updateBadges(activity: activityBadgeLabel, health: healthBadgeLabel)
        case .transcribing:
            if let recordStartAt {
                recordingDurationMsForLog = Int(now.timeIntervalSince(recordStartAt) * 1_000)
            }
            transcribeStartAt = now
            activityBadgeLabel = "STT"
            bubbleState.updateBadges(activity: activityBadgeLabel, health: healthBadgeLabel)
        case .success:
            let transcribeLatencyMs: Int?
            if let transcribeStartAt {
                let ms = Int(now.timeIntervalSince(transcribeStartAt) * 1_000)
                transcribeLatencyMs = ms
                activityBadgeLabel = "\(ms)ms"
            } else {
                transcribeLatencyMs = nil
                activityBadgeLabel = "Done"
            }
            let endToEndMs: Int?
            if let recordStartAt {
                endToEndMs = Int(now.timeIntervalSince(recordStartAt) * 1_000)
            } else {
                endToEndMs = nil
            }
            bubbleState.updateBadges(activity: activityBadgeLabel, health: healthBadgeLabel)

            TranscriptLogStore.shared.append(
                provider: activeProviderNameForLog.isEmpty ? sttProvider.displayName : activeProviderNameForLog,
                appName: activeAppNameForLog,
                durationMs: transcribeLatencyMs,
                text: latestTranscriptForLog,
                status: "inserted"
            )
            DictationSessionMetricsStore.shared.append(
                provider: activeProviderNameForLog.isEmpty ? sttProvider.displayName : activeProviderNameForLog,
                appName: activeAppNameForLog,
                recordingDurationMs: recordingDurationMsForLog,
                transcribingDurationMs: transcribeLatencyMs,
                endToEndDurationMs: endToEndMs,
                status: "inserted"
            )

            recordStartAt = nil
            transcribeStartAt = nil
            recordingDurationMsForLog = nil
            latestTranscriptForLog = ""
            activeProviderNameForLog = ""
        case .idle:
            activityBadgeLabel = ""
            bubbleState.updateBadges(activity: activityBadgeLabel, health: healthBadgeLabel)
            recordStartAt = nil
            transcribeStartAt = nil
            recordingDurationMsForLog = nil
            activeProviderNameForLog = ""
        case .error:
            activityBadgeLabel = "Issue"
            bubbleState.updateBadges(activity: activityBadgeLabel, health: healthBadgeLabel)
            let endToEndMs: Int?
            if let recordStartAt {
                endToEndMs = Int(now.timeIntervalSince(recordStartAt) * 1_000)
            } else {
                endToEndMs = nil
            }
            let transcribeLatencyMs: Int?
            if let transcribeStartAt {
                transcribeLatencyMs = Int(now.timeIntervalSince(transcribeStartAt) * 1_000)
            } else {
                transcribeLatencyMs = nil
            }
            if !latestTranscriptForLog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TranscriptLogStore.shared.append(
                    provider: activeProviderNameForLog.isEmpty ? sttProvider.displayName : activeProviderNameForLog,
                    appName: activeAppNameForLog,
                    durationMs: nil,
                    text: latestTranscriptForLog,
                    status: "saved_error"
                )
            }
            DictationSessionMetricsStore.shared.append(
                provider: activeProviderNameForLog.isEmpty ? sttProvider.displayName : activeProviderNameForLog,
                appName: activeAppNameForLog,
                recordingDurationMs: recordingDurationMsForLog,
                transcribingDurationMs: transcribeLatencyMs,
                endToEndDurationMs: endToEndMs,
                status: "error"
            )
            recordStartAt = nil
            transcribeStartAt = nil
            recordingDurationMsForLog = nil
            latestTranscriptForLog = ""
            activeProviderNameForLog = ""
        }
    }

    private func playRecordingSoundsIfNeeded(next state: DictationStateMachine.State) {
        let wasRecording: Bool
        if case .recording = previousCoreState {
            wasRecording = true
        } else {
            wasRecording = false
        }

        let isRecording: Bool
        if case .recording = state {
            isRecording = true
        } else {
            isRecording = false
        }

        if !wasRecording && isRecording {
            recordingSoundPlayer.playStartIfEnabled()
        } else if wasRecording && !isRecording {
            recordingSoundPlayer.playStopIfEnabled()
        }
    }

    private func updateBubbleVisibility(for state: DictationStateMachine.State) {
        let mode = DictationOverlaySettings.overlayMode
        let shouldShowOverlay: Bool

        switch state {
        case .recording, .transcribing:
            shouldShowOverlay = true
        case .idle, .success, .error:
            shouldShowOverlay = false
        }

        guard shouldShowOverlay else {
            bubblePanel.hide()
            topCenterOverlayPanel.hide()
            return
        }

        switch mode {
        case .off:
            bubblePanel.hide()
            topCenterOverlayPanel.hide()
        case .floatingBubble:
            topCenterOverlayPanel.hide()
            bubblePanel.show()
        case .topCenterWaveform:
            bubblePanel.hide()
            topCenterOverlayPanel.show()
        }
    }

    private func isHotkeySetupIssue(for state: DictationStateMachine.State) -> Bool {
        guard case .error(let message) = state else { return false }
        let normalized = message.lowercased()
        if normalized.contains("cannot monitor hotkeys") { return true }
        if normalized.contains("accessibility permission") { return true }
        return false
    }

    private func shouldRequestSpeechPermissionAtLaunch() -> Bool {
        STTProviderKind.loadSelection() == .appleSpeech
    }

    // MARK: - State Mapping

    /// Maps the core `DictationStateMachine.State` to the UI `BubbleState`.
    private func mapCoreState(_ state: DictationStateMachine.State) -> BubbleState {
        switch state {
        case .idle:         return .idle
        case .recording:    return .listening
        case .transcribing: return .transcribing
        case .success:      return .success
        case .error:        return .error
        }
    }

    /// Returns the error detail string when core state is `.error`, nil otherwise.
    private func errorDetail(for state: DictationStateMachine.State) -> String? {
        if case .error(let msg) = state { return msg }
        return nil
    }
}
