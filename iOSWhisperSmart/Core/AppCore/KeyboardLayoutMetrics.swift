import UIKit

struct KeyboardLayoutMetrics: Equatable {
    let keyHeight: CGFloat
    let rowMinimumHeight: CGFloat
    let accessoryHeight: CGFloat
    let stackSpacing: CGFloat
    let showsStatusLabel: Bool
    let dictationPanelHeight: CGFloat
    let preferredTypingHeight: CGFloat
    let preferredDictationHeight: CGFloat
    let keyCornerRadius: CGFloat
    let letterFontSize: CGFloat
    let modifierFontSize: CGFloat
    let keyContentInsets: UIEdgeInsets

    static func resolve(availableHeight: CGFloat, isCompactLandscape: Bool) -> KeyboardLayoutMetrics {
        if isCompactLandscape || availableHeight <= 220 {
            return KeyboardLayoutMetrics(
                keyHeight: 32,
                rowMinimumHeight: 32,
                accessoryHeight: 30,
                stackSpacing: 4,
                showsStatusLabel: false,
                dictationPanelHeight: max(150, availableHeight - 16),
                preferredTypingHeight: 216,
                preferredDictationHeight: 204,
                keyCornerRadius: 5,
                letterFontSize: 17,
                modifierFontSize: 13,
                keyContentInsets: UIEdgeInsets(top: 1, left: 3, bottom: 1, right: 3)
            )
        }

        if availableHeight <= 248 {
            return KeyboardLayoutMetrics(
                keyHeight: 36,
                rowMinimumHeight: 36,
                accessoryHeight: 34,
                stackSpacing: 5,
                showsStatusLabel: false,
                dictationPanelHeight: max(176, availableHeight - 16),
                preferredTypingHeight: 228,
                preferredDictationHeight: 220,
                keyCornerRadius: 6,
                letterFontSize: 20,
                modifierFontSize: 15,
                keyContentInsets: UIEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
            )
        }

        return KeyboardLayoutMetrics(
            keyHeight: 40,
            rowMinimumHeight: 40,
            accessoryHeight: 36,
            stackSpacing: 6,
            showsStatusLabel: true,
            dictationPanelHeight: min(210, availableHeight - 14),
            preferredTypingHeight: 256,
            preferredDictationHeight: 238,
            keyCornerRadius: 7,
            letterFontSize: 22,
            modifierFontSize: 16,
            keyContentInsets: UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        )
    }
}
