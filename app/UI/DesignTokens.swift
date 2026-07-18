import AppKit
import CoreText
import SwiftUI

private extension Color {
    init(hex: Int, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b, opacity: alpha)
    }

    /// Adaptive color that resolves against the current appearance.
    init(light: NSColor, dark: NSColor) {
        self = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    init(lightHex: Int, darkHex: Int, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(
            light: NSColor(
                srgbRed: CGFloat((lightHex >> 16) & 0xFF) / 255.0,
                green: CGFloat((lightHex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(lightHex & 0xFF) / 255.0,
                alpha: lightAlpha
            ),
            dark: NSColor(
                srgbRed: CGFloat((darkHex >> 16) & 0xFF) / 255.0,
                green: CGFloat((darkHex >> 8) & 0xFF) / 255.0,
                blue: CGFloat(darkHex & 0xFF) / 255.0,
                alpha: darkAlpha
            )
        )
    }
}

// MARK: - Color Tokens (Modernist system)
//
// Archivo type, a single red accent, flush-left labels, 2px rules,
// zero corner radius. Light = ink-on-paper; dark = warm-dark macOS surface.

enum VFColor {
    // ── Modernist palette (adaptive light/dark) ──────────────────
    static let bg        = Color(lightHex: 0xF3F2F2, darkHex: 0x1B1A19)
    static let sidebar   = Color(lightHex: 0xEBEAE9, darkHex: 0x211F1E)
    static let chrome    = Color(lightHex: 0xE4E3E3, darkHex: 0x242120)
    static let panel     = Color(lightHex: 0xFFFFFF, darkHex: 0x262322)
    static let panel2    = Color(lightHex: 0xF4F2F2, darkHex: 0x2F2C2B)
    static let text      = Color(lightHex: 0x201E1D, darkHex: 0xF4F3F2)
    static let muted     = Color(lightHex: 0x736F6F, darkHex: 0xA39E9D)
    static let border    = Color(lightHex: 0x201E1D, darkHex: 0xF4F3F2, lightAlpha: 0.13, darkAlpha: 0.12)
    static let border2   = Color(lightHex: 0x201E1D, darkHex: 0xF4F3F2, lightAlpha: 0.24, darkAlpha: 0.24)
    /// Heavy 2px rule under section headers.
    static let rule      = Color(lightHex: 0x201E1D, darkHex: 0xF4F3F2, lightAlpha: 0.85, darkAlpha: 0.55)

    static let accent       = Color(lightHex: 0xEC3013, darkHex: 0xFF563C)
    static let accentDark   = Color(lightHex: 0xDD2B0F, darkHex: 0xFF7358)
    static let accentStrong = Color(lightHex: 0xAE1800, darkHex: 0xFF9783)
    /// Selected/hover wash.
    static let active     = Color(lightHex: 0xFDEEEB, darkHex: 0xFF563C, darkAlpha: 0.13)
    /// Soft accent chip background.
    static let accentSoft = Color(lightHex: 0xFFE0D9, darkHex: 0xFF563C, darkAlpha: 0.16)
    static let knobOff    = Color(lightHex: 0xA29E9E, darkHex: 0x8A8584)

    /// Window background as a dynamic NSColor (for NSWindow chrome).
    static let windowBackgroundNS = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1B / 255.0, green: 0x1A / 255.0, blue: 0x19 / 255.0, alpha: 1)
            : NSColor(srgbRed: 0xF3 / 255.0, green: 0xF2 / 255.0, blue: 0xF2 / 255.0, alpha: 1)
    }

    // ── Semantic ─────────────────────────────────────────────────
    static let success = Color(lightHex: 0x2B8A3E, darkHex: 0x69DB7C)
    static let error   = Color(lightHex: 0xC92A2A, darkHex: 0xFF6B6B)
    static let warning = Color(lightHex: 0xB8860B, darkHex: 0xFFBD57)

    // ── Legacy aliases (settings) ────────────────────────────────
    static let accentFallback = accent
    static let accentHover = accentDark
    static let accentDeep = accentStrong
    static let successFallback = success
    static let successAlt = success

    static let bgBase = bg
    static let bgElevated = panel2
    static let surface1 = panel
    static let surface2 = panel2
    static let surface3 = active
    static let glass0NS = windowBackgroundNS
    static let glass0 = bg
    static let controlInset = panel2
    static let controlTrackOff = panel2
    static let controlKnobTop = Color.white
    static let controlKnobBottom = Color.white

    static let glassBorder = border
    static let glassHighlight = Color.clear

    static let neuLight = Color.clear
    static let neuDark  = Color.black.opacity(0.30)
    static let neuInsetLight = Color.clear
    static let neuInsetDark  = Color.clear

    static let depthRadialTop = Color.clear
    static let depthRadialBottom = Color.clear
    static let depthVignette = Color.clear
    static let textureMeshCool = Color.clear
    static let textureMeshNeutral = Color.clear
    static let textureMeshInk = Color.clear
    static let textureStroke = Color.clear
    static let textureHighlight = Color.clear

    static let surfacePrimary = bg
    static let surfaceOverlay = Color.black.opacity(0.45)
    static let surfaceElevated = panel

    // ── Overlay HUD surfaces (floating bubble / waveform bar) ────
    // The HUD floats over arbitrary screen content, so it stays a fixed
    // warm-dark surface in both appearances.
    static let glass1 = Color(hex: 0x262322)
    static let glass2 = Color(hex: 0x2F2C2B)
    static let glass3 = Color(hex: 0x3A3736)

    // ── Accent gradients (legacy API — now flat fills) ───────────
    static let accentGradient = LinearGradient(
        colors: [accent, accent], startPoint: .top, endPoint: .bottom)
    static let listeningGradient = LinearGradient(
        colors: [accent, accent], startPoint: .top, endPoint: .bottom)
    static let transcribingGradient = LinearGradient(
        colors: [accentDark, accentDark], startPoint: .top, endPoint: .bottom)
    static let successGradient = LinearGradient(
        colors: [success, success], startPoint: .top, endPoint: .bottom)
    static let errorGradient = LinearGradient(
        colors: [error, error], startPoint: .top, endPoint: .bottom)

    // Semantic (flat)
    static let listening    = accent
    static let transcribing = accentDark
    static let warningLegacy = warning

    // Provider preset tints
    static let presetBestTint  = accent
    static let presetCloudTint = accent

    // Text
    static let textPrimary = text
    static let textSecondary = muted
    static let textTertiary = muted
    static let textOnAccent = Color.white
    static let textDisabled = muted.opacity(0.5)
    static let textOnOverlay = Color.white
    static let focusRing = accent
    static let focusGlow = accent.opacity(0.30)
    static let interactiveHover = Color(lightHex: 0x201E1D, darkHex: 0xF4F3F2, lightAlpha: 0.05, darkAlpha: 0.06)
    static let interactivePressed = Color(lightHex: 0x201E1D, darkHex: 0xF4F3F2, lightAlpha: 0.10, darkAlpha: 0.12)
}

