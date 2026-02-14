import SwiftUI
import AppIntents

@main
struct iOSWhisperSmartApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var historyStore: TranscriptHistoryStore
    @StateObject private var metricsStore: ReliabilityMetricsStore
    @StateObject private var viewModel: DictationViewModel
    @State private var selectedTab: AppTab = .dictate
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    private let launchArguments = ProcessInfo.processInfo.arguments

    init() {
        let settings = AppSettings()
        let metrics = ReliabilityMetricsStore()
        let history = TranscriptHistoryStore(retentionPolicy: settings.retentionPolicy, metricsStore: metrics)
        _settings = StateObject(wrappedValue: settings)
        _historyStore = StateObject(wrappedValue: history)
        _metricsStore = StateObject(wrappedValue: metrics)
        _viewModel = StateObject(wrappedValue: DictationViewModel(settings: settings, historyStore: history, metricsStore: metrics))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if launchArguments.contains("-KeyboardTapHost") {
                    KeyboardTapHostView()
                } else if hasCompletedOnboarding {
                    RootTabView(selectedTab: $selectedTab)
                } else {
                    OnboardingView {
                        hasCompletedOnboarding = true
                    }
                }
            }
            .environmentObject(viewModel)
            .environmentObject(settings)
            .environmentObject(historyStore)
            .environmentObject(metricsStore)
            .preferredColorScheme(.dark)
            .background(WhisperTheme.background.ignoresSafeArea())
            .onOpenURL { url in
                guard let deepLink = AppDeepLink.parse(url) else { return }
                handle(deepLink: deepLink)
            }
        }
    }

    private func handle(deepLink: AppDeepLink) {
        switch deepLink {
        case .dictate:
            selectedTab = .dictate
            viewModel.startDictation(source: .keyboardHandoff)
        }
    }
}

struct WhisperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationAppIntent(),
            phrases: ["Start dictation in \(.applicationName)"],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )
    }
}
