import Foundation

enum CloudBlockReason: Equatable {
    case cloudDisabled
    case consentMissing
    case apiKeyMissing
    case networkUnavailable

    var userMessage: String {
        switch self {
        case .cloudDisabled:
            return "Cloud transcription is disabled in Settings."
        case .consentMissing:
            return "Cloud consent is required before audio can be sent to OpenAI."
        case .apiKeyMissing:
            return "OpenAI API key is missing. Add it in Settings."
        case .networkUnavailable:
            return "Network unavailable for cloud transcription."
        }
    }
}

struct CloudTranscriptionPolicyResult: Equatable {
    let isAllowed: Bool
    let reason: CloudBlockReason?

    static let allowed = CloudTranscriptionPolicyResult(isAllowed: true, reason: nil)

    static func blocked(_ reason: CloudBlockReason) -> CloudTranscriptionPolicyResult {
        CloudTranscriptionPolicyResult(isAllowed: false, reason: reason)
    }
}

struct CloudTranscriptionPolicy {
    static func evaluate(
        cloudEnabled: Bool,
        cloudConsentGranted: Bool,
        hasAPIKey: Bool,
        requireNetwork: Bool,
        networkReachable: Bool
    ) -> CloudTranscriptionPolicyResult {
        guard cloudEnabled else { return .blocked(.cloudDisabled) }
        guard cloudConsentGranted else { return .blocked(.consentMissing) }
        guard hasAPIKey else { return .blocked(.apiKeyMissing) }
        if requireNetwork && !networkReachable {
            return .blocked(.networkUnavailable)
        }
        return .allowed
    }
}
