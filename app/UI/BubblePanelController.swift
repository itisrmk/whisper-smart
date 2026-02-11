import AppKit
import SwiftUI

/// Manages a borderless, always-on-top `NSPanel` that hosts the
/// `FloatingBubbleView`. The panel is transparent and non-activating
/// so it never steals focus from the app the user is typing in.
final class BubblePanelController {

    private var panel: NSPanel?
    private let stateSubject: BubbleStateSubject

    init(stateSubject: BubbleStateSubject) {
        self.stateSubject = stateSubject
    }

    // MARK: - Public

    func show() {
        if panel == nil { createPanel() }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func reposition(near point: NSPoint) {
        panel?.setFrameOrigin(point)
    }

    // MARK: - Private

    private func createPanel() {
        let content = FloatingBubbleWithLabel(
            onTap: { [weak self] in self?.stateSubject.handleTap() }
        )
        .environmentObject(stateSubject)

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 120, height: 120)

        let p = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.contentView = hostingView

        // Default position: top-right of the main screen
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 100
            let y = screen.visibleFrame.maxY - 120
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = p
    }
}

// MARK: - Observable State Bridge

/// Lightweight observable that the bubble UI binds to.
/// Core layer will drive this; UI layer only reads.
final class BubbleStateSubject: ObservableObject {
    @Published var state: BubbleState = .idle
    /// Normalised audio level (0…1) fed from the audio capture pipeline.
    /// Drives the waveform bar heights when `state == .listening`.
    @Published var audioLevel: CGFloat = 0

    /// When `state == .error`, this contains the specific error description
    /// (e.g. "Microphone access denied …"). Used by the bubble label and menu.
    @Published var errorDetail: String = ""

    /// Called when the user taps the bubble. Override via `onTap` closure.
    var onTap: (() -> Void)?

    func handleTap() {
        onTap?()
    }

    func transition(to newState: BubbleState, errorDetail: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
            self?.errorDetail = errorDetail ?? ""
        }
    }

    func updateAudioLevel(_ level: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = min(max(level, 0), 1)
        }
    }
}
