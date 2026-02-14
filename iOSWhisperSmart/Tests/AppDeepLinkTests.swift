import XCTest
@testable import iOSWhisperSmart

final class AppDeepLinkTests: XCTestCase {
    func testParseDictateWithHost() {
        let url = URL(string: "whispersmart://dictate")!
        XCTAssertEqual(AppDeepLink.parse(url), .dictate)
    }

    func testParseDictateWithPath() {
        let url = URL(string: "whispersmart:///dictate")!
        XCTAssertEqual(AppDeepLink.parse(url), .dictate)
    }

    func testParseRejectsUnknownRoute() {
        let url = URL(string: "whispersmart://settings")!
        XCTAssertNil(AppDeepLink.parse(url))
    }
}
