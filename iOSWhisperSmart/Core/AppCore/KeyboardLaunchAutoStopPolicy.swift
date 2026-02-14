import Foundation

struct KeyboardLaunchAutoStopPolicy {
    let silenceThreshold: TimeInterval

    init(silenceThreshold: TimeInterval = 1.5) {
        self.silenceThreshold = silenceThreshold
    }

    func shouldAutoStop(lastPartialAt: Date?, now: Date) -> Bool {
        guard let lastPartialAt else { return false }
        return now.timeIntervalSince(lastPartialAt) >= silenceThreshold
    }
}
