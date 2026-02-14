import Foundation
import AppIntents

struct StartDictationAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Dictation"
    static var description = IntentDescription("Opens WhisperSmart and starts listening for speech.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .startDictationFromIntent, object: nil)
        return .result()
    }
}

extension Notification.Name {
    static let startDictationFromIntent = Notification.Name("startDictationFromIntent")
}
