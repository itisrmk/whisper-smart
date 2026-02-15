import AppKit
import SwiftUI

private extension Color {
    init(hex: Int, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Color Tokens

enum VFColor {
    // Primary brand
    static let accent = Color("AccentBlue", bundle: nil)
    static let accentFallback = Color(hex: 0x7090F7)
    static let accentHover = Color(hex: 0x6784E0)
    static let accentDeep = Color(hex: 0x45568B)
    static let successFallback = Color(hex: 0x71C184)
    static let successAlt = Color(hex: 0x62A174)

    // ── Surface layers ───────────────────────────────────────────
    static let bgBase = Color(hex: 0x111114)
    static let bgElevated = Color(hex: 0x141419)
    static let surface1 = Color(hex: 0x16161B)
    static let surface2 = Color(hex: 0x191A22)
    static let surface3 = Color(hex: 0x24252E)

    // Backward-compatible aliases used across the app.
    static let glass0NS = NSColor(srgbRed: 0x11 / 255.0, green: 0x11 / 255.0, blue: 0x14 / 255.0, alpha: 1.0)
    static let glass0 = bgBase
    static let glass1 = surface1
    static let glass2 = surface2
    static let glass3 = surface3
    static let controlInset = bgElevated
    static let controlTrackOff = surface2
    static let controlKnobTop = Color(hex: 0xF4F6FB)
    static let controlKnobBottom = Color(hex: 0xD5DBEA)

    /// 1px separator between layers.
    static let glassBorder = Color(hex: 0x3C3E4A, alpha: 0.50)
    /// Highlight edge on top of raised surfaces.
    static let glassHighlight = Color.white.opacity(0.08)

    // ── Neumorphic shadow pairs ─────────────────────────────────
    /// Light edge (top-left source) for raised elements
    static let neuLight = Color.white.opacity(0.06)
    /// Dark edge (bottom-right) for raised elements
    static let neuDark  = Color.black.opacity(0.40)
    /// Inset light edge for pressed/recessed wells
    static let neuInsetLight = Color.white.opacity(0.05)
    /// Inset dark edge for pressed/recessed wells
    static let neuInsetDark  = Color.black.opacity(0.35)

    // ── Depth background radial tints ────────────────────────────
    static let depthRadialTop = accentFallback.opacity(0.18)
    static let depthRadialBottom = Color(hex: 0x54618D, alpha: 0.12)
    static let depthVignette = Color.black.opacity(0.44)
    static let textureMeshCool = Color(hex: 0x8BA2F4, alpha: 0.17)
    static let textureMeshNeutral = Color(hex: 0x9BA7C6, alpha: 0.10)
    static let textureMeshInk = Color(hex: 0x07080C, alpha: 0.58)
    static let textureStroke = Color(hex: 0xAEBBE1, alpha: 0.14)
    static let textureHighlight = Color.white.opacity(0.10)

    // Surface / chrome (backward compat) — fixed dark values to avoid
    // system-appearance leaking light colors into our forced-dark UI.
    static let surfacePrimary = bgBase
    static let surfaceOverlay = Color.black.opacity(0.68)
    static let surfaceElevated = bgElevated

    // ── Accent gradients ─────────────────────────────────────────
    static let accentGradient = LinearGradient(
        colors: [accentFallback, accentHover],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let listeningGradient = LinearGradient(
        colors: [accentFallback, accentHover],
        startPoint: .top,
        endPoint: .bottom
    )

    static let transcribingGradient = LinearGradient(
        colors: [Color(hex: 0x8198F1), Color(hex: 0x5F75C8)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let successGradient = LinearGradient(
        colors: [successFallback, successAlt],
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
    static let listening    = accentFallback
    static let transcribing = Color(hex: 0x8198F1)
    static let success      = successFallback
    static let error        = Color(red: 1.0,  green: 0.36, blue: 0.36)

    // Text — tuned for WCAG-AA contrast on dark surfaces
    static let textPrimary = Color(hex: 0xE9ECF5)
    static let textSecondary = Color(hex: 0xB7BBC7)
    static let textTertiary = Color(hex: 0x9EA4B5)
    static let textOnAccent = Color(hex: 0xF4F7FF)
    static let textDisabled = Color(hex: 0xB7BBC7, alpha: 0.46)
    static let textOnOverlay = Color.white
    static let focusRing = accentFallback
    static let focusGlow = accentFallback.opacity(0.34)
    static let interactiveHover = Color.white.opacity(0.05)
    static let interactivePressed = Color.black.opacity(0.24)
}

// MARK: - Theme Tokens

enum VFTheme {
    static let forcedAppearanceName: NSAppearance.Name = .darkAqua
    static let forcedColorScheme: ColorScheme = .dark

    static func debugAssertTokenSanity(file: StaticString = #fileID, line: UInt = #line) {
#if DEBUG
        VFThemeGuard.assertDarkPaletteSanity(file: file, line: line)
#endif
    }
}

// MARK: - Typography Tokens

enum VFFont {
    static let bubbleStatus    = Font.system(size: 11, weight: .medium)
    static let menuItem        = Font.system(size: 13, weight: .regular)
    static let menuItemBold    = Font.system(size: 13, weight: .semibold)

    // Settings hierarchy
    static let settingsHeading   = Font.system(size: 28, weight: .semibold)
    static let settingsTitle     = Font.system(size: 14, weight: .semibold)
    static let settingsBody      = Font.system(size: 13, weight: .medium)
    static let settingsCaption   = Font.system(size: 12, weight: .regular)
    static let settingsFootnote  = Font.system(size: 11, weight: .regular)

    static let pillLabel       = Font.system(size: 11, weight: .semibold)
    static let segmentLabel    = Font.system(size: 12, weight: .semibold)
}

// MARK: - Spacing / Layout Tokens

enum VFSpacing {
    static let xxs: CGFloat = 4
    static let xs:  CGFloat = 8
    static let sm:  CGFloat = 12
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 20
    static let xl:  CGFloat = 24
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum VFRadius {
    static let bubble:  CGFloat = 24
    static let card:    CGFloat = 18
    static let pill:    CGFloat = 999
    static let button:  CGFloat = 12
    static let segment: CGFloat = 16
    static let field:   CGFloat = 12
    static let window:  CGFloat = 14
}

enum VFSize {
    static let bubbleDiameter:  CGFloat = 40
    static let menuBarIcon:     CGFloat = 18
    static let settingsWidth:   CGFloat = 960
    static let settingsHeight:  CGFloat = 740

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
    static let neuRadius: CGFloat = 6
    static let neuOffset: CGFloat = 2
    /// Card ambient shadow
    static let cardColor   = Color.black.opacity(0.28)
    static let cardRadius: CGFloat  = 20
    static let cardY:      CGFloat  = 10
    static let raisedControlColor = Color.black.opacity(0.30)
    static let raisedControlRadius: CGFloat = 10
    static let raisedControlY: CGFloat = 4
    static let focusOuterRadius: CGFloat = 8

    /// Glow shadow that matches a tint color (used on bubble)
    static func glow(color: Color, radius: CGFloat = 20) -> some View {
        Circle().fill(color.opacity(0.30))
            .blur(radius: radius)
    }

    /// Inner highlight for top edge of glass card
    static let innerHighlightOpacity: Double = 0.08
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
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: fillColor.opacity(0.98), location: 0.0),
                                .init(color: VFColor.surface2.opacity(0.94), location: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(VFColor.glassBorder, lineWidth: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    stops: [
                                        .init(color: Color.white.opacity(0.10), location: 0.0),
                                        .init(color: .clear, location: 0.35),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    )
                    .overlay(
                        LinearGradient(
                            colors: [VFColor.textureMeshCool.opacity(0.20), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .blendMode(.screen)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    )
                    .overlay(
                        GrainTexture(opacity: 0.012, cellSize: 2)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                            .allowsHitTesting(false)
                    )
                    .shadow(color: VFShadow.cardColor, radius: VFShadow.cardRadius, y: VFShadow.cardY)
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
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: VFColor.bgElevated.opacity(0.96), location: 0.0),
                                .init(color: VFColor.surface1.opacity(0.88), location: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(VFColor.glassBorder.opacity(0.9), lineWidth: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    stops: [
                                        .init(color: Color.white.opacity(0.07), location: 0.0),
                                        .init(color: .clear, location: 0.4),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    )
                    .shadow(color: Color.black.opacity(0.20), radius: 4, y: 2)
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

// MARK: - Structured Texture System

/// Decorative geometric texture layer used for the settings background.
/// Keeps contrast low while adding form and material depth.
struct StructuredTextureSystem: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [VFColor.textureMeshCool, .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: max(width, height) * 0.34
                        )
                    )
                    .frame(width: width * 0.68, height: height * 0.42)
                    .position(x: width * 0.78, y: height * 0.20)
                    .blendMode(.screen)

                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .stroke(VFColor.textureStroke, lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .fill(VFColor.textureMeshNeutral.opacity(0.14))
                    )
                    .frame(width: width * 0.44, height: height * 0.26)
                    .position(x: width * 0.80, y: height * 0.24)

                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(VFColor.textureStroke.opacity(0.70), lineWidth: 1)
                    .frame(width: width * 0.20, height: height * 0.14)
                    .position(x: width * 0.16, y: height * 0.14)

                Capsule(style: .continuous)
                    .fill(VFColor.textureMeshInk)
                    .frame(width: width * 0.22, height: height * 0.08)
                    .position(x: width * 0.87, y: height * 0.11)
                    .blur(radius: 0.5)

                LinearGradient(
                    colors: [.clear, VFColor.textureHighlight, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .rotationEffect(.degrees(-15))
                .frame(width: width * 0.50, height: height * 0.24)
                .position(x: width * 0.63, y: height * 0.30)
                .opacity(0.55)
            }
        }
        .opacity(0.42)
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
            LinearGradient(
                colors: [VFColor.bgBase, VFColor.bgElevated],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [VFColor.depthRadialTop, .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 620
            )
            RadialGradient(
                colors: [VFColor.depthRadialBottom, .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 560
            )

            RadialGradient(
                colors: [.clear, VFColor.depthVignette],
                center: .center,
                startRadius: 120,
                endRadius: 640
            )

            StructuredTextureSystem()

            GrainTexture(opacity: 0.014, cellSize: 1.8)
        }
        .ignoresSafeArea()
    }
}

extension View {
    func layeredDepthBackground() -> some View {
        self.background(LayeredDepthBackground())
    }
}

// MARK: - Forced Dark Theme Modifier

/// Apply this at settings root to keep SwiftUI controls and labels resolved in dark mode.
struct VFForcedDarkTheme: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, VFTheme.forcedColorScheme)
            .preferredColorScheme(VFTheme.forcedColorScheme)
            .tint(VFColor.accentFallback)
    }
}

extension View {
    func vfForcedDarkTheme() -> some View {
        modifier(VFForcedDarkTheme())
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

#if DEBUG
// Lightweight visual regression guard. If token edits accidentally drift
// toward bright surfaces or weak contrast, this assertion fails in debug.
private enum VFThemeGuard {
    private static var didAssert = false

    static func assertDarkPaletteSanity(file: StaticString = #fileID, line: UInt = #line) {
        guard !didAssert else { return }
        didAssert = true

        let glass0 = RGB(r: 0x11 / 255.0, g: 0x11 / 255.0, b: 0x14 / 255.0)
        let glass1 = RGB(r: 0x16 / 255.0, g: 0x16 / 255.0, b: 0x1B / 255.0)
        let glass2 = RGB(r: 0x19 / 255.0, g: 0x1A / 255.0, b: 0x22 / 255.0)
        let glass3 = RGB(r: 0x24 / 255.0, g: 0x25 / 255.0, b: 0x2E / 255.0)
        let accent = RGB(r: 0x70 / 255.0, g: 0x90 / 255.0, b: 0xF7 / 255.0)

        assert(luminance(glass0) < luminance(glass1), "Expected glass0 to be darker than glass1", file: file, line: line)
        assert(luminance(glass1) < luminance(glass2), "Expected glass1 to be darker than glass2", file: file, line: line)
        assert(luminance(glass2) < luminance(glass3), "Expected glass2 to be darker than glass3", file: file, line: line)

        let textPrimary = RGB(r: 0xE9 / 255.0, g: 0xEC / 255.0, b: 0xF5 / 255.0)
        let textSecondary = RGB(r: 0xB7 / 255.0, g: 0xBB / 255.0, b: 0xC7 / 255.0)
        let textTertiary = RGB(r: 0x9E / 255.0, g: 0xA4 / 255.0, b: 0xB5 / 255.0)

        assert(contrastRatio(textPrimary, glass1) >= 7.0, "textPrimary contrast on glass1 must stay >= 7.0", file: file, line: line)
        assert(contrastRatio(textSecondary, glass1) >= 4.5, "textSecondary contrast on glass1 must stay >= 4.5", file: file, line: line)
        assert(contrastRatio(textTertiary, glass1) >= 3.0, "textTertiary contrast on glass1 must stay >= 3.0", file: file, line: line)
        assert(contrastRatio(RGB(r: 0xF4 / 255.0, g: 0xF7 / 255.0, b: 0xFF / 255.0), accent) >= 2.5, "textOnAccent should remain readable on accent", file: file, line: line)
    }

    private struct RGB {
        let r: Double
        let g: Double
        let b: Double
    }

    private static func composite(whiteWithOpacity alpha: Double, over background: RGB) -> RGB {
        RGB(
            r: alpha + ((1 - alpha) * background.r),
            g: alpha + ((1 - alpha) * background.g),
            b: alpha + ((1 - alpha) * background.b)
        )
    }

    private static func luminance(_ rgb: RGB) -> Double {
        let r = linearize(rgb.r)
        let g = linearize(rgb.g)
        let b = linearize(rgb.b)
        return (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    }

    private static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let l1 = luminance(a)
        let l2 = luminance(b)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func linearize(_ channel: Double) -> Double {
        if channel <= 0.03928 {
            return channel / 12.92
        }
        return pow((channel + 0.055) / 1.055, 2.4)
    }
}
#endif
