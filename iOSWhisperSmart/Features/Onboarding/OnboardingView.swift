import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct OnboardingView: View {
    @EnvironmentObject private var viewModel: DictationViewModel
    let onContinue: () -> Void

    @State private var showDeniedHelp = false
    @State private var pageIndex = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(title: "Welcome to WhisperSmart", subtitle: "Fast dictation with local-first privacy and optional cloud upgrades.", icon: "waveform.badge.mic"),
        OnboardingPage(title: "How privacy works", subtitle: "Local mode stays on-device. Cloud mode is opt-in and fully controlled in Settings.", icon: "lock.shield.fill"),
        OnboardingPage(title: "Keyboard companion", subtitle: "Use Apple-style typing with 123/ABC modes. Tap Mic in the top row to trigger capture, then insert as soon as the shared transcript is ready.", icon: "keyboard.fill"),
        OnboardingPage(title: "Grant access", subtitle: "We only ask for microphone + speech permissions so live dictation can run.", icon: "checkmark.shield.fill")
    ]

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)

            HStack(spacing: 6) {
                ForEach(Array(pages.indices), id: \.self) { idx in
                    Capsule()
                        .fill(idx == pageIndex ? WhisperTheme.accent : Color.white.opacity(0.2))
                        .frame(width: idx == pageIndex ? 28 : 8, height: 8)
                        .animation(.easeInOut(duration: 0.2), value: pageIndex)
                }
            }

            Image(systemName: pages[pageIndex].icon)
                .font(.system(size: 68))
                .foregroundStyle(WhisperTheme.accent)
                .symbolEffect(.pulse.byLayer, isActive: pageIndex == 2)

            Text(pages[pageIndex].title)
                .font(.largeTitle.bold())
                .foregroundStyle(WhisperTheme.primaryText)

            Text(pages[pageIndex].subtitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(WhisperTheme.secondaryText)
                .padding(.horizontal)

            if pageIndex < pages.count - 1 {
                Button("Continue") {
                    withAnimation {
                        pageIndex += 1
                    }
                }
                .buttonStyle(WhisperPrimaryButtonStyle())
                .padding(.horizontal, 24)
            } else {
                Button("Grant Access & Continue") {
                    viewModel.requestPermissionsOnly { granted in
                        if granted {
                            onContinue()
                        } else {
                            showDeniedHelp = true
                        }
                    }
                }
                .buttonStyle(WhisperPrimaryButtonStyle())
                .padding(.horizontal, 24)
            }

            if showDeniedHelp {
                VStack(spacing: 8) {
                    Text("Permission was denied. You can enable access in iOS Settings.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("Open iOS Settings") {
                        openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Button("Skip") {
                onContinue()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal)
        .background(WhisperTheme.background.ignoresSafeArea())
    }

    private func openSystemSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}

private struct OnboardingPage {
    let title: String
    let subtitle: String
    let icon: String
}
