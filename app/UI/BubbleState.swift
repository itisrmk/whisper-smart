import SwiftUI

/// The five visual states of the floating dictation bubble.
enum BubbleState: String, CaseIterable, Identifiable, Hashable {
    case idle
    case listening
    case transcribing
    case success
    case error

    var id: String { rawValue }

    var tintColor: Color {
        switch self {
        case .idle:         return VFColor.accentFallback
        case .listening:    return VFColor.listening
        case .transcribing: return VFColor.transcribing
        case .success:      return VFColor.success
        case .error:        return VFColor.error
        }
    }

    var sfSymbol: String {
        switch self {
        case .idle:         return "mic.fill"
        case .listening:    return "waveform"
        case .transcribing: return "text.cursor"
        case .success:      return "checkmark"
        case .error:        return "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .idle:         return "Ready"
        case .listening:    return "Listening…"
        case .transcribing: return "Transcribing…"
        case .success:      return "Done"
        case .error:        return "Error"
        }
    }

    var isPulsing: Bool {
        self == .listening
    }
}
