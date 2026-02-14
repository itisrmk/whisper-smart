import Foundation

enum PrivacyMode: String, CaseIterable, Identifiable, Codable {
    case privateOffline
    case balanced
    case cloudFast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privateOffline: return "Private Offline"
        case .balanced: return "Balanced"
        case .cloudFast: return "Cloud Fast"
        }
    }

    var summary: String {
        switch self {
        case .privateOffline:
            return "Audio stays local. Best for strict privacy and offline resilience."
        case .balanced:
            return "Prefers cloud when allowed/reachable, with automatic local fallback."
        case .cloudFast:
            return "Prioritizes OpenAI cloud transcription for speed and quality."
        }
    }

    var mappedEngine: EnginePolicy {
        switch self {
        case .privateOffline: return .localApple
        case .balanced: return .balanced
        case .cloudFast: return .cloudOpenAI
        }
    }
}

enum TranscriptRetentionPolicy: String, CaseIterable, Identifiable, Codable {
    case keepForever
    case days30
    case days7
    case manualOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepForever: return "Keep Forever"
        case .days30: return "Auto-delete after 30 days"
        case .days7: return "Auto-delete after 7 days"
        case .manualOnly: return "Manual only (do not auto-save)"
        }
    }

    var details: String {
        switch self {
        case .keepForever:
            return "History is retained until you manually delete entries."
        case .days30:
            return "Entries older than 30 days are automatically removed."
        case .days7:
            return "Entries older than 7 days are automatically removed."
        case .manualOnly:
            return "Dictation output is not stored in history automatically."
        }
    }

    var retentionInterval: TimeInterval? {
        switch self {
        case .keepForever, .manualOnly:
            return nil
        case .days30:
            return 30 * 24 * 60 * 60
        case .days7:
            return 7 * 24 * 60 * 60
        }
    }
}

enum SubscriptionTier: String, Codable {
    case free
    case pro
}

struct ProviderProfile: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let description: String
    let dataFlowSummary: String
    let supportsCurrentBuild: Bool

    static let appleLocal = ProviderProfile(
        id: "apple.local",
        name: "Apple Local",
        description: "On-device/Apple speech path used for private offline dictation.",
        dataFlowSummary: "Audio remains on-device or Apple speech stack.",
        supportsCurrentBuild: true
    )

    static let openAICloud = ProviderProfile(
        id: "openai.cloud",
        name: "OpenAI Cloud",
        description: "OpenAI Whisper transcription for cloud fast and balanced modes.",
        dataFlowSummary: "Audio clips are uploaded to OpenAI after capture stops.",
        supportsCurrentBuild: true
    )

    static let futureAnthropic = ProviderProfile(
        id: "future.anthropic",
        name: "Future Provider Placeholder",
        description: "Reserved slot for future cloud provider integrations.",
        dataFlowSummary: "No data transfer in current build.",
        supportsCurrentBuild: false
    )

    static let allProfiles: [ProviderProfile] = [.appleLocal, .openAICloud, .futureAnthropic]
}

enum ProFeature: String, CaseIterable, Identifiable {
    case advancedTelemetry
    case providerProfiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .advancedTelemetry: return "Advanced telemetry breakdown"
        case .providerProfiles: return "Provider profile management"
        }
    }
}
