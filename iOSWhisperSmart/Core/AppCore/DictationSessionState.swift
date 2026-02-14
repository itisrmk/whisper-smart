import Foundation

enum DictationSessionState: Equatable {
    case idle
    case listening
    case partial(String)
    case final(String)
    case error(String)

    var transcript: String {
        switch self {
        case .partial(let value), .final(let value):
            return value
        case .error(let message):
            return "Error: \(message)"
        case .idle, .listening:
            return ""
        }
    }

    var isCapturing: Bool {
        switch self {
        case .listening, .partial:
            return true
        default:
            return false
        }
    }
}

enum DictationSessionEvent {
    case start
    case partial(String)
    case final(String)
    case fail(String)
    case reset
}

enum DictationSessionReducer {
    static func reduce(state: DictationSessionState, event: DictationSessionEvent) -> DictationSessionState {
        switch event {
        case .start:
            return .listening
        case .partial(let text):
            return .partial(text)
        case .final(let text):
            return .final(text)
        case .fail(let message):
            return .error(message)
        case .reset:
            return .idle
        }
    }
}
