import XCTest
@testable import iOSWhisperSmart

final class KeyboardLaunchAutoStopPolicyTests: XCTestCase {
    func testDoesNotAutoStopWithoutPartial() {
        let policy = KeyboardLaunchAutoStopPolicy(silenceThreshold: 1.5)
        XCTAssertFalse(policy.shouldAutoStop(lastPartialAt: nil, now: Date()))
    }

    func testDoesNotAutoStopBeforeThreshold() {
        let policy = KeyboardLaunchAutoStopPolicy(silenceThreshold: 1.5)
        let now = Date()
        let lastPartial = now.addingTimeInterval(-1.0)
        XCTAssertFalse(policy.shouldAutoStop(lastPartialAt: lastPartial, now: now))
    }

    func testAutoStopsAfterThreshold() {
        let policy = KeyboardLaunchAutoStopPolicy(silenceThreshold: 1.5)
        let now = Date()
        let lastPartial = now.addingTimeInterval(-1.6)
        XCTAssertTrue(policy.shouldAutoStop(lastPartialAt: lastPartial, now: now))
    }
}
