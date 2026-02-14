import SwiftUI

struct KeyboardTapHostView: View {
    private static let seededTranscript = "LATEST_SNIPPET"

    @State private var text = ""
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard Tap Host")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("keyboard-host-title")

            Text("Seeded transcript: \(Self.seededTranscript)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("keyboard-host-seeded-value")

            TextEditor(text: $text)
                .font(.system(size: 20, weight: .regular, design: .default))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 240)
                .background(Color(uiColor: .secondarySystemBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
                .cornerRadius(12)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .accessibilityIdentifier("keyboard-host-text-view")
                .focused($isEditorFocused)

            Text(text)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("keyboard-host-echo")

            HStack {
                Button("Clear Text") {
                    text = ""
                    isEditorFocused = true
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("keyboard-host-clear")

                Button("Seed Latest Transcript") {
                    seedLatestTranscript()
                    isEditorFocused = true
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("keyboard-host-seed")
            }
        }
        .padding(20)
        .background(WhisperTheme.background)
        .onAppear {
            seedLatestTranscript()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isEditorFocused = true
            }
        }
    }

    private func seedLatestTranscript() {
        KeyboardCompanionStore.shared.clearCache()
        KeyboardCompanionStore.shared.saveFinalTranscript(Self.seededTranscript)
    }
}
