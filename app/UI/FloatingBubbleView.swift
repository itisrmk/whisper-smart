import SwiftUI

/// Floating overlay bubble that visualises dictation state.
///
/// The bubble is designed to be hosted inside a borderless, transparent
/// `NSPanel` so it appears to float above all other windows.
struct FloatingBubbleView: View {
    let state: BubbleState
    var onTap: (() -> Void)?

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Pulsing ring (listening state only)
            if state.isPulsing {
                Circle()
                    .stroke(state.tintColor.opacity(0.35), lineWidth: 2)
                    .frame(width: VFSize.bubbleDiameter + 12,
                           height: VFSize.bubbleDiameter + 12)
                    .scaleEffect(pulseScale)
                    .onAppear {
                        pulseScale = 1.0
                        withAnimation(VFAnimation.pulseLoop) {
                            pulseScale = 1.25
                        }
                    }
                    .onDisappear { pulseScale = 1.0 }
            }

            // Main bubble
            Circle()
                .fill(state.tintColor.gradient)
                .frame(width: VFSize.bubbleDiameter,
                       height: VFSize.bubbleDiameter)
                .shadow(color: state.tintColor.opacity(0.4), radius: 8, y: 2)

            // Icon
            Image(systemName: state.sfSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(VFColor.textOnOverlay)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: VFSize.bubbleDiameter + 20,
               height: VFSize.bubbleDiameter + 20)
        .contentShape(Circle())
        .onTapGesture { onTap?() }
        .animation(VFAnimation.springSnappy, value: state)
    }
}

/// Extended bubble that includes a status label beneath the circle.
struct FloatingBubbleWithLabel: View {
    let state: BubbleState
    var onTap: (() -> Void)?

    var body: some View {
        VStack(spacing: VFSpacing.xs) {
            FloatingBubbleView(state: state, onTap: onTap)

            Text(state.label)
                .font(VFFont.bubbleStatus)
                .foregroundStyle(VFColor.textOnOverlay)
                .padding(.horizontal, VFSpacing.sm)
                .padding(.vertical, VFSpacing.xxs)
                .background(
                    Capsule()
                        .fill(VFColor.surfaceOverlay)
                )
        }
        .animation(VFAnimation.fadeMedium, value: state)
    }
}

// MARK: - Preview

#if DEBUG
struct FloatingBubbleView_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 24) {
            ForEach(BubbleState.allCases) { s in
                FloatingBubbleWithLabel(state: s)
            }
        }
        .padding(40)
        .background(Color.black.opacity(0.8))
    }
}
#endif
