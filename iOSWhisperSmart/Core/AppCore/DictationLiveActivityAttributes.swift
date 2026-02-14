import Foundation
#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct DictationLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var transcriptPreview: String
        var isCapturing: Bool
    }

    var startedAt: Date
}
#endif
