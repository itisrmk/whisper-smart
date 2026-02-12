import AppKit
import SwiftUI

final class TopCenterOverlayPanelController {
    private var panel: NSPanel?
    private let stateSubject: BubbleStateSubject

    init(stateSubject: BubbleStateSubject) {
        self.stateSubject = stateSubject
    }

    func show() {
        if panel == nil { createPanel() }
        repositionToTopCenter()

        guard let panel else { return }
        if panel.isVisible { return }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    private func createPanel() {
        let content = TopCenterWaveformOverlayView(
            onTap: { [weak self] in self?.stateSubject.handleTap() }
        )
        .environmentObject(stateSubject)

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 180, height: 42)

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
        p.contentView = hostingView

        self.panel = p
    }

    private func repositionToTopCenter() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - panel.frame.width / 2
        let y = visible.maxY - panel.frame.height - 18
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
