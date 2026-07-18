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
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.show() }
            return
        }
        if panel == nil { createPanel() }
        panel?.orderFrontRegardless()
    }

    func hide() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.hide() }
            return
        }
        panel?.orderOut(nil)
    }

    func toggle() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.toggle() }
            return
        }
        if panel?.isVisible == true { hide() } else { show() }
    }

    func reposition(near point: NSPoint) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.reposition(near: point) }
            return
        }
        panel?.setFrameOrigin(point)
    }

    // MARK: - Private

    private func createPanel() {
        let content = FloatingBubbleWithLabel(
            compactMode: true,
            onTap: { [weak self] in self?.stateSubject.handleTap() }
        )
        .environmentObject(stateSubject)

        // Side length must fit the bubble content (bubbleDiameter + 48) plus the
        // outer glow, which blurs well past the content frame. Undersizing the
        // panel clips the glow and pulse rings at the window edge.
        let side = VFSize.bubbleDiameter + 88
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: side, height: side)

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

    /// Live partial/final transcript shown as an overlay while recording/transcribing.
    @Published var liveTranscript: String = ""

    /// Lightweight status badges shown in the bubble/settings.
    @Published var activityBadge: String = ""
    @Published var healthBadge: String = ""

    /// Called when the user taps the bubble. Override via `onTap` closure.
    var onTap: (() -> Void)?

    func handleTap() {
        onTap?()
    }

    func transition(to newState: BubbleState, errorDetail: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
            self?.errorDetail = errorDetail ?? ""
            if newState == .idle || newState == .error {
                self?.audioLevel = 0
                self?.liveTranscript = ""
            }
        }
    }

    func updateAudioLevel(_ level: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = min(max(level, 0), 1)
        }
    }

    func updateLiveTranscript(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.liveTranscript = text
        }
    }

    func updateBadges(activity: String, health: String) {
        DispatchQueue.main.async { [weak self] in
            self?.activityBadge = activity
            self?.healthBadge = health
        }
    }
}
