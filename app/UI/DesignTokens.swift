import SwiftUI

// MARK: - Color Tokens

enum VFColor {
    // Primary brand
    static let accent = Color("AccentBlue", bundle: nil)
    static let accentFallback = Color(red: 0.35, green: 0.58, blue: 1.0) // #5994FF — slightly brighter for neumorphic

    // ── Neumorphic surface layers ───────────────────────────────
    // Dark neumorphism works by pairing a near-black base with
    // subtle light and shadow edges. These layers step up from
    // the deepest well to the most elevated control.
    static let glass0 = Color(white: 0.08)                      // window / deepest bg
    static let glass1 = Color(white: 0.12)                      // card background
    static let glass2 = Color(white: 0.16)                      // elevated card / hover
    static let glass3 = Color(white: 0.20)                      // pill / control fill

    /// 1-px separator between layers
    static let glassBorder = Color.white.opacity(0.08)
    /// Highlight edge on top of raised surfaces (lit-from-above)
    static let glassHighlight = Color.white.opacity(0.11)

    // ── Neumorphic shadow pairs ─────────────────────────────────
    /// Light edge (top-left source) for raised elements
    static let neuLight = Color.white.opacity(0.07)
    /// Dark edge (bottom-right) for raised elements
    static let neuDark  = Color.black.opacity(0.65)
    /// Inset light edge for pressed/recessed wells
    static let neuInsetLight = Color.white.opacity(0.04)
    /// Inset dark edge for pressed/recessed wells
    static let neuInsetDark  = Color.black.opacity(0.50)

    // ── Depth background radial tints ────────────────────────────
    static let depthRadialTop    = Color(red: 0.12, green: 0.22, blue: 0.46).opacity(0.14)
    static let depthRadialBottom = Color(red: 0.26, green: 0.10, blue: 0.42).opacity(0.10)
    static let depthVignette     = Color(red: 0.06, green: 0.05, blue: 0.14).opacity(0.35)

    // Surface / chrome (backward compat) — fixed dark values to avoid
    // system-appearance leaking light colors into our forced-dark UI.
    static let surfacePrimary   = Color(white: 0.10)
    static let surfaceOverlay   = Color.black.opacity(0.72)
    static let surfaceElevated  = Color(white: 0.14)

    // ── Accent gradients ─────────────────────────────────────────
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.35, green: 0.58, blue: 1.0),
                 Color(red: 0.45, green: 0.38, blue: 1.0)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let listeningGradient = LinearGradient(
        colors: [Color(red: 0.35, green: 0.58, blue: 1.0),
                 Color(red: 0.25, green: 0.48, blue: 0.95)],
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
        colors: [Color(red: 0.22, green: 0.80, blue: 0.50),
                 Color(red: 0.16, green: 0.64, blue: 0.42)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let errorGradient = LinearGradient(
        colors: [Color(red: 1.0, green: 0.36, blue: 0.36),
                 Color(red: 0.85, green: 0.24, blue: 0.24)],
        startPoint: .top,
        endPoint: .bottom
    )

    // Semantic (flat fallbacks)
    static let listening    = Color(red: 0.35, green: 0.58, blue: 1.0)
    static let transcribing = Color(red: 0.56, green: 0.40, blue: 1.0)
    static let success      = Color(red: 0.22, green: 0.80, blue: 0.50)
    static let error        = Color(red: 1.0,  green: 0.36, blue: 0.36)

    // Text — tuned for WCAG-AA contrast on dark surfaces
    static let textPrimary   = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary  = Color.white.opacity(0.40)
    static let textOnOverlay = Color.white
}

// MARK: - Typography Tokens

enum VFFont {
    static let bubbleStatus    = Font.system(size: 11, weight: .medium, design: .rounded)
    static let menuItem        = Font.system(size: 13, weight: .regular)
    static let menuItemBold    = Font.system(size: 13, weight: .semibold)

    // Settings — tighter hierarchy with rounded design for iOS feel
    static let settingsHeading   = Font.system(size: 22, weight: .bold, design: .rounded)
    static let settingsTitle     = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let settingsBody      = Font.system(size: 13, weight: .regular, design: .rounded)
    static let settingsCaption   = Font.system(size: 11, weight: .regular, design: .rounded)
    static let settingsFootnote  = Font.system(size: 10, weight: .regular, design: .rounded)

    static let pillLabel       = Font.system(size: 12, weight: .semibold, design: .rounded)
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
    static let xxxl: CGFloat = 40
}

enum VFRadius {
    static let bubble:  CGFloat = 28
    static let card:    CGFloat = 18        // rounder for neumorphic cards
    static let pill:    CGFloat = 100       // fully rounded pill controls
    static let button:  CGFloat = 12
    static let segment: CGFloat = 14        // segmented control corners
    static let field:   CGFloat = 10        // text fields / small controls
}

enum VFSize {
    static let bubbleDiameter:  CGFloat = 56
    static let menuBarIcon:     CGFloat = 18
    static let settingsWidth:   CGFloat = 520
    static let settingsHeight:  CGFloat = 520

    // Waveform bar layout
    static let waveformBarCount: Int = 5
    static let waveformBarWidth: CGFloat = 3
    static let waveformBarSpacing: CGFloat = 2.5
    static let waveformBarMinHeight: CGFloat = 4
    static let waveformBarMaxHeight: CGFloat = 22
}

// MARK: - Shadow / Depth Tokens

enum VFShadow {
    /// Raised neumorphic shadow — soft outer shadow pair
    static let neuRadius: CGFloat = 10
    static let neuOffset: CGFloat = 5
    /// Card ambient shadow
    static let cardColor   = Color.black.opacity(0.50)
    static let cardRadius: CGFloat  = 16
    static let cardY:      CGFloat  = 6

    /// Glow shadow that matches a tint color (used on bubble)
    static func glow(color: Color, radius: CGFloat = 20) -> some View {
        Circle().fill(color.opacity(0.30))
            .blur(radius: radius)
    }

    /// Inner highlight for top edge of glass card
    static let innerHighlightOpacity: Double = 0.09
}

// MARK: - Animation Tokens

enum VFAnimation {
    static let springSnappy  = Animation.spring(response: 0.3, dampingFraction: 0.72)
    static let springGentle  = Animation.spring(response: 0.5, dampingFraction: 0.8)
    static let springBounce  = Animation.spring(response: 0.4, dampingFraction: 0.6)
    static let fadeFast      = Animation.easeInOut(duration: 0.15)
    static let fadeMedium    = Animation.easeInOut(duration: 0.25)
    static let pulseLoop     = Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)
    static let glowPulse     = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)
    static let shimmer       = Animation.linear(duration: 2.0).repeatForever(autoreverses: false)

    // Waveform bar animation — staggered per-bar loops
    static func waveformBar(index: Int, count: Int) -> Animation {
        let baseDuration = 0.45
        let offset = Double(index) / Double(max(count, 1)) * 0.25
        return Animation
            .easeInOut(duration: baseDuration + offset)
            .repeatForever(autoreverses: true)
            .delay(offset)
    }
}

