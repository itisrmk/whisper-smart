import AppKit
import SwiftUI

/// Manages a single, reusable settings window.
/// Window chrome is configured for a seamless dark neumorphic appearance:
/// transparent titlebar, dark background matching the depth layer,
/// and no miniaturize/zoom to keep the panel feel.
final class SettingsWindowController {

    private var windowController: NSWindowController?

    func showSettings(initialTabRawValue: String? = nil, forceOnboarding: Bool = false) {
        VFTheme.debugAssertTokenSanity()

        if let wc = windowController {
            if let window = wc.window {
                applyForcedDarkAppearance(to: window)
                enforceScrollChromePolicy(for: window)
            }
            if forceOnboarding {
                NotificationCenter.default.post(name: .productOnboardingRequested, object: nil)
            }
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(initialTabRawValue: initialTabRawValue, forceOnboarding: forceOnboarding)
            .vfForcedDarkTheme()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Whisper Smart Settings"
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
        enforceScrollChromePolicy(for: window)

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
