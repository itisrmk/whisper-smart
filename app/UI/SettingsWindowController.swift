import AppKit
import SwiftUI

/// Manages a single, reusable settings window.
final class SettingsWindowController {

    private var windowController: NSWindowController?

    func showSettings() {
        if let wc = windowController {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Visperflow Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: VFSize.settingsWidth, height: VFSize.settingsHeight))
        window.center()

        let wc = NSWindowController(window: window)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.windowController = wc
    }
}
