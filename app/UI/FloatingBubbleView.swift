import SwiftUI

/// Floating overlay bubble that visualises dictation state.
///
/// The bubble is designed to be hosted inside a borderless, transparent
/// `NSPanel` so it appears to float above all other windows.  The dark
/// glass design uses layered gradients, glow rings, and depth shadows
/// inspired by iOS-style glassmorphism.
struct FloatingBubbleView: View {
    let state: BubbleState
    var onTap: (() -> Void)?

    @State private var pulseScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.5

    var body: some View {
        ZStack {
            // ── Outer glow (always present, intensifies when listening) ──
            Circle()
                .fill(state.tintColor.opacity(state.isPulsing ? 0.35 : 0.15))
                .frame(width: VFSize.bubbleDiameter + 40,
                       height: VFSize.bubbleDiameter + 40)
                .blur(radius: 20)
                .opacity(glowOpacity)
                .onAppear {
                    if state.isPulsing {
                        withAnimation(VFAnimation.glowPulse) {
                            glowOpacity = 1.0
                        }
                    }
                }
                .onChange(of: state) {
                    if state.isPulsing {
                        glowOpacity = 0.5
                        withAnimation(VFAnimation.glowPulse) {
                            glowOpacity = 1.0
                        }
                    } else {
                        withAnimation(VFAnimation.fadeMedium) {
                            glowOpacity = 0.5
                        }
                    }
                }

            // ── Pulsing ring (listening state only) ──
            if state.isPulsing {
                Circle()
                    .stroke(state.tintColor.opacity(0.45), lineWidth: 2)
                    .frame(width: VFSize.bubbleDiameter + 16,
                           height: VFSize.bubbleDiameter + 16)
                    .scaleEffect(pulseScale)
                    .onAppear {
                        pulseScale = 1.0
                        withAnimation(VFAnimation.pulseLoop) {
                            pulseScale = 1.35
                        }
                    }
                    .onDisappear { pulseScale = 1.0 }
            }

            // ── Glass backdrop circle ──
            Circle()
                .fill(VFColor.glass1)
                .frame(width: VFSize.bubbleDiameter,
                       height: VFSize.bubbleDiameter)
                .overlay(
                    Circle()
                        .stroke(VFColor.glassBorder, lineWidth: 1)
                )
                .overlay(
                    // Top-edge shine
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [VFColor.glassHighlight, .clear],
                                startPoint: .top,
                                endPoint: .center
                            ),
                            lineWidth: 1
                        )
                )

            // ── Tinted gradient fill ──
            Circle()
                .fill(state.tintColor.gradient)
                .frame(width: VFSize.bubbleDiameter - 6,
                       height: VFSize.bubbleDiameter - 6)
                .shadow(color: state.tintColor.opacity(0.5), radius: 12, y: 4)

            // ── Icon ──
            Image(systemName: state.sfSymbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(VFColor.textOnOverlay)
                .contentTransition(.symbolEffect(.replace))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
        .frame(width: VFSize.bubbleDiameter + 48,
               height: VFSize.bubbleDiameter + 48)
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
        VStack(spacing: VFSpacing.sm) {
            FloatingBubbleView(state: state, onTap: onTap)

            // ── Glass pill label ──
            Text(state.label)
                .font(VFFont.bubbleStatus)
                .foregroundStyle(VFColor.textOnOverlay)
                .padding(.horizontal, VFSpacing.md)
                .padding(.vertical, VFSpacing.xs)
                .background(
                    Capsule()
                        .fill(VFColor.glass2)
                        .overlay(
                            Capsule()
                                .stroke(VFColor.glassBorder, lineWidth: 0.5)
                        )
                )
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
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
        .background(VFColor.glass0)
    }
}
#endif
