import Foundation

enum KeyboardDictationState: Equatable {
    case typing
    case dictationWaiting(startedAt: Date)
    case dictationReady(transcript: String, updatedAt: Date)
}

enum KeyboardDictationEvent {
    case micTapped(now: Date)
    case transcriptAvailable(text: String, updatedAt: Date)
    case cancel
    case confirm
}

struct KeyboardMicFlowStateMachine {
    static func reduce(state: KeyboardDictationState, event: KeyboardDictationEvent) -> KeyboardDictationState {
        switch (state, event) {
        case (_, .micTapped(let now)):
            return .dictationWaiting(startedAt: now)
        case (.dictationWaiting, .transcriptAvailable(let text, let updatedAt)):
            return .dictationReady(transcript: text, updatedAt: updatedAt)
        case (.dictationReady, .transcriptAvailable(let text, let updatedAt)):
            return .dictationReady(transcript: text, updatedAt: updatedAt)
        case (_, .cancel), (_, .confirm):
            return .typing
        case (.typing, .transcriptAvailable):
            return .typing
        }
    }
}
