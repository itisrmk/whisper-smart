import Foundation
import SwiftUI

/// The five visual states of the dictation overlay.
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

// MARK: - Observable State Bridge

/// Lightweight observable that the overlay/menu-bar UI binds to.
/// Core layer will drive this; UI layer only reads.
final class BubbleStateSubject: ObservableObject {
    @Published var state: BubbleState = .idle
    /// Normalised audio level (0…1) fed from the audio capture pipeline.
    /// Drives the waveform bar heights when `state == .listening`.
    @Published var audioLevel: CGFloat = 0

    /// When `state == .error`, this contains the specific error description
    /// (e.g. "Microphone access denied …"). Used by the overlay label and menu.
    @Published var errorDetail: String = ""

    /// Live partial/final transcript shown as an overlay while recording/transcribing.
    @Published var liveTranscript: String = ""

    /// Lightweight status badges shown in the overlay/settings.
    @Published var activityBadge: String = ""
    @Published var healthBadge: String = ""

    /// Called when the user taps the overlay. Override via `onTap` closure.
    var onTap: (() -> Void)?

    func handleTap() {
        onTap?()
    }

    func transition(to newState: BubbleState, errorDetail: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
            self?.errorDetail = errorDetail ?? ""
            if newState == .idle || newState == .error {
                self?.audioLevel = 0
                self?.liveTranscript = ""
            }
        }
    }

    func updateAudioLevel(_ level: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = min(max(level, 0), 1)
        }
    }

    func updateLiveTranscript(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.liveTranscript = text
        }
    }

    func updateBadges(activity: String, health: String) {
        DispatchQueue.main.async { [weak self] in
            self?.activityBadge = activity
            self?.healthBadge = health
        }
    }
}
