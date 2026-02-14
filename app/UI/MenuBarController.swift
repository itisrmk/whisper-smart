import AppKit
import SwiftUI

/// Owns the `NSStatusItem` that lives in the macOS menu bar.
///
/// The menu provides quick access to start/stop dictation, open
/// settings, and quit the app.  Includes recovery items for when
/// the hotkey monitor cannot start (e.g. missing Accessibility).
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private let stateSubject: BubbleStateSubject

    // Callbacks the app delegate wires up
    var onToggleDictation: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onRetryHotkeyMonitor: (() -> Void)?
    var onOneShotRecording: (() -> Void)?
    var onStopOneShotRecording: (() -> Void)?

    /// Menu item that shows the current error detail (hidden when no error).
    private var errorDetailItem: NSMenuItem?
    /// Menu item for one-shot recording.
    private var oneShotItem: NSMenuItem?
    /// Menu item for retrying the hotkey monitor.
    private var retryItem: NSMenuItem?
    /// Menu item showing provider runtime diagnostics.
    private var providerDiagnosticsItem: NSMenuItem?
    /// Primary dictation control item.
    private var dictateItem: NSMenuItem?

    private var isOneShotActive = false

    init(stateSubject: BubbleStateSubject) {
        self.stateSubject = stateSubject
    }

    // MARK: - Setup

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "mic.fill",
                accessibilityDescription: "Whisper Smart Dictation"
            )
            button.image?.size = NSSize(width: VFSize.menuBarIcon, height: VFSize.menuBarIcon)
            button.image?.isTemplate = true
        }

        item.menu = buildMenu()
        self.statusItem = item
    }

    /// Refresh the menu item icon to reflect current bubble state.
    func updateIcon(for state: BubbleState) {
        guard let button = statusItem?.button else { return }
        let symbolName: String
        switch state {
        case .idle:         symbolName = "mic.fill"
        case .listening:    symbolName = "mic.badge.plus"
        case .transcribing: symbolName = "text.cursor"
        case .success:      symbolName = "checkmark.circle.fill"
        case .error:        symbolName = "exclamationmark.triangle.fill"
        }
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: state.label
        )
        button.image?.size = NSSize(width: VFSize.menuBarIcon, height: VFSize.menuBarIcon)
        button.image?.isTemplate = true

        // Show/hide recovery items based on error state
        let showRecovery = (state == .error)
        errorDetailItem?.isHidden = !showRecovery
        retryItem?.isHidden = !showRecovery

        if state == .idle {
            isOneShotActive = false
            oneShotItem?.title = "One-Shot Recording (no hotkey)"
        }
    }

    /// Keeps the primary menu action text aligned with current lifecycle state.
    func updateDictationAction(for state: DictationStateMachine.State) {
        switch state {
        case .recording:
            dictateItem?.title = "Stop Dictation"
            dictateItem?.isEnabled = true
        case .transcribing:
            dictateItem?.title = "Transcribing…"
            dictateItem?.isEnabled = false
        case .idle, .success, .error:
            dictateItem?.title = "Start Dictation"
            dictateItem?.isEnabled = true
        }
    }

    /// Update the error detail shown in the menu.
    func updateErrorDetail(_ detail: String) {
        let truncated = detail.count > 80
            ? String(detail.prefix(77)) + "..."
            : detail
        errorDetailItem?.title = truncated
        errorDetailItem?.isHidden = false
    }

    /// Update provider runtime diagnostics line in the menu.
    ///
    /// Also clears any stale error-detail text that may have been left behind
    /// by a previous provider resolution cycle when the new diagnostics no
    /// longer indicate an error condition.
    func updateProviderDiagnostics(_ diagnostics: ProviderRuntimeDiagnostics) {
        #if DEBUG
        diagnostics.assertDisplayConsistency()
        #endif
        let summary: String
        if diagnostics.usesFallback {
            if let fallbackReason = diagnostics.fallbackReason, !fallbackReason.isEmpty {
                let shortReason = fallbackReason.count > 56
                    ? String(fallbackReason.prefix(53)) + "..."
                    : fallbackReason
                summary = "Provider: \(diagnostics.effectiveKind.displayName) (fallback: \(shortReason))"
            } else {
                summary = "Provider: \(diagnostics.effectiveKind.displayName) (fallback)"
            }
        } else {
            summary = "Provider: \(diagnostics.effectiveKind.displayName)"
        }
        providerDiagnosticsItem?.title = summary

        let tooltip: String
        if let fallbackReason = diagnostics.fallbackReason {
            tooltip = "Fallback reason: \(fallbackReason)"
        } else {
            tooltip = "Health: \(diagnostics.healthLevel.rawValue)"
        }
        providerDiagnosticsItem?.toolTip = tooltip

        // When the new provider resolution is healthy (no fallback), clear
        // any leftover error detail from a previous cycle so it doesn't
        // persist stale text in the menu.
        if !diagnostics.usesFallback && diagnostics.healthLevel == .healthy {
            errorDetailItem?.title = ""
            errorDetailItem?.isHidden = true
        }
    }

    // MARK: - Menu Construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let dictateItem = NSMenuItem(
            title: "Start Dictation",
            action: #selector(handleToggleDictation),
            keyEquivalent: ""
        )
        dictateItem.target = self
        menu.addItem(dictateItem)
        self.dictateItem = dictateItem

        let providerDiag = NSMenuItem(
            title: "Provider: Loading…",
            action: nil,
            keyEquivalent: ""
        )
        providerDiag.isEnabled = false
        menu.addItem(providerDiag)
        self.providerDiagnosticsItem = providerDiag

        menu.addItem(.separator())

        // ── Recovery items ──

        let errItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errItem.isEnabled = false
        errItem.isHidden = true
        menu.addItem(errItem)
        self.errorDetailItem = errItem

        let retry = NSMenuItem(
            title: "Retry Hotkey Monitor",
            action: #selector(handleRetryHotkeyMonitor),
            keyEquivalent: "r"
        )
        retry.target = self
        retry.isHidden = true
        menu.addItem(retry)
        self.retryItem = retry

        let oneShot = NSMenuItem(
            title: "One-Shot Recording (no hotkey)",
            action: #selector(handleOneShotRecording),
            keyEquivalent: "d"
        )
        oneShot.target = self
        menu.addItem(oneShot)
        self.oneShotItem = oneShot

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(handleOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let checkUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(handleCheckForUpdates),
            keyEquivalent: ""
        )
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Whisper Smart",
            action: #selector(handleQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Actions

    @objc private func handleToggleDictation() {
        onToggleDictation?()
    }

    @objc private func handleOpenSettings() {
        onOpenSettings?()
    }

    @objc private func handleQuit() {
        onQuit?()
    }

    @objc private func handleCheckForUpdates() {
        UpdateManager.shared.checkForUpdates()
    }

    @objc private func handleRetryHotkeyMonitor() {
        onRetryHotkeyMonitor?()
    }

    @objc private func handleOneShotRecording() {
        if isOneShotActive {
            isOneShotActive = false
            oneShotItem?.title = "One-Shot Recording (no hotkey)"
            onStopOneShotRecording?()
        } else {
            isOneShotActive = true
            oneShotItem?.title = "Stop One-Shot Recording"
            onOneShotRecording?()
        }
    }
}
