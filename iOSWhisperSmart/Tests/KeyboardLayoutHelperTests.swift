import XCTest
@testable import iOSWhisperSmart

final class KeyboardLayoutHelperTests: XCTestCase {
    func testLetterRowsReturnsLowercaseByDefault() {
        let rows = KeyboardLayoutHelper.letterRows(isShiftEnabled: false)
        XCTAssertEqual(rows.first?.first, "q")
        XCTAssertEqual(rows[1][0], "a")
    }

    func testLetterRowsReturnsUppercaseWhenShiftEnabled() {
        let rows = KeyboardLayoutHelper.letterRows(isShiftEnabled: true)
        XCTAssertEqual(rows.first?.first, "Q")
        XCTAssertEqual(rows[2].last, "M")
    }

    func testRowsReturnsSymbolsInNumberMode() {
        let rows = KeyboardLayoutHelper.rows(for: .numbersAndSymbols, isShiftEnabled: true)
        XCTAssertEqual(rows.first?.first, "1")
        XCTAssertEqual(rows[1].last, "\"")
    }

    func testRowsReturnsLettersInLetterMode() {
        let rows = KeyboardLayoutHelper.rows(for: .letters, isShiftEnabled: false)
        XCTAssertEqual(rows[0], ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"])
    }

    func testCompactSnippetsRespectsLimit() {
        let snippets = (1...5).map { KeyboardSnippet(text: "snippet-\($0)") }
        let compact = KeyboardLayoutHelper.compactSnippets(from: snippets, limit: 3)
        XCTAssertEqual(compact.count, 3)
        XCTAssertEqual(compact.first?.text, "snippet-1")
    }
}
