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

// MARK: - Hotkey Settings

private struct HotkeySettingsTab: View {
    /// Index into `HotkeyBinding.presets` (or -1 for custom/unknown).
    @State private var selectedPresetIndex: Int = Self.initialPresetIndex()

    var body: some View {
        Form {
            Section {
                // Current shortcut display
                HStack {
                    Text("Dictation shortcut")
                        .font(VFFont.settingsBody)
                    Spacer()
                    Text(currentDisplayString)
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

                // Preset picker
                Picker("Preset", selection: $selectedPresetIndex) {
                    ForEach(0..<HotkeyBinding.presets.count, id: \.self) { i in
                        Text(HotkeyBinding.presets[i].displayString).tag(i)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedPresetIndex) {
                    applyPreset(at: selectedPresetIndex)
                }

                Text("Select a shortcut preset. Hold the key (or key combo) to start dictation, release to stop.")
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.textSecondary)
            } header: {
                Text("Global Shortcut")
                    .font(VFFont.settingsTitle)
            }
        }
        .formStyle(.grouped)
        .padding(VFSpacing.lg)
    }

    // MARK: - Helpers

    private var currentDisplayString: String {
        if selectedPresetIndex >= 0 && selectedPresetIndex < HotkeyBinding.presets.count {
            return HotkeyBinding.presets[selectedPresetIndex].displayString
        }
        return HotkeyBinding.load().displayString
    }

    private func applyPreset(at index: Int) {
        guard index >= 0 && index < HotkeyBinding.presets.count else { return }
        let binding = HotkeyBinding.presets[index]
        binding.save()
        // Post notification so AppDelegate picks up the change live.
        NotificationCenter.default.post(name: .hotkeyBindingDidChange, object: binding)
    }

    private static func initialPresetIndex() -> Int {
        let current = HotkeyBinding.load()
        return HotkeyBinding.presets.firstIndex(of: current) ?? 0
    }
}

// MARK: - Notification name for binding changes

extension Notification.Name {
    static let hotkeyBindingDidChange = Notification.Name("hotkeyBindingDidChange")
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
