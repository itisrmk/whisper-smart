import Foundation

enum ProductOnboardingPreferences {
    private static let completionKey = "productOnboarding.completed.v1"

    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completionKey)
    }

    static var shouldPresentOnLaunch: Bool {
        guard !isCompleted else { return false }
        return STTProviderKind.hasPersistedSelection() == false
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completionKey)
    }

    static func resetForDebug() {
        UserDefaults.standard.removeObject(forKey: completionKey)
    }
}
