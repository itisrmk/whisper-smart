import AppKit
import SwiftUI

/// Manages a single, reusable settings window.
/// Window chrome is configured for a seamless dark neumorphic appearance:
/// transparent titlebar, dark background matching the depth layer,
/// and no miniaturize/zoom to keep the panel feel.
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
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.08, alpha: 1.0)
        window.setContentSize(NSSize(width: VFSize.settingsWidth, height: VFSize.settingsHeight))
        window.center()

        let wc = NSWindowController(window: window)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.windowController = wc
    }
}
