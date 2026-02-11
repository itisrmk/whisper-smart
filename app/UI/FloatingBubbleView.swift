import SwiftUI

/// Floating overlay bubble that visualises dictation state.
///
/// The bubble is designed to be hosted inside a borderless, transparent
/// `NSPanel` so it appears to float above all other windows. The dark
/// neumorphic design uses layered gradients, soft shadow edges, and
/// glow rings inspired by modern Apple dark controls.
struct FloatingBubbleView: View {
    let state: BubbleState
    var onTap: (() -> Void)?

    @State private var pulseScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.5

    var body: some View {
        ZStack {
            // ── Outer glow (always present, intensifies when listening) ──
            Circle()
                .fill(state.tintColor.opacity(state.isPulsing ? 0.30 : 0.12))
                .frame(width: VFSize.bubbleDiameter + 44,
                       height: VFSize.bubbleDiameter + 44)
                .blur(radius: 22)
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
                    .stroke(state.tintColor.opacity(0.35), lineWidth: 1.5)
                    .frame(width: VFSize.bubbleDiameter + 18,
                           height: VFSize.bubbleDiameter + 18)
                    .scaleEffect(pulseScale)
                    .onAppear {
                        pulseScale = 1.0
                        withAnimation(VFAnimation.pulseLoop) {
                            pulseScale = 1.35
                        }
                    }
                    .onDisappear { pulseScale = 1.0 }
            }

            // ── Neumorphic backdrop circle ──
            Circle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: VFColor.glass1.opacity(1.0), location: 0.0),
                            .init(color: VFColor.glass1.opacity(0.85), location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: VFSize.bubbleDiameter,
                       height: VFSize.bubbleDiameter)
                // Neumorphic shadow pair
                .shadow(color: VFColor.neuLight, radius: 1, x: -1, y: -1)
                .shadow(color: VFColor.neuDark, radius: 8, x: 4, y: 4)
                .overlay(
                    // Top-edge shine
                    Circle()
                        .stroke(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(0.12), location: 0.0),
                                    .init(color: .clear, location: 0.4),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )

            // ── Tinted gradient fill (inner disc) ──
            Circle()
                .fill(state.tintColor.gradient)
                .frame(width: VFSize.bubbleDiameter - 8,
                       height: VFSize.bubbleDiameter - 8)
                .shadow(color: state.tintColor.opacity(0.40), radius: 10, y: 3)
                .overlay(
                    // Subtle top-edge highlight on tinted disc
                    Circle()
                        .stroke(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(0.18), location: 0.0),
                                    .init(color: .clear, location: 0.35),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )

            // ── Icon ──
            Image(systemName: state.sfSymbol)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(VFColor.textOnOverlay)
                .contentTransition(.symbolEffect(.replace))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
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

            // ── Neumorphic pill label ──
            Text(state.label)
                .font(VFFont.bubbleStatus)
                .foregroundStyle(VFColor.textOnOverlay)
                .padding(.horizontal, VFSpacing.md)
                .padding(.vertical, VFSpacing.xs + 1)
                .background(
                    Capsule()
                        .fill(VFColor.glass2)
                        .shadow(color: VFColor.neuDark, radius: 3, x: 2, y: 2)
                        .shadow(color: VFColor.neuLight, radius: 1, x: -1, y: -1)
                        .overlay(
                            Capsule()
                                .stroke(
                                    LinearGradient(
                                        stops: [
                                            .init(color: Color.white.opacity(0.10), location: 0),
                                            .init(color: .clear, location: 0.4),
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        )
                )
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
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
        .layeredDepthBackground()
    }
}
#endif