// MARK: - Theme Tokens

enum VFTheme {
    static func debugAssertTokenSanity(file: StaticString = #fileID, line: UInt = #line) {
        // Palette is adaptive now; nothing to assert.
    }
}

// MARK: - Typography Tokens (Archivo)

/// Registers the bundled Archivo variable font with CoreText.
/// Falls back to the system font when the resource is missing.
enum VFFontRegistrar {
    private(set) static var archivoAvailable = false
    private static var didAttempt = false

    static func registerIfNeeded() {
        guard !didAttempt else { return }
        didAttempt = true

        if NSFont(name: "Archivo-Regular", size: 12) != nil {
            archivoAvailable = true
            return
        }

        guard let url = fontResourceURL() else {
            NSLog("[VFFont] Archivo font resource not found; using system font")
            return
        }

        var errorRef: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &errorRef)
        if let error = errorRef?.takeRetainedValue() {
            NSLog("[VFFont] Archivo registration note: \(error)")
        }
        archivoAvailable = NSFont(name: "Archivo-Regular", size: 12) != nil
    }

    /// Locates the bundled font without SwiftPM's `Bundle.module` accessor —
    /// that accessor traps at launch in the packaged .app (it never checks
    /// Contents/Resources) and does not exist at all for the raw-swiftc QA
    /// harness builds. Checks every place the resource bundle can live.
    private static func fontResourceURL() -> URL? {
        let bundleName = "WhisperSmart_App.bundle"

        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            // Packaged .app: Contents/Resources/WhisperSmart_App.bundle
            candidates.append(resourceURL.appendingPathComponent(bundleName))
        }
        if let executableURL = Bundle.main.executableURL {
            // swift build / swift run: bundle sits next to the binary
            candidates.append(
                executableURL.deletingLastPathComponent().appendingPathComponent(bundleName)
            )
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))

        for candidate in candidates {
            if let bundle = Bundle(url: candidate),
               let url = bundle.url(
                   forResource: "Archivo-Variable", withExtension: "ttf", subdirectory: "Fonts"
               ) {
                return url
            }
        }

        // Loose fallback: fonts copied directly into the app's Resources.
        return Bundle.main.url(
            forResource: "Archivo-Variable", withExtension: "ttf", subdirectory: "Fonts"
        )
    }
}

