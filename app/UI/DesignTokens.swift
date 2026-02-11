import SwiftUI

// MARK: - Color Tokens

enum VFColor {
    // Primary brand
    static let accent = Color("AccentBlue", bundle: nil)
    static let accentFallback = Color(red: 0.29, green: 0.56, blue: 1.0) // #4A90FF

    // ── Layered dark glass surfaces ──────────────────────────────
    // Ordered from deepest to most elevated. Each layer adds a
    // subtle brightness bump to create perceptible depth.
    static let glass0 = Color(white: 0.06)                      // window / deepest bg
    static let glass1 = Color(white: 0.10)                      // card background
    static let glass2 = Color(white: 0.14)                      // elevated card / hover
    static let glass3 = Color(white: 0.18)                      // pill / control fill

    /// 1-px separator between glass layers
    static let glassBorder = Color.white.opacity(0.08)
    /// Highlight edge on top of glass cards (subtle shine)
    static let glassHighlight = Color.white.opacity(0.12)

    // Surface / chrome (kept for backward compat)
    static let surfacePrimary   = Color(nsColor: .windowBackgroundColor)
    static let surfaceOverlay   = Color.black.opacity(0.72)
    static let surfaceElevated  = Color(nsColor: .controlBackgroundColor)

    // ── Accent gradients ─────────────────────────────────────────
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.33, green: 0.55, blue: 1.0),
                 Color(red: 0.45, green: 0.35, blue: 1.0)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let listeningGradient = LinearGradient(
        colors: [Color(red: 0.29, green: 0.56, blue: 1.0),
                 Color(red: 0.20, green: 0.45, blue: 0.95)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let transcribingGradient = LinearGradient(
        colors: [Color(red: 0.56, green: 0.40, blue: 1.0),
                 Color(red: 0.40, green: 0.25, blue: 0.90)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let successGradient = LinearGradient(
        colors: [Color(red: 0.20, green: 0.78, blue: 0.47),
                 Color(red: 0.15, green: 0.62, blue: 0.40)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let errorGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.34, blue: 0.34),
                 Color(red: 0.85, green: 0.22, blue: 0.22)],
        startPoint: .top,
        endPoint: .bottom
    )

    // Semantic (flat fallbacks)
    static let listening    = Color(red: 0.29, green: 0.56, blue: 1.0)
    static let transcribing = Color(red: 0.56, green: 0.40, blue: 1.0)
    static let success      = Color(red: 0.20, green: 0.78, blue: 0.47)
    static let error        = Color(red: 1.0,  green: 0.34, blue: 0.34)

    // Text
    static let textPrimary   = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary  = Color.white.opacity(0.35)
    static let textOnOverlay = Color.white
}

// MARK: - Typography Tokens

enum VFFont {
    static let bubbleStatus    = Font.system(size: 11, weight: .medium, design: .rounded)
    static let menuItem        = Font.system(size: 13, weight: .regular)
    static let menuItemBold    = Font.system(size: 13, weight: .semibold)
    static let settingsHeading = Font.system(size: 20, weight: .bold, design: .rounded)
    static let settingsTitle   = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let settingsBody    = Font.system(size: 13, weight: .regular)
    static let settingsCaption = Font.system(size: 11, weight: .regular)
    static let pillLabel       = Font.system(size: 12, weight: .medium, design: .rounded)
    static let segmentLabel    = Font.system(size: 13, weight: .medium, design: .rounded)
}

// MARK: - Spacing / Layout Tokens

enum VFSpacing {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 24
    static let xxl: CGFloat = 32
}

enum VFRadius {
    static let bubble:  CGFloat = 28        // larger for glass bubble
    static let card:    CGFloat = 16        // rounder glass cards
    static let pill:    CGFloat = 100       // fully rounded pill controls
    static let button:  CGFloat = 10
    static let segment: CGFloat = 12        // segmented control corners
}

enum VFSize {
    static let bubbleDiameter:  CGFloat = 56    // slightly larger glass bubble
    static let menuBarIcon:     CGFloat = 18
    static let settingsWidth:   CGFloat = 500
    static let settingsHeight:  CGFloat = 480
}

// MARK: - Shadow / Depth Tokens

enum VFShadow {
    /// Subtle ambient shadow for glass cards
    static let cardColor   = Color.black.opacity(0.45)
    static let cardRadius: CGFloat  = 16
    static let cardY:      CGFloat  = 6

    /// Glow shadow that matches a tint color (used on bubble)
    static func glow(color: Color, radius: CGFloat = 20) -> some View {
        Circle().fill(color.opacity(0.30))
            .blur(radius: radius)
    }

    /// Inner highlight for top edge of glass card
    static let innerHighlightOpacity: Double = 0.10
}

// MARK: - Animation Tokens

enum VFAnimation {
    static let springSnappy  = Animation.spring(response: 0.3, dampingFraction: 0.7)
    static let springGentle  = Animation.spring(response: 0.5, dampingFraction: 0.8)
    static let springBounce  = Animation.spring(response: 0.4, dampingFraction: 0.6)
    static let fadeFast      = Animation.easeInOut(duration: 0.15)
    static let fadeMedium    = Animation.easeInOut(duration: 0.25)
    static let pulseLoop     = Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)
    static let glowPulse     = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)
    static let shimmer       = Animation.linear(duration: 2.0).repeatForever(autoreverses: false)
}

// MARK: - Glass Card Modifier

/// Applies the standard glass-card styling: dark fill, 1-px border,
/// top highlight edge, and depth shadow.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = VFRadius.card
    var fillColor: Color = VFColor.glass1

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(VFColor.glassBorder, lineWidth: 1)
                    )
                    .overlay(
                        // Top-edge highlight shine
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [VFColor.glassHighlight, .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: VFShadow.cardColor,
                        radius: VFShadow.cardRadius,
                        y: VFShadow.cardY
                    )
            )
    }
}

extension View {
    func glassCard(
        cornerRadius: CGFloat = VFRadius.card,
        fill: Color = VFColor.glass1
    ) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, fillColor: fill))
    }
}
