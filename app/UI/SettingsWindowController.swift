import AppKit
import SwiftUI

/// Manages a single, reusable settings window.
/// Window chrome is configured for the Modernist appearance: transparent
/// titlebar over the sidebar surface, adaptive light/dark background, and
/// no miniaturize/zoom to keep the panel feel.
final class SettingsWindowController {

    private var windowController: NSWindowController?
    private var windowCloseObserver: NSObjectProtocol?

    func showSettings(initialTabRawValue: String? = nil) {
        VFTheme.debugAssertTokenSanity()

        if let wc = windowController {
            if let window = wc.window {
                enforceScrollChromePolicy(for: window)
            }
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(initialTabRawValue: initialTabRawValue)
            .vfForcedDarkTheme()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        // The controller keeps the window alive; releasing on close while we
        // still hold a reference would leave a dangling window on reopen.
        window.isReleasedWhenClosed = false
        window.title = "Whisper Smart Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = true
        window.backgroundColor = VFColor.windowBackgroundNS
        window.setContentSize(NSSize(width: VFSize.settingsWidth, height: VFSize.settingsHeight))

        window.center()
        enforceScrollChromePolicy(for: window)

        let wc = NSWindowController(window: window)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Drop the controller once the window closes so the next
        // showSettings() builds a fresh window instead of trying to
        // resurrect a closed one.
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.windowController = nil
        }

        self.windowController = wc
    }

    /// Forces an overlay/no-chrome scroll style for every NSScrollView in the
    /// settings window. This avoids persistent scrollbar gutters on some macOS
    /// setups where SwiftUI `scrollIndicators(.hidden)` isn't strictly honored.
    private func enforceScrollChromePolicy(for window: NSWindow) {
        let applyPolicy = { [weak window] in
            guard let root = window?.contentViewController?.view ?? window?.contentView else { return }
            Self.configureScrollViews(in: root)
        }

        applyPolicy()
        DispatchQueue.main.async { applyPolicy() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: applyPolicy)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: applyPolicy)
    }

    private static func configureScrollViews(in view: NSView) {
        if let button = view as? NSButton {
            button.focusRingType = .none
        }

        if let scrollView = view as? NSScrollView {
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.verticalScroller?.isHidden = true
            scrollView.horizontalScroller?.isHidden = true
            scrollView.verticalScroller?.alphaValue = 0
            scrollView.horizontalScroller?.alphaValue = 0
        }

        if let scroller = view as? NSScroller {
            scroller.isHidden = true
            scroller.alphaValue = 0
        }

        for subview in view.subviews {
            configureScrollViews(in: subview)
        }
    }
}
