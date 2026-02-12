import AppKit

final class RecordingSoundPlayer {
    static let shared = RecordingSoundPlayer()

    private let startSound: NSSound?
    private let stopSound: NSSound?

    private init() {
        startSound = RecordingSoundPlayer.makeSound(named: "Pop")
        stopSound = RecordingSoundPlayer.makeSound(named: "Tink")
    }

    func playStartIfEnabled() {
        guard DictationOverlaySettings.recordingSoundsEnabled else { return }
        startSound?.play()
    }

    func playStopIfEnabled() {
        guard DictationOverlaySettings.recordingSoundsEnabled else { return }
        stopSound?.play()
    }

    private static func makeSound(named name: String) -> NSSound? {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return NSSound(contentsOf: url, byReference: true)
    }
}
