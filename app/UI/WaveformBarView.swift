import SwiftUI

/// A row of animated vertical bars that visualise audio input level.
///
/// When `isActive` is true the bars animate between min and max heights
/// with staggered timing, giving a superwhisper-style waveform feel.
/// The `audioLevel` value (0…1) scales the overall amplitude.
struct WaveformBarView: View {
    var isActive: Bool
    var audioLevel: CGFloat = 0.5
    var tintColor: Color = VFColor.listening

    private let barCount = VFSize.waveformBarCount

    var body: some View {
        HStack(spacing: VFSize.waveformBarSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                WaveformSingleBar(
                    index: index,
                    barCount: barCount,
                    isActive: isActive,
                    audioLevel: audioLevel,
                    tintColor: tintColor
                )
            }
        }
    }
}

/// A single animated waveform bar with per-bar stagger.
private struct WaveformSingleBar: View {
    let index: Int
    let barCount: Int
    let isActive: Bool
    let audioLevel: CGFloat
    let tintColor: Color

    @State private var phase: CGFloat = 0

    /// Per-bar height multiplier derived from a centre-weighted distribution.
    private var centreWeight: CGFloat {
        let mid = CGFloat(barCount - 1) / 2.0
        let dist = abs(CGFloat(index) - mid) / mid
        return 1.0 - dist * 0.35
    }

    private var targetHeight: CGFloat {
        if !isActive {
            return VFSize.waveformBarMinHeight
        }
        let amplitude = max(audioLevel, 0.25) * centreWeight
        let range = VFSize.waveformBarMaxHeight - VFSize.waveformBarMinHeight
        return VFSize.waveformBarMinHeight + range * amplitude * (0.5 + phase * 0.5)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: VFSize.waveformBarWidth / 2, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tintColor, tintColor.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: VFSize.waveformBarWidth, height: targetHeight)
            .shadow(color: tintColor.opacity(0.3), radius: 3, y: 1)
            .onAppear {
                if isActive { startAnimation() }
            }
            .onChange(of: isActive) {
                if isActive {
                    startAnimation()
                } else {
                    withAnimation(VFAnimation.fadeMedium) { phase = 0 }
                }
            }
    }

    private func startAnimation() {
        phase = 0
        withAnimation(VFAnimation.waveformBar(index: index, count: barCount)) {
            phase = 1
        }
    }
}

// MARK: - Preview

#if DEBUG
struct WaveformBarView_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 32) {
            WaveformBarView(isActive: false)
            WaveformBarView(isActive: true, audioLevel: 0.4)
            WaveformBarView(isActive: true, audioLevel: 0.8, tintColor: VFColor.transcribing)
        }
        .padding(40)
        .layeredDepthBackground()
    }
}
#endif
