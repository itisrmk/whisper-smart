import SwiftUI

enum WhisperTheme {
    static let background = LinearGradient(
        colors: [Color(red: 0.06, green: 0.07, blue: 0.12), Color(red: 0.03, green: 0.04, blue: 0.07)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let card = Color.white.opacity(0.08)
    static let cardAlt = Color.white.opacity(0.06)
    static let accent = Color(red: 0.42, green: 0.6, blue: 1.0)
    static let accentSoft = Color(red: 0.42, green: 0.6, blue: 1.0).opacity(0.2)
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.7)
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(WhisperTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            }
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardModifier())
    }
}

struct MicButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isActive ? Color.red.opacity(0.22) : WhisperTheme.accentSoft)
                    .frame(width: 120, height: 120)
                    .blur(radius: 10)

                Circle()
                    .fill(isActive ? Color.red : WhisperTheme.accent)
                    .frame(width: 84, height: 84)
                    .overlay {
                        Image(systemName: isActive ? "stop.fill" : "mic.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isActive ? 1.04 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.72), value: isActive)
        .accessibilityLabel(isActive ? "Stop Dictation" : "Start Dictation")
    }
}

struct WaveformPlaceholderView: View {
    let isAnimating: Bool

    @State private var phase: CGFloat = 0

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                var path = Path()
                let midY = size.height / 2
                let amplitude: CGFloat = isAnimating ? 12 : 4

                path.move(to: CGPoint(x: 0, y: midY))
                for x in stride(from: 0, through: size.width, by: 2) {
                    let relative = x / size.width
                    let wave = sin((relative * 8 + time * 2 + phase) * .pi)
                    let y = midY + wave * amplitude
                    path.addLine(to: CGPoint(x: x, y: y))
                }

                context.stroke(path, with: .color(WhisperTheme.accent), lineWidth: 3)
            }
        }
        .onAppear { phase = .random(in: 0...1) }
    }
}

struct WhisperPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 14)
            .font(.headline)
            .foregroundStyle(Color.white)
            .background(WhisperTheme.accent.opacity(configuration.isPressed ? 0.7 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct WhisperGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 14)
            .font(.headline)
            .foregroundStyle(WhisperTheme.primaryText)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