// MARK: - Brand Assets

/// Loads the bundled logo mark without SwiftPM's `Bundle.module` accessor —
/// same resolution strategy as `VFFontRegistrar` (that accessor traps at
/// launch in the packaged .app and does not exist for the raw-swiftc QA
/// harness builds).
enum VFBrand {
    /// The app logo mark (dark rounded square, transparent margin cropped).
    /// `nil` when the resource bundle is missing; callers should fall back
    /// to a drawn placeholder.
    static let logo: NSImage? = loadLogo()

    private static func loadLogo() -> NSImage? {
        let bundleName = "WhisperSmart_App.bundle"

        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(bundleName))
        }
        if let executableURL = Bundle.main.executableURL {
            candidates.append(
                executableURL.deletingLastPathComponent().appendingPathComponent(bundleName)
            )
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))

        for candidate in candidates {
            if let bundle = Bundle(url: candidate),
               let url = bundle.url(
                   forResource: "whisper-smart-logo", withExtension: "png", subdirectory: "Brand"
               ),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }

        // Loose fallback: asset copied directly into the app's Resources.
        if let url = Bundle.main.url(
            forResource: "whisper-smart-logo", withExtension: "png", subdirectory: "Brand"
        ) {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

enum VFFont {
    /// Archivo with a graceful system-font fallback.
    static func archivo(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        VFFontRegistrar.registerIfNeeded()
        guard VFFontRegistrar.archivoAvailable else {
            return Font.system(size: size, weight: weight)
        }
        return Font.custom(postScriptName(for: weight), size: size)
    }

    private static func postScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .black, .heavy:  return "Archivo-ExtraBold"
        case .bold:           return "Archivo-Bold"
        case .semibold:       return "Archivo-SemiBold"
        case .medium:         return "Archivo-Medium"
        case .light, .thin, .ultraLight: return "Archivo-Light"
        default:              return "Archivo-Regular"
        }
    }

    static let bubbleStatus    = archivo(11, .medium)
    static let menuItem        = archivo(13)
    static let menuItemBold    = archivo(13, .semibold)

    // Settings hierarchy
    static let settingsHeading   = archivo(33, .heavy)
    static let sheetTitle        = archivo(24, .heavy)
    static let settingsTitle     = archivo(16, .heavy)
    static let settingsBody      = archivo(14, .semibold)
    static let settingsCaption   = archivo(12.5)
    static let settingsFootnote  = archivo(11)

    static let pillLabel       = archivo(12, .bold)
    static let segmentLabel    = archivo(12, .semibold)

    /// Tiny uppercase kicker (stat tiles, badges).
    static let kicker          = archivo(9, .bold)
    /// Large stat value.
    static let statValue       = archivo(20, .heavy)

    // Overlay / bubble
    static let bubbleIcon      = archivo(20, .semibold)
    static let overlayCaption  = archivo(11, .medium)
    static let badgeLabel      = archivo(9, .semibold)
}

// MARK: - Spacing / Layout Tokens

enum VFSpacing {
    static let xxs: CGFloat = 4
    static let xs:  CGFloat = 8
    static let sm:  CGFloat = 12
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 20
    static let xl:  CGFloat = 24
    static let xxl: CGFloat = 28
    static let xxxl: CGFloat = 32
}

