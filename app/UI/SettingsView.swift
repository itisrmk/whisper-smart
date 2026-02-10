import SwiftUI

/// Root settings view hosted in its own `NSWindow`.
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            HotkeySettingsTab()
                .tabItem { Label("Hotkey", systemImage: "command") }
                .tag(SettingsTab.hotkey)

            ProviderSettingsTab()
                .tabItem { Label("Provider", systemImage: "cloud") }
                .tag(SettingsTab.provider)
        }
        .frame(width: VFSize.settingsWidth, height: VFSize.settingsHeight)
    }
}

// MARK: - Tab Enum

private enum SettingsTab: Hashable {
    case general, hotkey, provider
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showBubble")    private var showBubble = true

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Show floating bubble", isOn: $showBubble)
            } header: {
                Text("Behavior")
                    .font(VFFont.settingsTitle)
            }
        }
        .formStyle(.grouped)
        .padding(VFSpacing.lg)
    }
}

// MARK: - Hotkey Picker (Placeholder)

private struct HotkeySettingsTab: View {
    var body: some View {
        Form {
            Section {
                HotkeyPickerPlaceholder()
            } header: {
                Text("Global Shortcut")
                    .font(VFFont.settingsTitle)
            }
        }
        .formStyle(.grouped)
        .padding(VFSpacing.lg)
    }
}

/// Placeholder view for the hotkey picker.
/// Replace this with a real key-recording control once the
/// input-handling layer is implemented.
struct HotkeyPickerPlaceholder: View {
    @State private var displayedShortcut: String = "⌥ Space"

    var body: some View {
        HStack {
            Text("Dictation shortcut")
                .font(VFFont.settingsBody)

            Spacer()

            Text(displayedShortcut)
                .font(VFFont.settingsBody)
                .padding(.horizontal, VFSpacing.sm)
                .padding(.vertical, VFSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: VFRadius.button)
                        .fill(VFColor.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.button)
                        .stroke(VFColor.textSecondary.opacity(0.3), lineWidth: 1)
                )
        }

        Text("Click the shortcut area to record a new hotkey (coming soon).")
            .font(VFFont.settingsCaption)
            .foregroundStyle(VFColor.textSecondary)
    }
}

// MARK: - Provider Settings (Placeholder)

private struct ProviderSettingsTab: View {
    var body: some View {
        Form {
            Section {
                ProviderSettingsPlaceholder()
            } header: {
                Text("Transcription Provider")
                    .font(VFFont.settingsTitle)
            }
        }
        .formStyle(.grouped)
        .padding(VFSpacing.lg)
    }
}

/// Placeholder for provider configuration (API keys, model selection, etc.).
struct ProviderSettingsPlaceholder: View {
    @State private var selectedProvider = "Whisper (local)"

    private let providers = [
        "Whisper (local)",
        "OpenAI Whisper API",
        "Deepgram",
        "AssemblyAI",
    ]

    var body: some View {
        Picker("Provider", selection: $selectedProvider) {
            ForEach(providers, id: \.self) { p in
                Text(p).tag(p)
            }
        }
        .pickerStyle(.menu)

        Text("Provider-specific settings will appear here once the core transcription layer is connected.")
            .font(VFFont.settingsCaption)
            .foregroundStyle(VFColor.textSecondary)
    }
}

// MARK: - Preview

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
#endif