// MARK: - Neumorphic Card Modifier

/// Applies a dark neumorphic card style: subtle raised appearance with
/// dual-shadow edges (light top-left, dark bottom-right), a thin highlight
/// stroke, and refined inner gradient.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = VFRadius.card
    var fillColor: Color = VFColor.glass1

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Primary fill with vertical gradient lift
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: fillColor.opacity(1.0),  location: 0.0),
                                    .init(color: fillColor.opacity(0.88), location: 1.0),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Subtle grain texture
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .overlay(
                            GrainTexture(opacity: 0.02, cellSize: 2)
                                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        )
                        .allowsHitTesting(false)
                }
                // Neumorphic shadow pair
                .shadow(color: VFColor.neuLight, radius: 1, x: -1, y: -1)
                .shadow(color: VFColor.neuDark,  radius: VFShadow.neuRadius, x: VFShadow.neuOffset, y: VFShadow.neuOffset)
                // Top-edge highlight stroke
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.white.opacity(0.12), location: 0.0),
                                    .init(color: Color.white.opacity(0.03), location: 0.3),
                                    .init(color: .clear, location: 0.55),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )
                // Ambient card shadow
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

// MARK: - Neumorphic Inset Modifier

/// Creates a pressed/recessed appearance — the inverse of a raised card.
/// Used for input fields, wells, and inactive control tracks.
struct NeuInset: ViewModifier {
    var cornerRadius: CGFloat = VFRadius.field

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(white: 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    stops: [
                                        .init(color: VFColor.neuInsetDark, location: 0.0),
                                        .init(color: .clear, location: 0.5),
                                        .init(color: VFColor.neuInsetLight, location: 1.0),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: VFColor.neuInsetDark, radius: 3, x: 2, y: 2)
                    .shadow(color: VFColor.neuInsetLight, radius: 2, x: -1, y: -1)
            )
    }
}

extension View {
    func neuInset(cornerRadius: CGFloat = VFRadius.field) -> some View {
        modifier(NeuInset(cornerRadius: cornerRadius))
    }
}

// MARK: - Grain Texture (procedural, no asset file)

/// A subtle film-grain noise overlay rendered via `Canvas`.
/// Uses a seeded deterministic hash so the pattern is stable across
/// redraws (no flickering).
struct GrainTexture: View {
    var opacity: Double = 0.035
    var cellSize: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let cols = Int(ceil(size.width  / cellSize))
            let rows = Int(ceil(size.height / cellSize))
            for row in 0..<rows {
                for col in 0..<cols {
                    let seed = UInt64(row &* 7919 &+ col &* 6271)
                    let hash = (seed &* 2654435761) & 0xFFFF
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

/// Full-window background compositing:
/// 1. Solid `glass0` base
/// 2. Radial gradient tints for depth
/// 3. Bottom-centre vignette
/// 4. Subtle grain texture overlay
struct LayeredDepthBackground: View {
    var body: some View {
        ZStack {
            VFColor.glass0

            RadialGradient(
                colors: [VFColor.depthRadialTop, .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 500
            )
            RadialGradient(
                colors: [VFColor.depthRadialBottom, .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 440
            )

            RadialGradient(
                colors: [.clear, VFColor.depthVignette],
                center: .center,
                startRadius: 140,
                endRadius: 480
            )

            GrainTexture(opacity: 0.025)
        }
        .ignoresSafeArea()
    }
}

extension View {
    func layeredDepthBackground() -> some View {
        self.background(LayeredDepthBackground())
    }
}

// MARK: - Inner Highlight Shape

/// A top-edge inner highlight for a lit-from-above feel.
struct InnerHighlightStroke: ViewModifier {
    var cornerRadius: CGFloat = VFRadius.card

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.14), location: 0.0),
                            .init(color: Color.white.opacity(0.04), location: 0.25),
                            .init(color: .clear, location: 0.5),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
        )
    }
}

extension View {
    func innerHighlight(cornerRadius: CGFloat = VFRadius.card) -> some View {
        modifier(InnerHighlightStroke(cornerRadius: cornerRadius))
    }
}
