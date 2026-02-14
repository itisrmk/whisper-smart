import ActivityKit
import WidgetKit
import SwiftUI

@available(iOS 16.1, *)
struct DictationLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationLiveActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.state.isCapturing ? "WhisperSmart is listening" : "WhisperSmart finished")
                    .font(.headline)
                Text(context.state.transcriptPreview)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .activityBackgroundTint(Color.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isCapturing ? "waveform" : "checkmark.seal")
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.transcriptPreview)
                        .lineLimit(2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.isCapturing ? "Live" : "Done")
                        .font(.caption.bold())
                }
            } compactLeading: {
                Image(systemName: context.state.isCapturing ? "waveform" : "checkmark")
            } compactTrailing: {
                Text(context.state.isCapturing ? "Rec" : "End")
                    .font(.caption2)
            } minimal: {
                Image(systemName: "mic.fill")
            }
            .widgetURL(URL(string: "iOSWhisperSmart://dictation"))
            .keylineTint(.orange)
        }
    }
}