/// Modernist system: zero radius everywhere. Circles (radio dots, status
/// dots) are drawn with `Circle()` directly, not radius tokens.
enum VFRadius {
    static let bubble:  CGFloat = 0
    static let card:    CGFloat = 0
    static let pill:    CGFloat = 0
    static let button:  CGFloat = 0
    static let segment: CGFloat = 0
    static let field:   CGFloat = 0
    static let window:  CGFloat = 0
}

enum VFSize {
    static let bubbleDiameter:  CGFloat = 40
    static let menuBarIcon:     CGFloat = 18
    static let settingsWidth:   CGFloat = 900
    static let settingsHeight:  CGFloat = 700
    static let sidebarWidth:    CGFloat = 232

    // Waveform bar layout
    static let waveformBarCount: Int = 5
    static let waveformBarWidth: CGFloat = 3
    static let waveformBarSpacing: CGFloat = 2.5
    static let waveformBarMinHeight: CGFloat = 4
    static let waveformBarMaxHeight: CGFloat = 22
}

// MARK: - Shadow / Depth Tokens

enum VFShadow {
    static let neuRadius: CGFloat = 0
    static let neuOffset: CGFloat = 0
    static let cardColor   = Color.black.opacity(0.10)
    static let cardRadius: CGFloat  = 12
    static let cardY:      CGFloat  = 4
    static let raisedControlColor = Color.black.opacity(0.12)
    static let raisedControlRadius: CGFloat = 4
    static let raisedControlY: CGFloat = 1
    static let focusOuterRadius: CGFloat = 0

    static func glow(color: Color, radius: CGFloat = 20) -> some View {
        Circle().fill(color.opacity(0.28))
            .blur(radius: radius)
    }

    static let innerHighlightOpacity: Double = 0
}

// MARK: - Animation Tokens

enum VFAnimation {
    static let springSnappy  = Animation.easeInOut(duration: 0.18)
    static let springGentle  = Animation.easeInOut(duration: 0.25)
    static let springBounce  = Animation.spring(response: 0.4, dampingFraction: 0.7)
    static let fadeFast      = Animation.easeInOut(duration: 0.15)
    static let fadeMedium    = Animation.easeInOut(duration: 0.22)
    static let successPulse  = Animation.easeOut(duration: 0.38)
    static let pulseLoop     = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)
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

// MARK: - Flat Panel Modifier (legacy name: GlassCard)

/// Modernist panel: flat fill with a hairline border, zero radius.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 0
    var fillColor: Color = VFColor.panel

    func body(content: Content) -> some View {
        content
            .background(
                Rectangle()
                    .fill(fillColor)
                    .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
            )
    }
}

extension View {
    func glassCard(
        cornerRadius: CGFloat = 0,
        fill: Color = VFColor.panel
    ) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, fillColor: fill))
    }
}

// MARK: - Flat Inset Modifier (legacy name: NeuInset)

struct NeuInset: ViewModifier {
    var cornerRadius: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(
                Rectangle()
                    .fill(VFColor.panel2)
                    .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
            )
    }
}

extension View {
    func neuInset(cornerRadius: CGFloat = 0) -> some View {
        modifier(NeuInset(cornerRadius: cornerRadius))
    }
}

// MARK: - Legacy texture layers (now inert — the Modernist system is flat)

struct GrainTexture: View {
    var opacity: Double = 0
    var cellSize: CGFloat = 2

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct StructuredTextureSystem: View {
    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct LayeredDepthBackground: View {
    var body: some View {
        VFColor.bg.ignoresSafeArea()
    }
}

extension View {
    func layeredDepthBackground() -> some View {
        self.background(LayeredDepthBackground())
    }
}

// MARK: - Theme Modifier

/// Settings root modifier. The palette adapts to the system appearance;
/// this just wires the accent tint. (Legacy name kept at call sites.)
struct VFForcedDarkTheme: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(VFColor.accent)
    }
}

extension View {
    func vfForcedDarkTheme() -> some View {
        modifier(VFForcedDarkTheme())
    }
}

// MARK: - Inner Highlight Shape (legacy — inert)

struct InnerHighlightStroke: ViewModifier {
    var cornerRadius: CGFloat = 0

    func body(content: Content) -> some View {
        content
    }
}

extension View {
    func innerHighlight(cornerRadius: CGFloat = 0) -> some View {
        modifier(InnerHighlightStroke(cornerRadius: cornerRadius))
    }
}
