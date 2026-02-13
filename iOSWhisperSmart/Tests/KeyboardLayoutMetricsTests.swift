import XCTest
@testable import iOSWhisperSmart

final class KeyboardLayoutMetricsTests: XCTestCase {
    func testCompactLandscapeUsesCompressedMetrics() {
        let metrics = KeyboardLayoutMetrics.resolve(availableHeight: 210, isCompactLandscape: true)
        XCTAssertEqual(metrics.keyHeight, 32)
        XCTAssertFalse(metrics.showsStatusLabel)
        XCTAssertEqual(metrics.preferredTypingHeight, 216)
        XCTAssertEqual(metrics.letterFontSize, 17)
        XCTAssertEqual(metrics.keyContentInsets.top, 3)
    }

    func testRegularHeightUsesNativeLikeMetrics() {
        let metrics = KeyboardLayoutMetrics.resolve(availableHeight: 300, isCompactLandscape: false)
        XCTAssertEqual(metrics.keyHeight, 40)
        XCTAssertTrue(metrics.showsStatusLabel)
        XCTAssertEqual(metrics.dictationPanelHeight, 210)
        XCTAssertEqual(metrics.letterFontSize, 21)
        XCTAssertEqual(metrics.keyCornerRadius, 7)
    }

    func testCompactTypographyFitsWithinKeyHeight() {
        let metrics = KeyboardLayoutMetrics.resolve(availableHeight: 210, isCompactLandscape: true)
        let estimatedGlyphHeight = metrics.letterFontSize + metrics.keyContentInsets.top + metrics.keyContentInsets.bottom
        XCTAssertLessThanOrEqual(estimatedGlyphHeight, metrics.keyHeight)
    }
}
