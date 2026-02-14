import XCTest
@testable import iOSWhisperSmart

final class CloudTranscriptionPolicyTests: XCTestCase {
    func testCloudBlockedWhenCloudToggleOff() {
        let result = CloudTranscriptionPolicy.evaluate(
            cloudEnabled: false,
            cloudConsentGranted: true,
            hasAPIKey: true,
            requireNetwork: false,
            networkReachable: true
        )

        XCTAssertFalse(result.isAllowed)
        XCTAssertEqual(result.reason, .cloudDisabled)
    }

    func testCloudBlockedWhenConsentMissing() {
        let result = CloudTranscriptionPolicy.evaluate(
            cloudEnabled: true,
            cloudConsentGranted: false,
            hasAPIKey: true,
            requireNetwork: false,
            networkReachable: true
        )

        XCTAssertFalse(result.isAllowed)
        XCTAssertEqual(result.reason, .consentMissing)
    }

    func testCloudBlockedWhenAPIKeyMissing() {
        let result = CloudTranscriptionPolicy.evaluate(
            cloudEnabled: true,
            cloudConsentGranted: true,
            hasAPIKey: false,
            requireNetwork: false,
            networkReachable: true
        )

        XCTAssertFalse(result.isAllowed)
        XCTAssertEqual(result.reason, .apiKeyMissing)
    }

    func testBalancedCloudBlockedWhenNetworkRequiredAndUnavailable() {
        let result = CloudTranscriptionPolicy.evaluate(
            cloudEnabled: true,
            cloudConsentGranted: true,
            hasAPIKey: true,
            requireNetwork: true,
            networkReachable: false
        )

        XCTAssertFalse(result.isAllowed)
        XCTAssertEqual(result.reason, .networkUnavailable)
    }

    func testCloudAllowedWhenAllRequirementsMet() {
        let result = CloudTranscriptionPolicy.evaluate(
            cloudEnabled: true,
            cloudConsentGranted: true,
            hasAPIKey: true,
            requireNetwork: false,
            networkReachable: false
        )

        XCTAssertTrue(result.isAllowed)
        XCTAssertNil(result.reason)
    }
}
