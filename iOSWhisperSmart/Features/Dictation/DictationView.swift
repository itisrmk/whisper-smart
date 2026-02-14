import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct DictationView: View {
    @EnvironmentObject private var viewModel: DictationViewModel
    @EnvironmentObject private var settings: AppSettings
    @State private var showShareSheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard
                privacyCard
                transcriptCard
                actionRow
            }
            .padding(20)
        }
        .background(WhisperTheme.background.ignoresSafeArea())
        .navigationTitle("WhisperSmart")
        .animation(.easeInOut(duration: 0.22), value: viewModel.state.isCapturing)
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [viewModel.transcript])
        }
        .alert("Permissions Needed", isPresented: $viewModel.permissionDenied) {
            Button("Open Settings") {
                openSystemSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please enable microphone and speech recognition access in Settings.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .startDictationFromIntent)) { _ in
            viewModel.startDictation()
        }
    }

    private var headerCard: some View {
        VStack(spacing: 16) {
            WaveformPlaceholderView(isAnimating: viewModel.state.isCapturing)
                .frame(height: 60)
            MicButton(isActive: viewModel.state.isCapturing) {
                if viewModel.state.isCapturing {
                    viewModel.stopDictation()
                } else {
                    viewModel.startDictation()
                }
            }
            Text(statusTitle)
                .foregroundStyle(WhisperTheme.secondaryText)
                .font(.subheadline.weight(.medium))

            HStack(spacing: 8) {
                Label(settings.outputStyleMode.title, systemImage: "textformat")
                Label(settings.privacyMode.title, systemImage: "lock.shield")
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
        }
        .cardStyle()
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            Text(viewModel.privacyIndicator)
                .font(.footnote)
                .foregroundStyle(WhisperTheme.secondaryText)
            Spacer()
        }
        .cardStyle()
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Transcript")
                .font(.headline)
                .foregroundStyle(WhisperTheme.primaryText)

            Text(viewModel.transcript.isEmpty ? "Start dictation to see live text appear here..." : viewModel.transcript)
                .font(.body)
                .foregroundStyle(viewModel.transcript.isEmpty ? WhisperTheme.secondaryText : WhisperTheme.primaryText)
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                .padding(14)
                .background(WhisperTheme.cardAlt)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .cardStyle()
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.copyToClipboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(WhisperGhostButtonStyle())
            .disabled(viewModel.transcript.isEmpty)

            Button {
                showShareSheet = true
            } label: {
                Label("Share", systemImage: "square.and.arrow.up.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(WhisperPrimaryButtonStyle())
            .disabled(viewModel.transcript.isEmpty)
        }
    }

    private var statusTitle: String {
        switch viewModel.state {
        case .idle:
            return "Tap to start"
        case .listening:
            return "Listening..."
        case .partial:
            return "Capturing in real-time"
        case .final:
            return "Dictation complete"
        case .error(let message):
            return message
        }
    }

    private func openSystemSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}
