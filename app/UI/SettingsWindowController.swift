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

        let darkAppearance = NSAppearance(named: .darkAqua)

        let settingsView = SettingsView()
            .environment(\.colorScheme, .dark)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Visperflow Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Force dark appearance on window and content so SwiftUI resolves
        // all adaptive colors against the dark palette.
        window.appearance = darkAppearance
        window.contentView?.appearance = darkAppearance
        window.isOpaque = true
        window.backgroundColor = NSColor(white: 0.08, alpha: 1.0)
        window.setContentSize(NSSize(width: VFSize.settingsWidth, height: VFSize.settingsHeight))

        // Disable any accidental vibrancy/appearance blending in the hosting view.
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1.0).cgColor
        window.center()

        let wc = NSWindowController(window: window)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.windowController = wc
    }
}
