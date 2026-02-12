import SwiftUI

/// Minimal top-center overlay focused on waveform feedback.
/// Designed to blend into the UI with a neutral gray shell.
struct TopCenterWaveformOverlayView: View {
    @EnvironmentObject var stateSubject: BubbleStateSubject
    var onTap: (() -> Void)?

    var body: some View {
        HStack(spacing: VFSpacing.sm) {
            Circle()
                .fill(stateSubject.state.tintColor.opacity(0.85))
                .frame(width: 6, height: 6)

            if stateSubject.state == .listening {
                WaveformBarView(
                    isActive: true,
                    audioLevel: stateSubject.audioLevel,
                    tintColor: VFColor.textOnOverlay
                )
                .frame(width: 46, height: 16)
            } else if stateSubject.state == .transcribing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(VFColor.textOnOverlay)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: stateSubject.state.sfSymbol)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(VFColor.textOnOverlay)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(VFColor.glass2.opacity(0.92))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.28), radius: 10, y: 3)
        )
        .contentShape(Capsule())
        .onTapGesture { onTap?() }
        .animation(VFAnimation.fadeMedium, value: stateSubject.state)
        .animation(VFAnimation.fadeMedium, value: stateSubject.audioLevel)
    }
}
