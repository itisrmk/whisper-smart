import SwiftUI

enum AppTab: Hashable {
    case dictate
    case history
    case settings
}

struct RootTabView: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                DictationView()
            }
            .tabItem {
                Label("Dictate", systemImage: "waveform.circle.fill")
            }
            .tag(AppTab.dictate)

            NavigationStack {
                HistoryView()
            }
            .tabItem {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .tag(AppTab.history)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .tag(AppTab.settings)
        }
        .tint(WhisperTheme.accent)
    }
}
