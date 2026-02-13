import XCTest
@testable import iOSWhisperSmart

final class KeyboardLayoutMetricsTests: XCTestCase {
    func testCompactLandscapeUsesCompressedMetrics() {
        let metrics = KeyboardLayoutMetrics.resolve(availableHeight: 210, isCompactLandscape: true)
        XCTAssertEqual(metrics.keyHeight, 32)
        XCTAssertFalse(metrics.showsStatusLabel)
        XCTAssertEqual(metrics.preferredTypingHeight, 216)
    }

    func testRegularHeightUsesNativeLikeMetrics() {
        let metrics = KeyboardLayoutMetrics.resolve(availableHeight: 300, isCompactLandscape: false)
        XCTAssertEqual(metrics.keyHeight, 40)
        XCTAssertTrue(metrics.showsStatusLabel)
        XCTAssertEqual(metrics.dictationPanelHeight, 210)
    }
}
