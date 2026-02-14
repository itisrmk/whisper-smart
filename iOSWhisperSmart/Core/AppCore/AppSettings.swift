import Foundation

struct ReplacementRule: Codable, Identifiable, Equatable {
    let id: UUID
    var find: String
    var replaceWith: String

    init(id: UUID = UUID(), find: String, replaceWith: String) {
        self.id = id
        self.find = find
        self.replaceWith = replaceWith
    }

    var isValid: Bool {
        !find.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum OutputStyleMode: String, CaseIterable, Identifiable, Codable {
    case message
    case email
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .message: return "Message"
        case .email: return "Email"
        case .notes: return "Notes"
        }
    }

    var details: String {
        switch self {
        case .message: return "Natural chat tone with clean punctuation and light polish."
        case .email: return "Professional email structure with clear greeting, paragraph flow, and respectful sign-off."
        case .notes: return "Structured capture mode with crisp bullets for fast scanning."
        }
    }

    var symbolName: String {
        switch self {
        case .message: return "message.fill"
        case .email: return "envelope.fill"
        case .notes: return "note.text"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var selectedEngine: EnginePolicy {
        didSet { defaults.set(selectedEngine.rawValue, forKey: Keys.engine) }
    }

    @Published var privacyMode: PrivacyMode {
        didSet {
            defaults.set(privacyMode.rawValue, forKey: Keys.privacyMode)
            selectedEngine = privacyMode.mappedEngine
        }
    }

    @Published var retentionPolicy: TranscriptRetentionPolicy {
        didSet { defaults.set(retentionPolicy.rawValue, forKey: Keys.retentionPolicy) }
    }

    @Published var cloudTranscriptionEnabled: Bool {
        didSet { defaults.set(cloudTranscriptionEnabled, forKey: Keys.cloudEnabled) }
    }

    @Published var cloudConsentGranted: Bool {
        didSet { defaults.set(cloudConsentGranted, forKey: Keys.cloudConsent) }
    }

    @Published var outputStyleMode: OutputStyleMode {
        didSet { defaults.set(outputStyleMode.rawValue, forKey: Keys.outputStyleMode) }
    }

    @Published var replacementRules: [ReplacementRule] {
        didSet { persistReplacementRules() }
    }

    @Published var showDebugMetrics: Bool {
        didSet { defaults.set(showDebugMetrics, forKey: Keys.showDebugMetrics) }
    }

    @Published var selectedProviderProfileID: String {
        didSet { defaults.set(selectedProviderProfileID, forKey: Keys.providerProfile) }
    }

    @Published var proTierUnlocked: Bool {
        didSet { defaults.set(proTierUnlocked, forKey: Keys.proTierUnlocked) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let engineRaw = defaults.string(forKey: Keys.engine) ?? EnginePolicy.localApple.rawValue
        let resolvedEngine = EnginePolicy(rawValue: engineRaw) ?? .localApple
        self.selectedEngine = resolvedEngine

        let privacyRaw = defaults.string(forKey: Keys.privacyMode) ?? AppSettings.defaultPrivacyMode(for: resolvedEngine).rawValue
        self.privacyMode = PrivacyMode(rawValue: privacyRaw) ?? .privateOffline

        let retentionRaw = defaults.string(forKey: Keys.retentionPolicy) ?? TranscriptRetentionPolicy.keepForever.rawValue
        self.retentionPolicy = TranscriptRetentionPolicy(rawValue: retentionRaw) ?? .keepForever

        self.cloudTranscriptionEnabled = defaults.bool(forKey: Keys.cloudEnabled)
        self.cloudConsentGranted = defaults.bool(forKey: Keys.cloudConsent)

        let styleRaw = defaults.string(forKey: Keys.outputStyleMode) ?? OutputStyleMode.message.rawValue
        self.outputStyleMode = OutputStyleMode(rawValue: styleRaw) ?? .message

        self.replacementRules = AppSettings.loadReplacementRules(defaults: defaults)
        self.showDebugMetrics = defaults.bool(forKey: Keys.showDebugMetrics)

        let providerID = defaults.string(forKey: Keys.providerProfile) ?? ProviderProfile.appleLocal.id
        self.selectedProviderProfileID = ProviderProfile.allProfiles.contains(where: { $0.id == providerID }) ? providerID : ProviderProfile.appleLocal.id

        self.proTierUnlocked = defaults.bool(forKey: Keys.proTierUnlocked)

        self.selectedEngine = privacyMode.mappedEngine
    }

    var selectedProviderProfile: ProviderProfile {
        ProviderProfile.allProfiles.first(where: { $0.id == selectedProviderProfileID }) ?? .appleLocal
    }

    func addReplacementRule(find: String, replaceWith: String) {
        let newRule = ReplacementRule(find: find, replaceWith: replaceWith)
        guard newRule.isValid else { return }
        replacementRules.append(newRule)
    }

    func updateReplacementRule(id: UUID, find: String, replaceWith: String) {
        guard let index = replacementRules.firstIndex(where: { $0.id == id }) else { return }
        replacementRules[index].find = find
        replacementRules[index].replaceWith = replaceWith
        replacementRules = replacementRules.filter { $0.isValid }
    }

    func removeReplacementRules(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            guard replacementRules.indices.contains(index) else { continue }
            replacementRules.remove(at: index)
        }
    }

    func isFeatureAvailable(_ feature: ProFeature) -> Bool {
        switch feature {
        case .advancedTelemetry, .providerProfiles:
            return proTierUnlocked
        }
    }

    private static func defaultPrivacyMode(for engine: EnginePolicy) -> PrivacyMode {
        switch engine {
        case .localApple: return .privateOffline
        case .balanced: return .balanced
        case .cloudOpenAI: return .cloudFast
        }
    }

    private static func loadReplacementRules(defaults: UserDefaults) -> [ReplacementRule] {
        guard let data = defaults.data(forKey: Keys.replacementRules),
              let decoded = try? JSONDecoder().decode([ReplacementRule].self, from: data) else {
            return []
        }

        return decoded.filter { $0.isValid }
    }

    private func persistReplacementRules() {
        guard let data = try? JSONEncoder().encode(replacementRules) else { return }
        defaults.set(data, forKey: Keys.replacementRules)
    }
}

private enum Keys {
    static let engine = "app.selectedEngine"
    static let privacyMode = "app.privacyMode"
    static let retentionPolicy = "app.retentionPolicy"
    static let cloudEnabled = "app.cloudTranscriptionEnabled"
    static let cloudConsent = "app.cloudConsentGranted"
    static let outputStyleMode = "app.outputStyleMode"
    static let replacementRules = "app.replacementRules"
    static let showDebugMetrics = "app.showDebugMetrics"
    static let providerProfile = "app.providerProfile"
    static let proTierUnlocked = "app.proTierUnlocked"
}
