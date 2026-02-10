import SwiftUI

// MARK: - Color Tokens

enum VFColor {
    // Primary brand
    static let accent = Color("AccentBlue", bundle: nil)
    static let accentFallback = Color(red: 0.29, green: 0.56, blue: 1.0) // #4A90FF

    // Surface / chrome
    static let surfacePrimary   = Color(nsColor: .windowBackgroundColor)
    static let surfaceOverlay   = Color.black.opacity(0.72)
    static let surfaceElevated  = Color(nsColor: .controlBackgroundColor)

    // Semantic
    static let listening    = Color(red: 0.29, green: 0.56, blue: 1.0)  // blue pulse
    static let transcribing = Color(red: 0.56, green: 0.40, blue: 1.0)  // purple
    static let success      = Color(red: 0.20, green: 0.78, blue: 0.47) // green
    static let error        = Color(red: 1.0,  green: 0.34, blue: 0.34) // red

    // Text
    static let textPrimary   = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textOnOverlay = Color.white
}

// MARK: - Typography Tokens

enum VFFont {
    static let bubbleStatus  = Font.system(size: 11, weight: .medium, design: .rounded)
    static let menuItem      = Font.system(size: 13, weight: .regular)
    static let menuItemBold  = Font.system(size: 13, weight: .semibold)
    static let settingsTitle = Font.system(size: 15, weight: .semibold)
    static let settingsBody  = Font.system(size: 13, weight: .regular)
    static let settingsCaption = Font.system(size: 11, weight: .regular)
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
    static let bubble:  CGFloat = 22
    static let card:    CGFloat = 10
    static let button:  CGFloat = 6
}

enum VFSize {
    static let bubbleDiameter:  CGFloat = 44
    static let menuBarIcon:     CGFloat = 18
    static let settingsWidth:   CGFloat = 480
    static let settingsHeight:  CGFloat = 400
}

// MARK: - Animation Tokens

enum VFAnimation {
    static let springSnappy  = Animation.spring(response: 0.3, dampingFraction: 0.7)
    static let springGentle  = Animation.spring(response: 0.5, dampingFraction: 0.8)
    static let fadeFast      = Animation.easeInOut(duration: 0.15)
    static let fadeMedium    = Animation.easeInOut(duration: 0.25)
    static let pulseLoop     = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)
}
