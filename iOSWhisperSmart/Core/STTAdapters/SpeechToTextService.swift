import Foundation

enum EnginePolicy: String, CaseIterable, Identifiable, Codable {
    case localApple
    case cloudOpenAI
    case balanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localApple:
            return "Local (Apple Speech)"
        case .cloudOpenAI:
            return "Cloud (OpenAI Whisper)"
        case .balanced:
            return "Balanced"
        }
    }

    var details: String {
        switch self {
        case .localApple:
            return "Uses Apple Speech recognition on device/Apple services for live transcription."
        case .cloudOpenAI:
            return "Records audio and sends it to OpenAI transcription API when you stop."
        case .balanced:
            return "Uses local live transcription by default. If cloud is enabled and reachable, it upgrades final transcript with OpenAI and falls back to local on failure."
        }
    }
}

protocol SpeechToTextService: AnyObject {
    var onPartialResult: ((String) -> Void)? { get set }
    var onFinalResult: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func requestPermissions() async -> Bool
    func startRecognition() throws
    func stopRecognition()
}
