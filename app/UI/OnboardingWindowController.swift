import AppKit
import SwiftUI

/// Manages the standalone first-run onboarding window (Wispr-Flow-style
/// guided setup). One reusable window; chrome matches the settings window.
final class OnboardingWindowController {

    /// Fired whenever a permission was granted mid-flow (e.g. Accessibility)
    /// so the app can bootstrap the hotkey monitor for the practice step.
    var onPermissionsChanged: (() -> Void)?

    /// Fired when the user completes the flow via "Start dictating".
    var onFinished: (() -> Void)?

    private let stateSubject: BubbleStateSubject
    private var windowController: NSWindowController?
    private var windowCloseObserver: NSObjectProtocol?

    init(stateSubject: BubbleStateSubject) {
        self.stateSubject = stateSubject
    }

    func show() {
        if let wc = windowController {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let flowView = OnboardingFlowView(
            stateSubject: stateSubject,
            onPermissionsChanged: { [weak self] in
                self?.onPermissionsChanged?()
            },
            onFinished: { [weak self] in
                self?.finish()
            }
        )
        .vfForcedDarkTheme()

        let hostingController = NSHostingController(rootView: flowView)

        let window = NSWindow(contentViewController: hostingController)
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Whisper Smart"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = true
        window.backgroundColor = VFColor.windowBackgroundNS
        window.setContentSize(NSSize(width: 760, height: 620))
        window.center()

        let wc = NSWindowController(window: window)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

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

    private func finish() {
        onFinished?()
        windowController?.window?.close()
    }
}
