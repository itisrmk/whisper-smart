import SwiftUI

// MARK: - Color Tokens

enum VFColor {
    // Primary brand
    static let accent = Color("AccentBlue", bundle: nil)
    static let accentFallback = Color(red: 0.29, green: 0.56, blue: 1.0) // #4A90FF

    // ── Layered dark glass surfaces ──────────────────────────────
    // Ordered from deepest to most elevated. Each layer adds a
    // subtle brightness bump to create perceptible depth, inspired
    // by iOS dark-mode material layering.
    static let glass0 = Color(white: 0.04)                      // window / deepest bg
    static let glass1 = Color(white: 0.09)                      // card background
    static let glass2 = Color(white: 0.13)                      // elevated card / hover
    static let glass3 = Color(white: 0.17)                      // pill / control fill

    /// 1-px separator between glass layers
    static let glassBorder = Color.white.opacity(0.07)
    /// Highlight edge on top of glass cards (subtle shine)
    static let glassHighlight = Color.white.opacity(0.10)

    // ── Depth background radial tints ────────────────────────────
    /// Faint accent radial glow placed behind content for depth.
    /// The cool top tint and warm bottom tint produce an immersive
    /// dark environment reminiscent of iOS Control Centre.
    static let depthRadialTop    = Color(red: 0.14, green: 0.28, blue: 0.58).opacity(0.18)
    static let depthRadialBottom = Color(red: 0.32, green: 0.12, blue: 0.52).opacity(0.12)
    /// Secondary warm vignette anchored at bottom-centre
    static let depthVignette     = Color(red: 0.08, green: 0.06, blue: 0.18).opacity(0.40)

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
    static let cardColor   = Color.black.opacity(0.55)
    static let cardRadius: CGFloat  = 18
    static let cardY:      CGFloat  = 8

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

/// Applies the standard glass-card styling: dark fill with subtle
/// vertical gradient lift, 1-px border, refined top-edge highlight
/// with multi-stop fade, and depth shadow.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = VFRadius.card
    var fillColor: Color = VFColor.glass1

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Primary fill with a stronger vertical lift
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: fillColor.opacity(1.0),  location: 0.0),
                                    .init(color: fillColor.opacity(0.90), location: 0.5),
                                    .init(color: fillColor.opacity(0.78), location: 1.0),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Subtle inner noise for texture
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .overlay(
                            GrainTexture(opacity: 0.025, cellSize: 2)
                                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        )
                        .allowsHitTesting(false)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(VFColor.glassBorder, lineWidth: 1)
                )
                .overlay(
                    // Multi-stop top-edge highlight for a more
                    // realistic lit-from-above shine
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(0.15), location: 0.0),
                                    .init(color: Color.white.opacity(0.05), location: 0.25),
                                    .init(color: .clear, location: 0.50),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
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

// MARK: - Grain Texture (procedural, no asset file)

/// A subtle film-grain noise overlay rendered via `Canvas`.
/// Uses a seeded deterministic hash so the pattern is stable across
/// redraws (no flickering). Intensity is kept very low to add texture
/// without hurting readability.
///
/// The grain uses a two-octave hash: coarse cells provide base
/// variation while a secondary finer offset adds micro-texture,
/// producing an organic film-stock feel.
struct GrainTexture: View {
    var opacity: Double = 0.035
    /// Grid cell size in points — smaller = finer grain, higher cost.
    var cellSize: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width  / cellSize))
            let rows = Int(ceil(size.height / cellSize))
            for row in 0..<rows {
                for col in 0..<cols {
                    // Primary deterministic pseudo-random brightness
                    let seed = UInt64(row &* 7919 &+ col &* 6271)
                    let hash = (seed &* 2654435761) & 0xFFFF
                    // Secondary octave for micro-variation
                    let seed2 = UInt64(row &* 4217 &+ col &* 8923)
                    let hash2 = (seed2 &* 2246822519) & 0xFFFF
                    let brightness = (Double(hash) + Double(hash2) * 0.4) / (65535.0 * 1.4)
                    let rect = CGRect(
                        x: CGFloat(col) * cellSize,
                        y: CGFloat(row) * cellSize,
                        width: cellSize,
                        height: cellSize
                    )
                    context.fill(
                        Path(rect),
                        with: .color(Color.white.opacity(brightness))
                    )
                }
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Layered Depth Background

/// Full-window background that composites:
/// 1. Solid `glass0` base
/// 2. Two radial gradient tints for depth (cool top-left, warm bottom-right)
/// 3. Bottom-centre vignette for an iOS-like recessed feel
/// 4. Subtle dual-octave grain texture overlay
///
/// Apply via `.layeredDepthBackground()` on any container.
struct LayeredDepthBackground: View {
    var body: some View {
        ZStack {
            // 1. Solid base — deepest dark
            VFColor.glass0

            // 2. Radial tints — wider spread for immersive depth
            RadialGradient(
                colors: [VFColor.depthRadialTop, .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [VFColor.depthRadialBottom, .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 460
            )

            // 3. Bottom-centre vignette — warm dark edge
            RadialGradient(
                colors: [.clear, VFColor.depthVignette],
                center: .center,
                startRadius: 120,
                endRadius: 500
            )

            // 4. Film grain
            GrainTexture()
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Replaces the view's background with the layered depth treatment.
    func layeredDepthBackground() -> some View {
        self.background(LayeredDepthBackground())
    }
}

// MARK: - Inner Highlight Shape

/// A top-edge inner highlight rendered as an inset stroke that fades
/// from bright to transparent. Gives glass cards a lit-from-above feel.
struct InnerHighlightStroke: ViewModifier {
    var cornerRadius: CGFloat = VFRadius.card

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.18), location: 0.0),
                            .init(color: Color.white.opacity(0.06), location: 0.25),
                            .init(color: .clear, location: 0.5),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
    }
}

extension View {
    func innerHighlight(cornerRadius: CGFloat = VFRadius.card) -> some View {
        modifier(InnerHighlightStroke(cornerRadius: cornerRadius))
    }
}
