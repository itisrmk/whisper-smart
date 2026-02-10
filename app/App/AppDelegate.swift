import AppKit

/// The NSApplicationDelegate that wires together the menu bar,
/// floating bubble, and settings window.
///
/// This is the central coordinator for UI lifecycle. It does **not**
/// contain business logic — the core layer will inject behaviour
/// via the `BubbleStateSubject` and callback closures.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let bubbleState = BubbleStateSubject()

    private lazy var menuBar = MenuBarController(stateSubject: bubbleState)
    private lazy var bubblePanel = BubblePanelController(stateSubject: bubbleState)
    private lazy var settingsWindow = SettingsWindowController()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon
        NSApp.setActivationPolicy(.accessory)

        menuBar.install()
        bubblePanel.show()

        wireCallbacks()
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        menuBar.onToggleDictation = { [weak self] in
            guard let self else { return }
            // Toggle between idle ↔ listening as a UI demo.
            // The real implementation will be driven by the core layer.
            let next: BubbleState = (self.bubbleState.state == .idle) ? .listening : .idle
            self.bubbleState.transition(to: next)
            self.menuBar.updateIcon(for: next)
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
}
