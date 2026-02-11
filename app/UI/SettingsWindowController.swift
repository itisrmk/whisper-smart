import AppKit
import SwiftUI

/// Manages a single, reusable settings window.
/// Window chrome is configured for a seamless dark neumorphic appearance:
/// transparent titlebar, dark background matching the depth layer,
/// and no miniaturize/zoom to keep the panel feel.
final class SettingsWindowController {

    private var windowController: NSWindowController?

    func showSettings() {
        VFTheme.debugAssertTokenSanity()

        if let wc = windowController {
            if let window = wc.window {
                applyForcedDarkAppearance(to: window)
            }
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
            .vfForcedDarkTheme()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Visperflow Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Force dark appearance on window and content so SwiftUI resolves
        // all adaptive colors against the dark palette.
        applyForcedDarkAppearance(to: window)
        window.isOpaque = true
        window.backgroundColor = VFColor.glass0NS
        window.setContentSize(NSSize(width: VFSize.settingsWidth, height: VFSize.settingsHeight))

        // Disable any accidental vibrancy/appearance blending in the hosting view.
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = VFColor.glass0NS.cgColor
        window.center()

        let wc = NSWindowController(window: window)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.windowController = wc
    }

    private func applyForcedDarkAppearance(to window: NSWindow) {
        guard let darkAppearance = NSAppearance(named: VFTheme.forcedAppearanceName) else {
            return
        }
        window.appearance = darkAppearance
        window.contentView?.appearance = darkAppearance
        window.contentViewController?.view.appearance = darkAppearance
        window.contentViewController?.view.wantsLayer = true
        window.contentViewController?.view.layer?.backgroundColor = VFColor.glass0NS.cgColor
    }
}
