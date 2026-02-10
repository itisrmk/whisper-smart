import AppKit
import SwiftUI

/// Owns the `NSStatusItem` that lives in the macOS menu bar.
///
/// The menu provides quick access to start/stop dictation, open
/// settings, and quit the app.
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private let stateSubject: BubbleStateSubject

    // Callbacks the app delegate wires up
    var onToggleDictation: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init(stateSubject: BubbleStateSubject) {
        self.stateSubject = stateSubject
    }

    // MARK: - Setup

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "mic.fill",
                accessibilityDescription: "Visperflow Dictation"
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

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(handleOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Visperflow",
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
}
