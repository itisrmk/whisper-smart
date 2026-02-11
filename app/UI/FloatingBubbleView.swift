import SwiftUI

/// Floating overlay bubble that visualises dictation state.
///
/// The bubble is designed to be hosted inside a borderless, transparent
/// `NSPanel` so it appears to float above all other windows. During the
/// `listening` state the icon is replaced by animated waveform bars for
/// a superwhisper-like recording feel. Other states keep the SF Symbol
/// icon with state-driven glow and colour.
struct FloatingBubbleView: View {
    let state: BubbleState
    var audioLevel: CGFloat = 0
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

            // ── Centre content: waveform bars when listening, icon otherwise ──
            if state == .listening {
                WaveformBarView(
                    isActive: true,
                    audioLevel: audioLevel,
                    tintColor: VFColor.textOnOverlay
                )
                .transition(.scale.combined(with: .opacity))
            } else {
                Image(systemName: state.sfSymbol)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(VFColor.textOnOverlay)
                    .contentTransition(.symbolEffect(.replace))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .transition(.scale.combined(with: .opacity))
            }
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
    @EnvironmentObject var stateSubject: BubbleStateSubject

    var onTap: (() -> Void)?

    var body: some View {
        VStack(spacing: VFSpacing.sm) {
            FloatingBubbleView(
                state: stateSubject.state,
                audioLevel: stateSubject.audioLevel,
                onTap: onTap
            )

            // ── Neumorphic pill label ──
            Text(bubbleLabelText)
                .font(VFFont.bubbleStatus)
                .foregroundStyle(VFColor.textOnOverlay)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
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
        .animation(VFAnimation.fadeMedium, value: stateSubject.state)
    }

    /// When in error state, show the specific error detail instead of
    /// the generic "Error" label.
    private var bubbleLabelText: String {
        if stateSubject.state == .error && !stateSubject.errorDetail.isEmpty {
            // Truncate for the pill — full message is in the menu/settings.
            let detail = stateSubject.errorDetail
            if detail.count > 60 {
                return String(detail.prefix(57)) + "..."
            }
            return detail
        }
        return stateSubject.state.label
    }
}

// MARK: - Preview

#if DEBUG
struct FloatingBubbleView_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 24) {
            ForEach(BubbleState.allCases) { s in
                FloatingBubbleWithLabel()
                    .environmentObject({
                        let subject = BubbleStateSubject()
                        subject.state = s
                        if s == .listening { subject.audioLevel = 0.6 }
                        return subject
                    }())
            }
        }
        .padding(40)
        .layeredDepthBackground()
    }
}
#endif
