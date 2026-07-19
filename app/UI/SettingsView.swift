import SwiftUI
import Carbon.HIToolbox
import AppKit

/// Root settings view hosted in its own `NSWindow`.
/// Modernist design: Archivo type, a single red accent, flush-left labels,
/// hairline + 2px rules, zero corner radius, adaptive light/dark.
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    init(initialTabRawValue: String? = nil) {
        if let initialTabRawValue,
           let initialTab = SettingsTab(rawValue: initialTabRawValue) {
            _selectedTab = State(initialValue: initialTab)
        } else {
            _selectedTab = State(initialValue: .general)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                selectedTab: $selectedTab,
                onOpenOnboarding: {
                    // The standalone onboarding window is owned by AppDelegate.
                    NotificationCenter.default.post(name: .productOnboardingRequested, object: nil)
                }
            )
            .frame(width: VFSize.sidebarWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(VFColor.sidebar)
            .overlay(alignment: .trailing) {
                Rectangle().fill(VFColor.border).frame(width: 1)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: VFSpacing.xl) {
                    SettingsPaneHeader(selectedTab: selectedTab)
                    selectedTabContent
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .padding(EdgeInsets(top: 34, leading: 32, bottom: 44, trailing: 32))
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(VFColor.bg)
        }
        .frame(width: VFSize.settingsWidth, height: VFSize.settingsHeight)
        .background(VFColor.bg)
        // The select pills draw their own accent chevron.
        .menuIndicator(.hidden)
        .vfForcedDarkTheme()
        .animation(VFAnimation.fadeMedium, value: selectedTab)
        .onReceive(NotificationCenter.default.publisher(for: .correctionDictionaryPrefillRequested)) { _ in
            withAnimation(VFAnimation.springSnappy) {
                selectedTab = .dictionary
            }
        }
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsTab()
        case .hotkey:
            HotkeySettingsTab()
        case .dictionary:
            DictionaryStyleSettingsTab()
        case .provider:
            ProviderSettingsTab()
        case .history:
            TranscriptHistoryTab()
        }
    }

}

// MARK: - Tab Enum

private enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, hotkey, dictionary, provider, history

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:    return "General"
        case .hotkey:     return "Hotkey"
        case .dictionary: return "Dictionary & Style"
        case .provider:   return "Provider"
        case .history:    return "History"
        }
    }

    var icon: String {
        switch self {
        case .general:    return "slider.horizontal.3"
        case .hotkey:     return "command"
        case .dictionary: return "character.book.closed"
        case .provider:   return "cloud"
        case .history:    return "list.bullet"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Startup, audio & overlay"
        case .hotkey: return "Global shortcut controls"
        case .dictionary: return "Styles, snippets & corrections"
        case .provider: return "Models & cloud setup"
        case .history: return "Transcript metrics & logs"
        }
    }

    /// Lede under the page title.
    var lede: String {
        switch self {
        case .general: return "Startup, audio, and your everyday dictation workflow."
        case .hotkey: return "One global shortcut for hands-free dictation, anywhere on your Mac."
        case .dictionary: return "Writing styles, voice commands, snippets, and corrections — tuned to how you write."
        case .provider: return "Choose where transcription runs — right on your Mac, or in the cloud."
        case .history: return "Everything you've dictated, with timing so you can spot what to tune."
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selectedTab: SettingsTab
    let onOpenOnboarding: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App identity block (below the transparent titlebar).
            HStack(spacing: 11) {
                if let logo = VFBrand.logo {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 40, height: 40)
                        .overlay(
                            // Keeps the dark logo plate legible on the dark sidebar.
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(VFColor.border2, lineWidth: 1)
                        )
                } else {
                    Rectangle()
                        .fill(VFColor.accent)
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "waveform")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(Color.white)
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisper Smart")
                        .font(VFFont.archivo(15, .heavy))
                        .foregroundStyle(VFColor.text)
                    Text("Preferences")
                        .font(VFFont.archivo(11.5))
                        .foregroundStyle(VFColor.muted)
                }
            }
            .padding(EdgeInsets(top: 42, leading: 16, bottom: 16, trailing: 16))

            Rectangle()
                .fill(VFColor.border)
                .frame(height: 2)
                .padding(.bottom, VFSpacing.xs)

            VStack(spacing: 0) {
                ForEach(SettingsTab.allCases) { tab in
                    SidebarNavItem(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        action: {
                            withAnimation(VFAnimation.springSnappy) {
                                selectedTab = tab
                            }
                        }
                    )
                }
            }

            Spacer(minLength: VFSpacing.sm)

            VStack(alignment: .leading, spacing: 9) {
                Button(action: onOpenOnboarding) {
                    HStack(spacing: VFSpacing.xs) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VFColor.accent)
                        Text("Onboarding")
                            .font(VFFont.archivo(12.5, .semibold))
                            .foregroundStyle(VFColor.text)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Rectangle().stroke(VFColor.border2, lineWidth: 1))

                HStack(spacing: 6) {
                    Image(systemName: "applelogo")
                        .font(.system(size: 11, weight: .medium))
                    Text("macOS native")
                        .font(VFFont.archivo(11, .semibold))
                }
                .foregroundStyle(VFColor.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(VFColor.active)
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct SidebarNavItem: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Group {
                if tab == .hotkey {
                    Text("⌘")
                        .font(VFFont.archivo(15, .bold))
                } else {
                    Image(systemName: tab.icon)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(width: 19, height: 19)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(tab.label)
                    .font(VFFont.archivo(13.5, .semibold))
                    .lineLimit(1)
                Text(tab.subtitle)
                    .font(VFFont.archivo(11))
                    .foregroundStyle(VFColor.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? VFColor.accent : VFColor.text)
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 16))
        .background(isSelected ? VFColor.active : (hovering ? VFColor.interactiveHover : Color.clear))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? VFColor.accent : Color.clear)
                .frame(width: 3)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsPaneHeader: View {
    let selectedTab: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(selectedTab.label)
                .font(VFFont.settingsHeading)
                .tracking(-0.5)
                .foregroundStyle(VFColor.text)
            Text(selectedTab.lede)
                .font(VFFont.archivo(13.5))
                .foregroundStyle(VFColor.muted)
                .frame(maxWidth: 480, alignment: .leading)
        }
    }
}

// MARK: - Section Container

/// A titled Modernist panel section: flat panel, hairline border,
/// icon chip + heavy title over a 2px rule.
private struct NeuSection<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Rectangle()
                    .fill(VFColor.accentSoft)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(VFColor.accent)
                    )
                Text(title)
                    .font(VFFont.settingsTitle)
                    .foregroundStyle(VFColor.text)
            }
            .padding(.top, 18)
            .padding(.bottom, 14)

            Rectangle()
                .fill(VFColor.rule)
                .frame(height: 2)

            VStack(alignment: .leading, spacing: VFSpacing.md) {
                content()
            }
            .padding(.top, VFSpacing.md)
        }
        .padding(.horizontal, VFSpacing.xl)
        .padding(.bottom, VFSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Rectangle()
                .fill(VFColor.panel)
                .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
        )
    }
}

// Keep backward compat alias
private typealias GlassSection = NeuSection

// MARK: - Separator

private struct NeuDivider: View {
    var body: some View {
        Rectangle()
            .fill(VFColor.border)
            .frame(height: 1)
    }
}

// MARK: - Advanced Disclosure

/// Collapsed-by-default container for advanced controls, styled to match
/// the flat panel language (hairline border, accent chevron, zero radius).
private struct AdvancedDisclosure<Content: View>: View {
    var title: String = "Advanced"
    @State private var isExpanded = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(VFAnimation.fadeMedium) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: VFSpacing.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(VFColor.accent)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                        .font(VFFont.archivo(12.5, .semibold))
                        .foregroundStyle(VFColor.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, VFSpacing.sm)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: VFSpacing.md) {
                    content()
                }
                .padding(VFSpacing.sm)
                .padding(.top, VFSpacing.xs)
            }
        }
        .background(
            Rectangle()
                .fill(VFColor.panel2)
                .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
        )
    }
}

private struct GlassFieldModifier: ViewModifier {
    var cornerRadius: CGFloat = 0
    var verticalPadding: CGFloat = VFSpacing.xs

    func body(content: Content) -> some View {
        content
            .font(VFFont.archivo(13))
            .foregroundStyle(VFColor.text)
            .padding(.horizontal, VFSpacing.sm)
            .padding(.vertical, verticalPadding)
            .background(
                Rectangle()
                    .fill(VFColor.panel2)
                    .overlay(Rectangle().stroke(VFColor.border2, lineWidth: 1))
            )
    }
}

private extension View {
    func glassInputField(cornerRadius: CGFloat = 0, verticalPadding: CGFloat = VFSpacing.xs) -> some View {
        modifier(GlassFieldModifier(cornerRadius: cornerRadius, verticalPadding: verticalPadding))
    }

    /// Dropdown trigger: bordered, zero-radius, accent label + chevron.
    func glassSelectPill() -> some View {
        HStack(spacing: 7) {
            self
                .font(VFFont.archivo(13, .semibold))
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(VFColor.accent)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            Rectangle()
                .stroke(VFColor.border2, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

private struct GlassCapsuleButtonStyle: ButtonStyle {
    enum Tone {
        case primary
        case neutral
        case danger
    }

    var tone: Tone = .neutral

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VFFont.archivo(12, .bold))
            .foregroundStyle(labelColor)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(background(pressed: configuration.isPressed))
            .animation(VFAnimation.fadeFast, value: configuration.isPressed)
    }

    private var labelColor: Color {
        switch tone {
        case .primary: return .white
        case .neutral: return VFColor.text
        case .danger:  return VFColor.error
        }
    }

    @ViewBuilder
    private func background(pressed: Bool) -> some View {
        switch tone {
        case .primary:
            Rectangle().fill(pressed ? VFColor.accentDark : VFColor.accent)
        case .neutral:
            Rectangle()
                .fill(pressed ? VFColor.interactivePressed : Color.clear)
                .overlay(Rectangle().stroke(VFColor.border2, lineWidth: 1))
        case .danger:
            Rectangle()
                .fill(pressed ? VFColor.error.opacity(0.12) : Color.clear)
                .overlay(Rectangle().stroke(VFColor.error.opacity(0.6), lineWidth: 1))
        }
    }
}

private struct GlassIconButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(7)
            .background(
                Rectangle()
                    .fill(configuration.isPressed ? VFColor.interactivePressed : Color.clear)
                    .overlay(Rectangle().stroke(VFColor.border2, lineWidth: 1))
            )
            .animation(VFAnimation.fadeFast, value: configuration.isPressed)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("dictationOverlayMode") private var overlayModeRaw = DictationOverlayMode.topCenterWaveform.rawValue
    @AppStorage("recordingSoundsEnabled") private var recordingSoundsEnabled = true
    @AppStorage("postProcessingPipelineEnabled") private var postProcessingPipelineEnabled = true

    @State private var availableInputDevices: [AudioInputDevice] = []
    @State private var selectedInputDeviceUID: String = ""

    @State private var silenceTimeoutSeconds = DictationWorkflowSettings.silenceTimeoutSeconds
    @State private var insertionMode = DictationWorkflowSettings.insertionMode

    @State private var permSnap = PermissionDiagnostics.snapshot()

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            NeuSection(icon: "slider.horizontal.3", title: "Behavior") {
                NeuToggleRow(
                    title: "Launch at login",
                    subtitle: "Start automatically when you log in",
                    isOn: $launchAtLogin
                )
                NeuDivider()
                HStack {
                    VStack(alignment: .leading, spacing: VFSpacing.xs) {
                        Text("Recording overlay")
                            .font(VFFont.settingsBody)
                            .foregroundStyle(VFColor.textPrimary)
                        Text("Choose how recording feedback appears")
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.textSecondary)
                    }
                    Spacer()
                    Menu {
                        ForEach(DictationOverlayMode.allCases) { mode in
                            Button(mode.displayName) {
                                overlayModeRaw = mode.rawValue
                            }
                        }
                    } label: {
                        Text(selectedOverlayMode.displayName)
                            .glassSelectPill()
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                }
                NeuDivider()
                NeuToggleRow(
                    title: "Recording sounds",
                    subtitle: "Play a short sound when recording starts and stops",
                    isOn: $recordingSoundsEnabled
                )
                NeuDivider()
                AdvancedDisclosure {
                    // Microphone selection
                    HStack {
                        VStack(alignment: .leading, spacing: VFSpacing.xs) {
                            Text("Input device")
                                .font(VFFont.settingsBody)
                                .foregroundStyle(VFColor.textPrimary)
                            Text("Choose a specific microphone")
                                .font(VFFont.settingsCaption)
                                .foregroundStyle(VFColor.textSecondary)
                        }
                        Spacer()
                        Menu {
                            Button {
                                selectedInputDeviceUID = ""
                                DictationWorkflowSettings.selectedInputDeviceUID = ""
                            } label: {
                                HStack {
                                    Text("System Default")
                                    if selectedInputDeviceUID.isEmpty {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            if !availableInputDevices.isEmpty {
                                Divider()
                            }
                            ForEach(availableInputDevices) { device in
                                Button {
                                    selectedInputDeviceUID = device.id
                                    DictationWorkflowSettings.selectedInputDeviceUID = device.id
                                } label: {
                                    HStack {
                                        Text(device.name)
                                        if device.id == selectedInputDeviceUID {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(selectedInputDeviceName)
                                .lineLimit(1)
                                .glassSelectPill()
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .frame(maxWidth: 180)
                    }

                    NeuDivider()

                    VStack(alignment: .leading, spacing: VFSpacing.sm) {
                        HStack {
                            Text("Silence timeout")
                                .font(VFFont.settingsBody)
                                .foregroundStyle(VFColor.textPrimary)
                            Spacer()
                            Text(String(format: "%.1fs", silenceTimeoutSeconds))
                                .font(VFFont.settingsCaption)
                                .foregroundStyle(VFColor.textSecondary)
                        }

                        Slider(value: $silenceTimeoutSeconds, in: 0.35...8.0, step: 0.1)
                            .onChange(of: silenceTimeoutSeconds) { _, newValue in
                                DictationWorkflowSettings.silenceTimeoutSeconds = newValue
                            }

                        Text("Used by one-shot dictation to auto-stop when no speech is detected.")
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.textSecondary)
                    }

                    NeuDivider()

                    HStack {
                        Text("Insertion mode")
                            .font(VFFont.settingsBody)
                            .foregroundStyle(VFColor.textPrimary)
                        Spacer()
                        Menu {
                            ForEach(DictationWorkflowSettings.InsertionMode.allCases) { mode in
                                Button(mode.displayName) {
                                    insertionMode = mode
                                    DictationWorkflowSettings.insertionMode = mode
                                }
                            }
                        } label: {
                            Text(insertionMode.displayName)
                                .glassSelectPill()
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                    }

                    NeuDivider()

                    NeuToggleRow(
                        title: "Transcript cleanup pipeline",
                        subtitle: "Apply conservative text cleanup after transcription",
                        isOn: $postProcessingPipelineEnabled
                    )
                }
            }

            NeuSection(icon: "lock.shield", title: "Permission Diagnostics") {
                VStack(alignment: .leading, spacing: VFSpacing.sm) {
                    PermissionRow(
                        name: "Accessibility",
                        status: permSnap.accessibility,
                        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    )
                    NeuDivider()
                    PermissionRow(
                        name: "Microphone",
                        status: permSnap.microphone,
                        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                    )
                    NeuDivider()
                    PermissionRow(
                        name: "Speech Recognition",
                        status: permSnap.speechRecognition,
                        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
                    )

                    HStack {
                        Spacer()
                        Button {
                            permSnap = PermissionDiagnostics.snapshot()
                        } label: {
                            HStack(spacing: VFSpacing.xs) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Refresh")
                                    .font(VFFont.pillLabel)
                            }
                            .foregroundStyle(VFColor.textPrimary)
                        }
                        .buttonStyle(GlassCapsuleButtonStyle(tone: .neutral))
                    }
                    .padding(.top, VFSpacing.xs)
                }
            }
        }
        .onAppear {
            // Deferred: this runs during the settings window's initial layout
            // pass; the overlay-mode getter can write UserDefaults (legacy-key
            // migration), which re-enters the view graph mid-update.
            DispatchQueue.main.async {
                // Ensure old `showBubble` users get migrated to the new mode key.
                overlayModeRaw = DictationOverlaySettings.overlayMode.rawValue
                recordingSoundsEnabled = DictationOverlaySettings.recordingSoundsEnabled
                permSnap = PermissionDiagnostics.snapshot()
                silenceTimeoutSeconds = DictationWorkflowSettings.silenceTimeoutSeconds
                insertionMode = DictationWorkflowSettings.insertionMode

                // Load available input devices
                availableInputDevices = AudioDeviceManager.availableInputDevices()
                selectedInputDeviceUID = DictationWorkflowSettings.selectedInputDeviceUID
            }
        }
        .onChange(of: overlayModeRaw) { _, newValue in
            // Write-if-different: an unconditional write here echoes back into
            // this same @AppStorage key mid-update via synchronous KVO.
            let mode = DictationOverlayMode(rawValue: newValue) ?? .topCenterWaveform
            if DictationOverlaySettings.overlayMode != mode {
                DictationOverlaySettings.overlayMode = mode
            }
        }
    }

    private var selectedOverlayMode: DictationOverlayMode {
        DictationOverlayMode(rawValue: overlayModeRaw) ?? .topCenterWaveform
    }

    private var selectedInputDeviceName: String {
        if selectedInputDeviceUID.isEmpty {
            return "System Default"
        }
        if let device = availableInputDevices.first(where: { $0.id == selectedInputDeviceUID }) {
            return device.name
        }
        return "System Default"
    }
}

// MARK: - Dictionary & Style

private struct DictionaryStyleSettingsTab: View {
    @State private var defaultWritingStyle = DictationWorkflowSettings.defaultWritingStyle
    @State private var defaultDomainPreset = DictationWorkflowSettings.defaultDomainPreset
    @State private var perAppDefaultsJSON = DictationWorkflowSettings.perAppDefaultsJSON
    @State private var snippetsJSON = DictationWorkflowSettings.snippetsJSON
    @State private var correctionDictionaryJSON = DictationWorkflowSettings.correctionDictionaryJSON
    @State private var customAIInstructions = DictationWorkflowSettings.customAIInstructions
    @State private var developerModeEnabled = DictationWorkflowSettings.developerModeEnabled
    @State private var voiceCommandFormattingEnabled = DictationWorkflowSettings.voiceCommandFormattingEnabled
    @FocusState private var customInstructionsFocused: Bool

    @State private var perAppProfiles: [PerAppProfileDraft] = []
    @State private var snippetRows: [PhraseMappingDraft] = []
    @State private var correctionRows: [PhraseMappingDraft] = []
    @State private var vocabularySuggestions: [DictionarySuggestion] = []

    private struct PerAppProfileDraft: Identifiable, Equatable {
        var id = UUID()
        var bundleID: String = ""
        var style: String = "casual"
        var prefix: String = ""
        var suffix: String = ""
    }

    private struct PhraseMappingDraft: Identifiable, Equatable {
        var id = UUID()
        var key: String = ""
        var value: String = ""
    }

    private struct AppProfileRecommendation: Identifiable {
        let id: String
        let appName: String
        let bundleID: String
        let style: String
        let prefix: String
        let suffix: String
    }

    private let profileStyles = ["neutral", "formal", "casual", "concise", "developer"]
    private let recommendedProfiles: [AppProfileRecommendation] = [
        .init(id: "mail", appName: "Mail", bundleID: "com.apple.mail", style: "formal", prefix: "", suffix: ""),
        .init(id: "slack", appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", style: "casual", prefix: "", suffix: ""),
        .init(id: "notion", appName: "Notion", bundleID: "notion.id", style: "concise", prefix: "", suffix: ""),
        .init(id: "vscode", appName: "VS Code", bundleID: "com.microsoft.VSCode", style: "developer", prefix: "", suffix: ""),
        .init(id: "cursor", appName: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", style: "developer", prefix: "", suffix: "")
    ]

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            NeuSection(icon: "sparkles.rectangle.stack", title: "Style & Commands") {
                VStack(alignment: .leading, spacing: VFSpacing.md) {
                    NeuToggleRow(
                        title: "Voice punctuation commands",
                        subtitle: "Recognize commands like comma, period, new paragraph, or 'replace X with Y in ...'",
                        isOn: $voiceCommandFormattingEnabled
                    )
                    .onChange(of: voiceCommandFormattingEnabled) { _, newValue in
                        DictationWorkflowSettings.voiceCommandFormattingEnabled = newValue
                    }

                    NeuDivider()

                    NeuToggleRow(
                        title: "Developer dictation mode",
                        subtitle: "Convert spoken coding tokens (open paren, underscore, brace)",
                        isOn: $developerModeEnabled
                    )
                    .onChange(of: developerModeEnabled) { _, newValue in
                        DictationWorkflowSettings.developerModeEnabled = newValue
                    }

                    NeuDivider()

                    HStack {
                        VStack(alignment: .leading, spacing: VFSpacing.xs) {
                            Text("Default writing style")
                                .font(VFFont.settingsBody)
                                .foregroundStyle(VFColor.textPrimary)
                            Text("Used when no per-app profile matches the active app")
                                .font(VFFont.settingsCaption)
                                .foregroundStyle(VFColor.textSecondary)
                        }
                        Spacer()
                        Menu {
                            ForEach(DictationWorkflowSettings.WritingStyle.allCases) { style in
                                Button(style.displayName) {
                                    defaultWritingStyle = style
                                    DictationWorkflowSettings.defaultWritingStyle = style
                                }
                            }
                        } label: {
                            Text(defaultWritingStyle.displayName)
                                .glassSelectPill()
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                    }

                    NeuDivider()

                    HStack {
                        VStack(alignment: .leading, spacing: VFSpacing.xs) {
                            Text("Dictation domain preset")
                                .font(VFFont.settingsBody)
                                .foregroundStyle(VFColor.textPrimary)
                            Text(defaultDomainPreset.helperText)
                                .font(VFFont.settingsCaption)
                                .foregroundStyle(VFColor.textSecondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Menu {
                            ForEach(DictationWorkflowSettings.DomainPreset.allCases) { preset in
                                Button(preset.displayName) {
                                    defaultDomainPreset = preset
                                    DictationWorkflowSettings.defaultDomainPreset = preset
                                }
                            }
                        } label: {
                            Text(defaultDomainPreset.displayName)
                                .glassSelectPill()
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                    }

                    NeuDivider()

                    VStack(alignment: .leading, spacing: VFSpacing.sm) {
                        Text("Custom AI instructions (cloud)")
                            .font(VFFont.settingsBody)
                            .foregroundStyle(VFColor.textPrimary)

                        TextEditor(text: $customAIInstructions)
                            .font(VFFont.archivo(12))
                            .scrollContentBackground(.hidden)
                            .focused($customInstructionsFocused)
                            .frame(height: 78)
                            .padding(6)
                            .background(
                                Rectangle()
                                    .fill(VFColor.panel2)
                                    .overlay(
                                        Rectangle().stroke(
                                            customInstructionsFocused ? VFColor.accent : VFColor.border2,
                                            lineWidth: 1
                                        )
                                    )
                            )
                            .onChange(of: customAIInstructions) { _, newValue in
                                DictationWorkflowSettings.customAIInstructions = newValue
                            }

                        Text("Used as transcription prompt when OpenAI cloud provider is active.")
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.textSecondary)
                            .lineSpacing(2)
                    }
                }
            }

            NeuSection(icon: "character.book.closed", title: "Dictionary") {
                VStack(alignment: .leading, spacing: VFSpacing.md) {
                    snippetsEditor

                    NeuDivider()

                    if !vocabularySuggestions.isEmpty {
                        vocabularySuggestionsStrip
                    }

                    correctionDictionaryEditor
                }
            }

            NeuSection(icon: "square.grid.2x2", title: "Per-App Profiles") {
                perAppProfilesEditor
            }
        }
        .onAppear {
            // Deferred: this runs during the settings window's initial layout
            // pass; writing state mid-update re-enters the view graph.
            DispatchQueue.main.async {
                defaultWritingStyle = DictationWorkflowSettings.defaultWritingStyle
                defaultDomainPreset = DictationWorkflowSettings.defaultDomainPreset
                perAppDefaultsJSON = DictationWorkflowSettings.perAppDefaultsJSON
                snippetsJSON = DictationWorkflowSettings.snippetsJSON
                correctionDictionaryJSON = DictationWorkflowSettings.correctionDictionaryJSON
                customAIInstructions = DictationWorkflowSettings.customAIInstructions
                developerModeEnabled = DictationWorkflowSettings.developerModeEnabled
                voiceCommandFormattingEnabled = DictationWorkflowSettings.voiceCommandFormattingEnabled

                perAppProfiles = parsePerAppProfiles(from: perAppDefaultsJSON)
                snippetRows = parsePhraseMap(from: snippetsJSON)
                correctionRows = parsePhraseMap(from: correctionDictionaryJSON)
                refreshVocabularySuggestions()
                consumePendingCorrectionPrefill()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .correctionDictionaryPrefillRequested)) { _ in
            // Deferred: the History tab posts before this tab is mounted; when
            // it is already mounted, consume in place.
            DispatchQueue.main.async {
                consumePendingCorrectionPrefill()
            }
        }
        .onChange(of: perAppProfiles) { _, newValue in
            persistPerAppProfiles(newValue)
        }
        .onChange(of: snippetRows) { _, newValue in
            persistPhraseMap(newValue, target: .snippets)
        }
        .onChange(of: correctionRows) { _, newValue in
            persistPhraseMap(newValue, target: .corrections)
        }
    }

    @ViewBuilder
    private var perAppProfilesEditor: some View {
        editorContainer(
            title: "Per-app profiles",
            subtitle: "Applied automatically by active app."
        ) {
            VStack(alignment: .leading, spacing: VFSpacing.sm) {
                if perAppProfiles.isEmpty {
                    Text("No app profiles yet.")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)
                }

                ForEach(Array(perAppProfiles.indices), id: \.self) { index in
                    editorRowContainer {
                        HStack(spacing: VFSpacing.sm) {
                            TextField(
                                "Bundle ID (e.g. com.apple.mail)",
                                text: Binding(
                                    get: { perAppProfiles[index].bundleID },
                                    set: { perAppProfiles[index].bundleID = $0 }
                                )
                            )
                            .textFieldStyle(.plain)
                            .glassInputField()

                            Picker(
                                "Style",
                                selection: Binding(
                                    get: { perAppProfiles[index].style },
                                    set: { perAppProfiles[index].style = $0 }
                                )
                            ) {
                                ForEach(profileStyles, id: \.self) { style in
                                    Text(style.capitalized).tag(style)
                                }
                            }
                            .pickerStyle(.menu)

                            Button(role: .destructive) {
                                perAppProfiles.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(VFColor.error)
                                    .frame(width: 14, height: 14)
                            }
                            .buttonStyle(GlassIconButtonStyle(cornerRadius: 7))
                        }

                        HStack(spacing: VFSpacing.sm) {
                            TextField(
                                "Optional prefix",
                                text: Binding(
                                    get: { perAppProfiles[index].prefix },
                                    set: { perAppProfiles[index].prefix = $0 }
                                )
                            )
                            .textFieldStyle(.plain)
                            .glassInputField()

                            TextField(
                                "Optional suffix",
                                text: Binding(
                                    get: { perAppProfiles[index].suffix },
                                    set: { perAppProfiles[index].suffix = $0 }
                                )
                            )
                            .textFieldStyle(.plain)
                            .glassInputField()
                        }
                    }
                }

                Button {
                    perAppProfiles.append(PerAppProfileDraft())
                } label: {
                    Label("Add app profile", systemImage: "plus.circle.fill")
                        .font(VFFont.pillLabel)
                }
                .buttonStyle(addActionButtonStyle)
                .padding(.top, VFSpacing.xs)

                VStack(alignment: .leading, spacing: VFSpacing.xs) {
                    Text("Quick recommendations")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: VFSpacing.xs) {
                            ForEach(recommendedProfiles) { recommendation in
                                Button(recommendation.appName) {
                                    applyRecommendedProfile(recommendation)
                                }
                                .buttonStyle(GlassCapsuleButtonStyle(tone: .neutral))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var snippetsEditor: some View {
        editorContainer(
            title: "Voice snippets",
            subtitle: "Say the phrase, and Whisper Smart inserts the expansion."
        ) {
            VStack(alignment: .leading, spacing: VFSpacing.sm) {
                if snippetRows.isEmpty {
                    Text("No snippets yet.")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)
                }

                ForEach(Array(snippetRows.indices), id: \.self) { index in
                    editorRowContainer {
                        HStack(spacing: VFSpacing.sm) {
                            TextField(
                                "Spoken phrase",
                                text: Binding(
                                    get: { snippetRows[index].key },
                                    set: { snippetRows[index].key = $0 }
                                )
                            )
                            .textFieldStyle(.plain)
                            .glassInputField()

                            TextField(
                                "Expansion text",
                                text: Binding(
                                    get: { snippetRows[index].value },
                                    set: { snippetRows[index].value = $0 }
                                )
                            )
                            .textFieldStyle(.plain)
                            .glassInputField()

                            Button(role: .destructive) {
                                snippetRows.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(VFColor.error)
                                    .frame(width: 14, height: 14)
                            }
                            .buttonStyle(GlassIconButtonStyle(cornerRadius: 7))
                        }
                    }
                }

                Button {
                    snippetRows.append(PhraseMappingDraft())
                } label: {
                    Label("Add snippet", systemImage: "plus.circle.fill")
                        .font(VFFont.pillLabel)
                }
                .buttonStyle(addActionButtonStyle)
                .padding(.top, VFSpacing.xs)
            }
        }
    }

    @ViewBuilder
    private var correctionDictionaryEditor: some View {
        editorContainer(
            title: "Correction dictionary",
            subtitle: "Applied after transcription to normalize words and names."
        ) {
            VStack(alignment: .leading, spacing: VFSpacing.sm) {
                if correctionRows.isEmpty {
                    Text("No corrections yet.")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)
                }

                ForEach(Array(correctionRows.indices), id: \.self) { index in
                    editorRowContainer {
                        HStack(spacing: VFSpacing.sm) {
                            TextField(
                                "From",
                                text: Binding(
                                    get: { correctionRows[index].key },
                                    set: { correctionRows[index].key = $0 }
                                )
                            )
                            .textFieldStyle(.plain)
                            .glassInputField()

                            TextField(
                                "To",
                                text: Binding(
                                    get: { correctionRows[index].value },
                                    set: { correctionRows[index].value = $0 }
                                )
                            )
                            .textFieldStyle(.plain)
                            .glassInputField()

                            Button(role: .destructive) {
                                correctionRows.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(VFColor.error)
                                    .frame(width: 14, height: 14)
                            }
                            .buttonStyle(GlassIconButtonStyle(cornerRadius: 7))
                        }
                    }
                }

                Button {
                    correctionRows.append(PhraseMappingDraft())
                } label: {
                    Label("Add correction", systemImage: "plus.circle.fill")
                        .font(VFFont.pillLabel)
                }
                .buttonStyle(addActionButtonStyle)
                .padding(.top, VFSpacing.xs)
            }
        }
    }

    @ViewBuilder
    private var vocabularySuggestionsStrip: some View {
        VStack(alignment: .leading, spacing: VFSpacing.xs) {
            Text("Suggestions")
                .font(VFFont.settingsBody)
                .foregroundStyle(VFColor.textPrimary)
            Text("Vocabulary spotted in your transcript history. Add to teach the correction dictionary, or dismiss to hide forever.")
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: VFSpacing.xs) {
                    ForEach(vocabularySuggestions) { suggestion in
                        HStack(spacing: VFSpacing.xs) {
                            Text(suggestion.term)
                                .font(VFFont.archivo(12, .semibold))
                                .foregroundStyle(VFColor.textPrimary)
                                .lineLimit(1)

                            Button {
                                acceptVocabularySuggestion(suggestion)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(VFColor.accent)
                                    .frame(width: 14, height: 14)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Add \(suggestion.term) to dictionary")

                            Button {
                                dismissVocabularySuggestion(suggestion)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(VFColor.muted)
                                    .frame(width: 14, height: 14)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dismiss suggestion \(suggestion.term)")
                        }
                        .padding(.horizontal, VFSpacing.sm)
                        .padding(.vertical, VFSpacing.xs)
                        .background(
                            Rectangle()
                                .fill(VFColor.panel)
                                .overlay(Rectangle().stroke(VFColor.border2, lineWidth: 1))
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(VFSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Rectangle()
                .fill(VFColor.panel2)
                .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
        )
    }

    private func refreshVocabularySuggestions() {
        vocabularySuggestions = DictionarySuggestionEngine.suggestions(
            fromHistoryTexts: TranscriptLogStore.shared.entries.map(\.text)
        )
    }

    private func acceptVocabularySuggestion(_ suggestion: DictionarySuggestion) {
        prefillCorrectionRow(with: suggestion.term)
        vocabularySuggestions.removeAll { $0.term == suggestion.term }
    }

    private func dismissVocabularySuggestion(_ suggestion: DictionarySuggestion) {
        DictionarySuggestionEngine.dismiss(suggestion.term)
        vocabularySuggestions.removeAll { $0.term == suggestion.term }
    }

    private func consumePendingCorrectionPrefill() {
        guard let text = CorrectionDictionaryPrefill.consume() else { return }
        prefillCorrectionRow(with: text)
    }

    /// Adds a correction row mapping the misheard (lowercased) form to the
    /// properly cased term, ready for the user to adjust.
    private func prefillCorrectionRow(with term: String) {
        let key = term.lowercased()
        if let existing = correctionRows.firstIndex(where: {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
        }) {
            correctionRows[existing].value = term
            return
        }
        correctionRows.append(PhraseMappingDraft(key: key, value: term))
    }

    @ViewBuilder
    private func editorContainer<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            VStack(alignment: .leading, spacing: VFSpacing.xs) {
                Text(title)
                    .font(VFFont.settingsBody)
                    .foregroundStyle(VFColor.textPrimary)
                Text(subtitle)
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.textSecondary)
            }

            content()
        }
        .padding(VFSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Rectangle()
                .fill(VFColor.panel2)
                .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
        )
    }

    @ViewBuilder
    private func editorRowContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            content()
        }
        .padding(VFSpacing.sm)
        .background(
            Rectangle()
                .fill(VFColor.panel)
                .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
        )
    }

    private var addActionButtonStyle: some ButtonStyle {
        ProminentAddButtonStyle()
    }

    private func deleteIconButton(action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VFColor.error)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(GlassIconButtonStyle(cornerRadius: 7))
    }

    private func emptyStateCard(_ text: String) -> some View {
        Text(text)
            .font(VFFont.settingsCaption)
            .foregroundStyle(VFColor.muted)
            .padding(VFSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Rectangle()
                    .fill(VFColor.panel2)
                    .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
            )
    }

    private func parsePerAppProfiles(from json: String) -> [PerAppProfileDraft] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let map = object as? [String: [String: Any]] else {
            return []
        }

        return map.keys.sorted().map { bundleID in
            let payload = map[bundleID] ?? [:]
            let rawStyle = (payload["style"] as? String ?? "casual").lowercased()
            let style = profileStyles.contains(rawStyle) ? rawStyle : "casual"
            return PerAppProfileDraft(
                bundleID: bundleID,
                style: style,
                prefix: payload["prefix"] as? String ?? "",
                suffix: payload["suffix"] as? String ?? ""
            )
        }
    }

    private func parsePhraseMap(from json: String) -> [PhraseMappingDraft] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let map = object as? [String: String] else {
            return []
        }

        return map.keys.sorted().map { key in
            PhraseMappingDraft(key: key, value: map[key] ?? "")
        }
    }

    private func persistPerAppProfiles(_ profiles: [PerAppProfileDraft]) {
        var result: [String: [String: String]] = [:]

        for profile in profiles {
            let bundleID = profile.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty else { continue }

            var payload: [String: String] = ["style": profile.style]
            let prefix = profile.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = profile.suffix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { payload["prefix"] = prefix }
            if !suffix.isEmpty { payload["suffix"] = suffix }
            result[bundleID] = payload
        }

        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        perAppDefaultsJSON = json
        DictationWorkflowSettings.perAppDefaultsJSON = json
    }

    private func applyRecommendedProfile(_ recommendation: AppProfileRecommendation) {
        let normalizedBundleID = recommendation.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedBundleID.isEmpty else { return }

        if let index = perAppProfiles.firstIndex(where: {
            $0.bundleID.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedBundleID
        }) {
            perAppProfiles[index].style = recommendation.style
            perAppProfiles[index].prefix = recommendation.prefix
            perAppProfiles[index].suffix = recommendation.suffix
            return
        }

        perAppProfiles.append(
            PerAppProfileDraft(
                bundleID: normalizedBundleID,
                style: recommendation.style,
                prefix: recommendation.prefix,
                suffix: recommendation.suffix
            )
        )
    }

    private enum PhraseMapTarget {
        case snippets
        case corrections
    }

    private func persistPhraseMap(_ rows: [PhraseMappingDraft], target: PhraseMapTarget) {
        var result: [String: String] = [:]

        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { continue }
            result[key] = value
        }

        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return
        }

        switch target {
        case .snippets:
            snippetsJSON = json
            DictationWorkflowSettings.snippetsJSON = json
        case .corrections:
            correctionDictionaryJSON = json
            DictationWorkflowSettings.correctionDictionaryJSON = json
        }
    }
}

private struct ProminentAddButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VFFont.archivo(12, .bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                Rectangle().fill(configuration.isPressed ? VFColor.accentDark : VFColor.accent)
            )
            .animation(VFAnimation.fadeFast, value: configuration.isPressed)
    }
}

/// A single row showing a permission's name, status dot, and action hint.
private struct PermissionRow: View {
    let name: String
    let status: PermissionDiagnostics.Status
    let settingsURL: String

    var body: some View {
        HStack {
            Circle()
                .fill(status.isUsable ? VFColor.success : VFColor.error)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: VFSpacing.xxs) {
                Text(name)
                    .font(VFFont.settingsBody)
                    .foregroundStyle(VFColor.textPrimary)
                Text(status.actionHint)
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(
                        status.isUsable ? VFColor.textSecondary : VFColor.error
                    )
            }

            Spacer()

            if !status.isUsable {
                Button {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Open")
                }
                .buttonStyle(GlassCapsuleButtonStyle(tone: .primary))
            }
        }
    }
}

// MARK: - Hotkey Settings

private struct HotkeySettingsTab: View {
    @State private var currentBinding: HotkeyBinding = HotkeyBinding.load()
    @State private var selectedPresetIndex: Int = Self.initialPresetIndex()
    @State private var isRecording: Bool = false
    @State private var liveModifiers: String = ""
    @State private var validationError: String? = nil
    @State private var keyMonitor: Any? = nil
    @State private var flagsMonitor: Any? = nil
    /// Tracks the last lone modifier event so we can finalize on release.
    @State private var pendingModifierEvent: NSEvent? = nil

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            NeuSection(icon: "command", title: "Global Shortcut") {
                VStack(alignment: .leading, spacing: VFSpacing.md) {
                    // Shortcut display / recorder
                    HStack {
                        Text("Dictation shortcut")
                            .font(VFFont.settingsBody)
                            .foregroundStyle(VFColor.textPrimary)

                        Spacer()

                        Button {
                            if isRecording {
                                cancelRecording()
                            } else {
                                startRecording()
                            }
                        } label: {
                            Group {
                                if isRecording {
                                    Text(liveModifiers.isEmpty ? "Press a combo…" : liveModifiers)
                                        .font(VFFont.archivo(13, .semibold))
                                        .foregroundStyle(VFColor.accent)
                                } else {
                                    HStack(spacing: 5) {
                                        ForEach(shortcutKeycaps, id: \.self) { cap in
                                            Text(cap)
                                                .font(VFFont.archivo(12.5, .semibold))
                                                .foregroundStyle(VFColor.text)
                                                .padding(.horizontal, 6)
                                                .frame(minWidth: 22, minHeight: 24)
                                                .background(
                                                    Rectangle()
                                                        .fill(VFColor.panel)
                                                        .overlay(Rectangle().stroke(VFColor.border2, lineWidth: 1))
                                                )
                                        }
                                    }
                                }
                            }
                            .frame(minWidth: 120)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Rectangle()
                                    .fill(VFColor.panel2)
                                    .overlay(
                                        Rectangle().stroke(
                                            isRecording ? VFColor.accent : VFColor.border2,
                                            lineWidth: 1.5
                                        )
                                    )
                            )
                            .contentShape(Rectangle())
                            .animation(VFAnimation.fadeFast, value: isRecording)
                            .animation(VFAnimation.fadeFast, value: liveModifiers)
                        }
                        .buttonStyle(.plain)
                    }

                    // Hint / error row
                    if isRecording {
                        Text("Press modifier + key (e.g. ⌥ Space) or tap a modifier alone (e.g. ⌃). Esc to cancel.")
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.accentFallback.opacity(0.8))
                    }

                    if let error = validationError {
                        Text(error)
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.error)
                            .transition(.opacity)
                    }

                    NeuDivider()

                    // Preset picker
                    HStack {
                        Text("Preset")
                            .font(VFFont.settingsBody)
                            .foregroundStyle(VFColor.textPrimary)

                        Spacer()

                        Menu {
                            ForEach(0..<HotkeyBinding.presets.count, id: \.self) { i in
                                Button(HotkeyBinding.presets[i].displayString) {
                                    selectedPresetIndex = i
                                    applyPreset(at: i)
                                }
                            }
                        } label: {
                            HStack(spacing: VFSpacing.sm) {
                                Text(presetDisplayString)
                                    .font(VFFont.pillLabel)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .glassSelectPill()
                        }
                        .menuStyle(.button)
                    .buttonStyle(.plain)
                        .disabled(isRecording)
                        .opacity(isRecording ? 0.4 : 1.0)
                    }

                    Text("Pick a preset or click the shortcut pill to record a custom combo.")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)
                }
            }
        }
        .onDisappear { tearDownMonitors() }
    }

    // MARK: - Recorder lifecycle

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        liveModifiers = ""
        validationError = nil

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleKeyDown(event)
            return nil
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            handleFlagsChanged(event)
            return nil
        }
    }

    private func cancelRecording() {
        tearDownMonitors()
        isRecording = false
        liveModifiers = ""
        pendingModifierEvent = nil
    }

    private func tearDownMonitors() {
        if let m = keyMonitor  { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
    }

    // MARK: - Event handlers

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        liveModifiers = Self.modifierSymbols(from: flags)

        if flags.isEmpty {
            // All modifiers released — if we were tracking a lone modifier, finalize it.
            if let modEvent = pendingModifierEvent,
               let binding = HotkeyBinding.fromModifierOnly(event: modEvent) {
                pendingModifierEvent = nil
                tearDownMonitors()
                isRecording = false
                liveModifiers = ""
                validationError = nil
                applyBinding(binding)
            }
            pendingModifierEvent = nil
        } else {
            // A modifier is held. Record the event so we can finalize on release.
            pendingModifierEvent = event
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // A regular key was pressed — this is not a modifier-only shortcut.
        pendingModifierEvent = nil

        // Esc cancels recording
        if event.keyCode == UInt16(kVK_Escape) {
            cancelRecording()
            return
        }

        guard let binding = HotkeyBinding.from(event: event) else {
            withAnimation(VFAnimation.fadeFast) {
                validationError = "Add a modifier key (⌘ ⌥ ⌃ ⇧) with that key."
            }
            clearValidationAfterDelay()
            return
        }

        tearDownMonitors()
        isRecording = false
        liveModifiers = ""
        validationError = nil
        applyBinding(binding)
    }

    // MARK: - Apply binding

    private func applyBinding(_ binding: HotkeyBinding) {
        currentBinding = binding
        selectedPresetIndex = binding.presetIndex ?? -1
        binding.save()
        NotificationCenter.default.post(
            name: .hotkeyBindingDidChange,
            object: nil,
            userInfo: ["binding": binding.toUserInfo()]
        )
    }

    private func applyPreset(at index: Int) {
        guard index >= 0 && index < HotkeyBinding.presets.count else { return }
        applyBinding(HotkeyBinding.presets[index])
    }

    // MARK: - Helpers

    private func clearValidationAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(VFAnimation.fadeFast) { validationError = nil }
        }
    }

    private static func modifierSymbols(from flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control)  { parts.append("⌃") }
        if flags.contains(.option)   { parts.append("⌥") }
        if flags.contains(.shift)    { parts.append("⇧") }
        if flags.contains(.command)  { parts.append("⌘") }
        if flags.contains(.function) { parts.append("Fn") }
        return parts.joined(separator: " ")
    }

    private var presetDisplayString: String {
        if selectedPresetIndex >= 0 && selectedPresetIndex < HotkeyBinding.presets.count {
            return HotkeyBinding.presets[selectedPresetIndex].displayString
        }
        return "Custom"
    }

    /// The current shortcut split into keycap chunks for display.
    private var shortcutKeycaps: [String] {
        let parts = currentBinding.displayString
            .split(separator: " ")
            .map(String.init)
        return parts.isEmpty ? [currentBinding.displayString] : parts
    }

    private static func initialPresetIndex() -> Int {
        let current = HotkeyBinding.load()
        return HotkeyBinding.presets.firstIndex(of: current) ?? -1
    }
}

// Notification names for binding/provider changes live in
// app/Core/AppNotifications.swift so Core code can post them.

// MARK: - Provider Settings

private struct ProviderSettingsTab: View {
    private enum SmartModelPreset: String, CaseIterable, Identifiable {
        case light
        case balanced
        case best
        case cloud

        var id: String { rawValue }

        var title: String {
            switch self {
            case .light: return "Light"
            case .balanced: return "Balanced"
            case .best: return "Best"
            case .cloud: return "Cloud"
            }
        }

        var subtitle: String {
            switch self {
            case .light: return "Whisper Base (MLX) · fast local"
            case .balanced: return "Parakeet TDT 0.6B (MLX) · best local speed"
            case .best: return "Whisper Large-v3 Turbo (MLX) · highest local accuracy"
            case .cloud: return "OpenAI Whisper API · remote transcription"
            }
        }

        var shortBadge: String {
            switch self {
            case .light: return "LGT"
            case .balanced: return "TDT"
            case .best: return "MAX"
            case .cloud: return "API"
            }
        }

        var provider: STTProviderKind {
            switch self {
            case .light, .best: return .whisper
            case .balanced: return .parakeet
            case .cloud: return .openaiAPI
            }
        }
    }

    @State private var selectedKind: STTProviderKind = STTProviderKind.loadSelection()
    @StateObject private var mlxInstaller = MLXModelInstaller.shared
    @State private var cloudFallbackEnabled = DictationProviderPolicy.cloudFallbackEnabled
    @State private var openAIAPIKey = DictationProviderPolicy.openAIAPIKey
    @State private var openAIEndpointProfile = DictationProviderPolicy.openAIEndpointProfile
    @State private var openAIBaseURL = DictationProviderPolicy.openAIBaseURL
    @State private var openAIModel = DictationProviderPolicy.openAIModel
    @State private var openAIAPIKeyStatusMessage: String?
    @State private var openAIAPIKeyStatusSeverity: ProviderMessageSeverity = .info
    @State private var presetDiagnostics: [STTProviderKind: ProviderRuntimeDiagnostics] = [:]

    private enum ProviderMessageSeverity {
        case info
        case warning
        case error

        var color: Color {
            switch self {
            case .info:
                return VFColor.textSecondary
            case .warning:
                return Color(red: 1.0, green: 0.74, blue: 0.34)
            case .error:
                return VFColor.error
            }
        }

        var icon: String {
            switch self {
            case .info:
                return "info.circle.fill"
            case .warning:
                return "exclamationmark.triangle.fill"
            case .error:
                return "xmark.octagon.fill"
            }
        }

        init(_ severity: AppStatusSeverity) {
            switch severity {
            case .info: self = .info
            case .warning: self = .warning
            case .error: self = .error
            }
        }
    }

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            NeuSection(icon: "waveform.and.mic", title: "Smart Model Selection") {
                VStack(alignment: .leading, spacing: VFSpacing.lg) {
                    Text("Pick a model, click Download, then click Use. Nothing installs until you ask. Cloud needs an OpenAI API key.")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)

                    VStack(spacing: VFSpacing.md) {
                        ForEach(SmartModelPreset.allCases) { preset in
                            presetCard(preset)
                        }
                    }

                    NeuToggleRow(
                        title: "Allow cloud fallback",
                        subtitle: "Let dictation use the OpenAI cloud endpoint when Cloud is selected or local models are unavailable",
                        isOn: $cloudFallbackEnabled
                    )
                    .onChange(of: cloudFallbackEnabled) { _, newValue in
                        // Deferred: persisting posts .sttProviderDidChange whose
                        // cascade must not run mid-update.
                        DispatchQueue.main.async {
                            guard DictationProviderPolicy.cloudFallbackEnabled != newValue else { return }
                            DictationProviderPolicy.cloudFallbackEnabled = newValue
                            NotificationCenter.default.post(name: .sttProviderDidChange, object: nil)
                        }
                    }

                    if selectedKind == .openaiAPI {
                        providerConfigurationSection
                    }

                    if selectedKind == .parakeet || selectedKind == .whisper || selectedKind == .openaiAPI {
                        AdvancedDisclosure {
                            if selectedKind == .parakeet || selectedKind == .whisper {
                                MLXModelDetailRow(kind: selectedKind, installer: mlxInstaller)
                            }

                            if selectedKind == .openaiAPI {
                                cloudEndpointAdvancedSection
                            }
                        }
                    }
                }
            }

            // TTS preview section removed.
        }
        .onAppear {
            // Deferred: onAppear runs inside the tab's first layout pass, and
            // this block writes UserDefaults and mutates @StateObject phases —
            // both of which re-enter the view graph mid-update and crash
            // (AttributeGraph precondition failure).
            DispatchQueue.main.async {
                cloudFallbackEnabled = DictationProviderPolicy.cloudFallbackEnabled
                openAIAPIKey = DictationProviderPolicy.openAIAPIKey
                openAIEndpointProfile = DictationProviderPolicy.openAIEndpointProfile
                openAIBaseURL = DictationProviderPolicy.openAIBaseURL
                openAIModel = DictationProviderPolicy.openAIModel
                openAIAPIKeyStatusMessage = nil
                refreshPresetDiagnostics()
            }
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .sttProviderDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            refreshPresetDiagnostics()
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .mlxRuntimeBootstrapDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            refreshPresetDiagnostics()
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .mlxModelInstallDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            refreshPresetDiagnostics()
        }
    }

    @ViewBuilder
    private var providerConfigurationSection: some View {
        if selectedKind == .openaiAPI {
            VStack(alignment: .leading, spacing: VFSpacing.sm) {
                Text("OpenAI API key")
                    .font(VFFont.settingsBody)
                    .foregroundStyle(VFColor.textPrimary)
                TextField("sk-...", text: $openAIAPIKey)
                    .textFieldStyle(.plain)
                    .glassInputField()
                    .onChange(of: openAIAPIKey) { _, newValue in
                        let normalized = DictationProviderPolicy.normalizedOpenAIAPIKey(newValue)
                        if normalized != newValue {
                            openAIAPIKey = normalized
                        }
                    }
                    .onSubmit {
                        persistOpenAIAPIKey()
                    }

                HStack(spacing: VFSpacing.sm) {
                    profileActionButton(title: "Paste & Save", isPrimary: true, enabled: true) {
                        pasteAndSaveOpenAIAPIKey()
                    }
                }

                if let status = openAIAPIKeyStatusMessage {
                    statusText(status, severity: openAIAPIKeyStatusSeverity)
                }
            }
            .onDisappear { [openAIAPIKey] in
                // Save an edited API key even if the user never pressed
                // Return or the save button before leaving the tab.
                // Deferred: onDisappear runs during the view update that
                // removes this tab; persisting posts .sttProviderDidChange
                // whose cascade must not run mid-update.
                DispatchQueue.main.async {
                    let normalized = DictationProviderPolicy.normalizedOpenAIAPIKey(openAIAPIKey)
                    if normalized != DictationProviderPolicy.openAIAPIKey {
                        persistOpenAIAPIKey(normalized)
                    }
                }
            }
        }
    }

    /// Cloud endpoint configuration (profile, base URL, model). Lives inside
    /// the Advanced disclosure — everyday setup only needs the API key above.
    @ViewBuilder
    private var cloudEndpointAdvancedSection: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack {
                Text("Endpoint profile")
                    .font(VFFont.settingsBody)
                    .foregroundStyle(VFColor.textPrimary)
                Spacer()
                Menu {
                    ForEach(DictationProviderPolicy.OpenAIEndpointProfile.allCases) { profile in
                        Button(profile.displayName) {
                            openAIEndpointProfile = profile
                            DictationProviderPolicy.openAIEndpointProfile = profile
                            // Load the profile's defaults so the form never
                            // shows the previous profile's stale values.
                            openAIBaseURL = profile.defaultBaseURL
                            openAIModel = profile.defaultModel
                            DictationProviderPolicy.openAIBaseURL = openAIBaseURL
                            DictationProviderPolicy.openAIModel = openAIModel
                            NotificationCenter.default.post(name: .sttProviderDidChange, object: nil)
                            openAIAPIKeyStatusMessage = nil
                        }
                    }
                } label: {
                    Text(openAIEndpointProfile.displayName)
                        .glassSelectPill()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }

            HStack(spacing: VFSpacing.sm) {
                VStack(alignment: .leading, spacing: VFSpacing.xs) {
                    Text("Base URL")
                        .font(VFFont.settingsBody)
                        .foregroundStyle(VFColor.textPrimary)
                    TextField(openAIEndpointProfile.defaultBaseURL, text: $openAIBaseURL)
                        .textFieldStyle(.plain)
                        .glassInputField()
                        .onChange(of: openAIBaseURL) { _, newValue in
                            // Persist as-typed so switching tabs doesn't
                            // discard edits; normalization happens on save.
                            DictationProviderPolicy.openAIBaseURL = newValue
                        }
                        .onSubmit {
                            persistOpenAIEndpointConfiguration()
                        }
                }

                VStack(alignment: .leading, spacing: VFSpacing.xs) {
                    Text("Model")
                        .font(VFFont.settingsBody)
                        .foregroundStyle(VFColor.textPrimary)
                    TextField(openAIEndpointProfile.defaultModel, text: $openAIModel)
                        .textFieldStyle(.plain)
                        .glassInputField()
                        .onChange(of: openAIModel) { _, newValue in
                            DictationProviderPolicy.openAIModel = newValue
                        }
                        .onSubmit {
                            persistOpenAIEndpointConfiguration()
                        }
                }
            }

            Text("Supports official OpenAI and compatible self-hosted gateways that expose `/v1/audio/transcriptions`. Press Return in a field to save it.")
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textSecondary)
        }
    }

    private func presetCard(_ preset: SmartModelPreset) -> some View {
        // Diagnostics are cached in @State and refreshed outside view updates.
        // Computing them here ran SFSpeechRecognizer/TCC/Keychain work inside
        // body on every render — the source of an AttributeGraph crash.
        let presetStatus = presetDiagnostics[preset.provider]
            .flatMap { presetStatusMessage(for: preset, diagnostics: $0) }
        let isActive = activePreset == preset

        return HStack(alignment: .top, spacing: 15) {
            presetArtwork(for: preset, isActive: isActive)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(preset.title)
                        .font(VFFont.archivo(15, .bold))
                        .foregroundStyle(VFColor.text)
                    Text(preset.subtitle)
                        .font(VFFont.archivo(12))
                        .foregroundStyle(VFColor.muted)
                        .lineLimit(2)
                }

                HStack(spacing: 9) {
                    presetActionRow(for: preset, isActive: isActive)
                }
                .frame(minHeight: 26)
                .padding(.top, 11)

                if let presetStatus {
                    statusText(presetStatus.message, severity: presetStatus.severity)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Circle()
                    .stroke(isActive ? VFColor.accent : VFColor.border2, lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                if isActive {
                    Circle()
                        .fill(VFColor.accent)
                        .frame(width: 12, height: 12)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .padding(VFSpacing.md)
        .background(
            Rectangle()
                .fill(isActive ? VFColor.active : VFColor.panel)
                .overlay(
                    Rectangle().stroke(
                        isActive ? VFColor.accent : VFColor.border,
                        lineWidth: isActive ? 1.5 : 1
                    )
                )
        )
    }

    private func presetArtwork(for preset: SmartModelPreset, isActive: Bool) -> some View {
        Rectangle()
            .fill(VFColor.panel2)
            .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
            .overlay(
                Text(preset.shortBadge)
                    .font(VFFont.archivo(11, .heavy))
                    .tracking(0.6)
                    .foregroundStyle(VFColor.accent)
            )
            .frame(width: 46, height: 46)
    }

    /// The state that drives each card's single primary action:
    /// Download → (progress) → Use → In use, with Retry on failure.
    private enum PresetInstallState {
        case installed
        case notInstalled
        case working(String)
        case failed(String)
    }

    /// The MLX model each preset installs and runs.
    private func presetModel(for preset: SmartModelPreset) -> MLXModel? {
        switch preset {
        case .light: return MLXModelCatalog.whisperBase
        case .balanced: return MLXModelCatalog.selectedParakeetModel
        case .best: return MLXModelCatalog.selectedWhisperModel
        case .cloud: return nil
        }
    }

    private func presetInstallState(for preset: SmartModelPreset) -> PresetInstallState {
        guard let model = presetModel(for: preset) else {
            // Cloud: use the cached key (loaded onAppear) — reading the
            // Keychain from body would reintroduce side effects during view
            // updates.
            return openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .notInstalled
                : .installed
        }

        switch mlxInstaller.phase {
        case .installing(let modelID, let detail) where modelID == model.id:
            return .working(detail)
        case .failed(let modelID, _) where modelID == model.id:
            // Raw installer output (repo names, xcode-select hints, tool logs)
            // only appears inside Advanced; the card stays plain-language.
            return .failed(AppStatusCatalog.modelInstallFailed.message)
        default:
            return mlxInstaller.isInstalled(model) ? .installed : .notInstalled
        }
    }

    @ViewBuilder
    private func presetActionRow(for preset: SmartModelPreset, isActive: Bool) -> some View {
        HStack(spacing: VFSpacing.sm) {
            switch presetInstallState(for: preset) {
            case .installed:
                if isActive {
                    installedChip(label: "In use", color: VFColor.accentFallback)
                } else {
                    profileActionButton(title: "Use", isPrimary: true, enabled: true) {
                        applyPreset(preset)
                    }
                }
            case .notInstalled:
                profileActionButton(
                    title: preset == .cloud ? "Add API Key" : "Download",
                    isPrimary: true,
                    enabled: true
                ) {
                    startPresetInstall(preset)
                }
            case .working(let label):
                installedChip(label: label, color: VFColor.accentFallback)
                profileActionButton(title: "Cancel", enabled: true) {
                    cancelPresetInstall(preset)
                }
            case .failed(let message):
                profileActionButton(title: "Retry", isPrimary: true, enabled: true) {
                    startPresetInstall(preset)
                }
                statusText(message, severity: .error)
            }
        }
    }

    private func startPresetInstall(_ preset: SmartModelPreset) {
        guard let model = presetModel(for: preset) else {
            // Cloud: selecting reveals the API key form below the cards.
            applyPreset(.cloud)
            return
        }
        // The click is the consent for the model download + runtime install.
        MLXModelInstaller.shared.install(model)
    }

    private func cancelPresetInstall(_ preset: SmartModelPreset) {
        MLXModelInstaller.shared.cancelInstall()
    }

    private func applyPreset(_ preset: SmartModelPreset) {
        switch preset {
        case .light:
            MLXModelCatalog.selectedWhisperModel = MLXModelCatalog.whisperBase
            selectProvider(.whisper)
        case .balanced:
            selectProvider(.parakeet)
        case .best:
            if MLXModelCatalog.selectedWhisperModel == MLXModelCatalog.whisperBase {
                MLXModelCatalog.selectedWhisperModel = MLXModelCatalog.whisperLargeTurbo
            }
            selectProvider(.whisper)
        case .cloud:
            selectProvider(.openaiAPI)
        }
    }

    private var activePreset: SmartModelPreset {
        switch selectedKind {
        case .openaiAPI:
            return .cloud
        case .parakeet:
            return .balanced
        case .whisper:
            return MLXModelCatalog.selectedWhisperModel == MLXModelCatalog.whisperBase ? .light : .best
        case .appleSpeech, .stub:
            return .light
        }
    }

    private struct PresetStatus {
        let message: String
        let severity: ProviderMessageSeverity
    }

    private func presetStatusMessage(for preset: SmartModelPreset, diagnostics: ProviderRuntimeDiagnostics) -> PresetStatus? {
        // Install-state prompts live on the card's action button now; the only
        // status worth a banner is the active provider silently falling back.
        // Wording comes from AppStatusCatalog so the banner matches the menu
        // bar and overlay exactly.
        guard preset == activePreset else { return nil }
        if let status = diagnostics.userFacingStatus {
            return PresetStatus(message: status.message, severity: ProviderMessageSeverity(status.severity))
        }
        return nil
    }

    @ViewBuilder
    private func statusText(_ message: String, severity: ProviderMessageSeverity) -> some View {
        HStack(alignment: .top, spacing: VFSpacing.xs) {
            Image(systemName: severity.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(severity.color)
                .padding(.top, 1)
            Text(message)
                .font(VFFont.settingsCaption)
                .foregroundStyle(severity.color)
        }
        .padding(.horizontal, VFSpacing.sm)
        .padding(.vertical, VFSpacing.xs)
        .background(
            Rectangle()
                .fill(severity.color.opacity(0.10))
                .overlay(Rectangle().stroke(severity.color.opacity(0.35), lineWidth: 1))
        )
    }

    private func profileActionButton(
        title: String,
        isPrimary: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(GlassCapsuleButtonStyle(tone: isPrimary ? .primary : .neutral))
        .focusable(true)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func installedChip(label: String, color: Color = VFColor.success) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(VFFont.archivo(11, .semibold))
                .foregroundStyle(color == VFColor.accent ? VFColor.accentStrong : color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Rectangle().fill(color.opacity(0.12)))
    }

    private func selectProvider(_ kind: STTProviderKind) {
        selectedKind = kind
        kind.saveSelection()
        NotificationCenter.default.post(name: .sttProviderDidChange, object: nil)
    }

    private func persistOpenAIEndpointConfiguration() {
        openAIBaseURL = DictationProviderPolicy.normalizedOpenAIBaseURL(openAIBaseURL)
        openAIModel = DictationProviderPolicy.normalizedOpenAIModel(openAIModel)

        DictationProviderPolicy.openAIEndpointProfile = openAIEndpointProfile
        DictationProviderPolicy.openAIBaseURL = openAIBaseURL
        DictationProviderPolicy.openAIModel = openAIModel

        NotificationCenter.default.post(name: .sttProviderDidChange, object: nil)

        if let endpointError = DictationProviderPolicy.validateOpenAIEndpoint(
            baseURL: openAIBaseURL,
            model: openAIModel
        ) {
            openAIAPIKeyStatusSeverity = .warning
            openAIAPIKeyStatusMessage = "Endpoint saved, but configuration is invalid. \(endpointError)"
            return
        }

        openAIAPIKeyStatusSeverity = .info
        openAIAPIKeyStatusMessage = "Endpoint settings saved."
    }

    private func persistOpenAIAPIKey(_ explicitKey: String? = nil) {
        persistOpenAIEndpointConfiguration()
        let normalized = DictationProviderPolicy.normalizedOpenAIAPIKey(explicitKey ?? openAIAPIKey)
        openAIAPIKey = normalized
        let persistenceResult = DictationProviderPolicy.persistOpenAIAPIKey(normalized)
        // Saving a key can auto-enable cloud fallback (unless the user
        // explicitly turned it off) — reflect that in the visible toggle.
        // The toggle's onChange no-ops because the persisted value already
        // matches, so this does not count as an explicit user override.
        cloudFallbackEnabled = DictationProviderPolicy.cloudFallbackEnabled
        NotificationCenter.default.post(name: .sttProviderDidChange, object: nil)

        switch DictationProviderPolicy.validateOpenAIAPIKey(normalized) {
        case .empty:
            openAIAPIKeyStatusSeverity = .warning
            openAIAPIKeyStatusMessage = "No key detected. Paste your OpenAI key and save again."
        case .valid:
            openAIAPIKeyStatusSeverity = .info
            openAIAPIKeyStatusMessage = "API key saved securely."
        case .suspiciousPrefix:
            openAIAPIKeyStatusSeverity = .warning
            openAIAPIKeyStatusMessage = "API key saved, but format looks unusual. Check key length/prefix."
        case .malformed(let reason):
            openAIAPIKeyStatusSeverity = .warning
            openAIAPIKeyStatusMessage = "API key saved, but may be invalid. \(reason)"
        }

        if persistenceResult == .savedUserDefaultsFallback {
            openAIAPIKeyStatusSeverity = .warning
            openAIAPIKeyStatusMessage = "API key saved, but secure Keychain storage was unavailable. Using local fallback storage."
        }
    }

    private func pasteAndSaveOpenAIAPIKey() {
        guard let clipboard = NSPasteboard.general.string(forType: .string),
              !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            openAIAPIKeyStatusSeverity = .warning
            openAIAPIKeyStatusMessage = "Clipboard is empty. Copy your OpenAI key and retry."
            return
        }

        persistOpenAIAPIKey(clipboard)
    }

    /// Recomputes provider diagnostics for every preset card. Must only run
    /// outside a view update (deferred onAppear, notification delivery) —
    /// diagnostics touch TCC, Keychain, and the filesystem.
    private func refreshPresetDiagnostics() {
        var map: [STTProviderKind: ProviderRuntimeDiagnostics] = [:]
        for preset in SmartModelPreset.allCases {
            map[preset.provider] = STTProviderResolver.diagnostics(for: preset.provider)
        }
        presetDiagnostics = map
    }
}

private struct DiagnosticLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: VFSpacing.xs) {
            Text(label + ":")
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textSecondary)
            Text(value)
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textPrimary)
        }
    }
}

// MARK: - Model Download Row

private struct MLXModelDetailRow: View {
    let kind: STTProviderKind
    @ObservedObject var installer: MLXModelInstaller
    @State private var runtimeStatus = MLXRuntimeBootstrapManager.shared.statusSnapshot()
    @State private var selectedModelID: String = ""

    private var options: [MLXModel] {
        kind == .parakeet ? MLXModelCatalog.parakeetOptions : MLXModelCatalog.whisperOptions
    }

    private var selectedModel: MLXModel {
        MLXModelCatalog.model(withID: selectedModelID)
            ?? MLXModelCatalog.selectedModel(for: kind)
            ?? MLXModelCatalog.parakeetV3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: VFSpacing.xxs) {
                    Text("Model")
                        .font(VFFont.settingsBody)
                        .foregroundStyle(VFColor.textPrimary)
                    Text("Runs locally with MLX on Apple Silicon.")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)
                }
                Spacer()
                Menu {
                    ForEach(options) { option in
                        Button("\(option.displayName) · \(option.qualityBand) · \(option.approxSizeLabel)") {
                            select(option)
                        }
                    }
                } label: {
                    Text(selectedModel.displayName)
                        .glassSelectPill()
                }
                .menuStyle(.button)
                    .buttonStyle(.plain)
            }

            NeuDivider()

            DiagnosticLine(label: "Status", value: statusLine)
            DiagnosticLine(label: "Runtime", value: runtimeStatusLine)
            DiagnosticLine(label: "Source", value: selectedModel.repo)

            switch installer.phase {
            case .installing(let modelID, let detail) where modelID == selectedModel.id:
                HStack(spacing: VFSpacing.sm) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text(detail)
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)
                    Button {
                        installer.cancelInstall()
                    } label: {
                        Text("Cancel")
                            .font(VFFont.pillLabel)
                            .foregroundStyle(VFColor.textPrimary)
                    }
                    .buttonStyle(GlassCapsuleButtonStyle(tone: .neutral))
                }
            case .failed(let modelID, let message) where modelID == selectedModel.id:
                HStack(alignment: .top, spacing: VFSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(VFColor.error)
                    Text(message)
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.error)
                }
                installButton(title: "Retry install")
            default:
                if !installer.isInstalled(selectedModel) {
                    installButton(title: "Download \(selectedModel.displayName) (\(selectedModel.approxSizeLabel))")
                }
            }
        }
        .padding(VFSpacing.md)
        .background(
            Rectangle()
                .fill(VFColor.panel2)
                .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
        )
        .onAppear {
            // Deferred: state writes during the initial layout pass re-enter
            // the view graph mid-update.
            DispatchQueue.main.async {
                selectedModelID = MLXModelCatalog.selectedModel(for: kind)?.id ?? ""
            }
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .mlxRuntimeBootstrapDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            runtimeStatus = MLXRuntimeBootstrapManager.shared.statusSnapshot()
        }
    }

    private func select(_ option: MLXModel) {
        selectedModelID = option.id
        if kind == .parakeet {
            MLXModelCatalog.selectedParakeetModel = option
        } else {
            MLXModelCatalog.selectedWhisperModel = option
        }
        NotificationCenter.default.post(name: .sttProviderDidChange, object: nil)
    }

    private func installButton(title: String) -> some View {
        Button {
            MLXModelInstaller.shared.install(selectedModel)
        } label: {
            Text(title)
                .font(VFFont.pillLabel)
                .foregroundStyle(VFColor.textOnAccent)
        }
        .buttonStyle(GlassCapsuleButtonStyle(tone: .primary))
    }

    private var statusLine: String {
        installer.isInstalled(selectedModel)
            ? "Installed (\(selectedModel.approxSizeLabel))"
            : "Not installed"
    }

    private var runtimeStatusLine: String {
        switch runtimeStatus.phase {
        case .idle:
            return "Not installed (installs with the model)"
        case .bootstrapping:
            return "Installing… \(runtimeStatus.detail)"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed — \(runtimeStatus.detail)"
        }
    }
}

private struct TranscriptHistoryTab: View {
    @ObservedObject private var store = TranscriptLogStore.shared
    @ObservedObject private var metricsStore = DictationSessionMetricsStore.shared
    @State private var query: String = ""

    private var filteredEntries: [TranscriptLogEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.text.lowercased().contains(q) ||
            $0.provider.lowercased().contains(q) ||
            $0.appName.lowercased().contains(q)
        }
    }

    private var metricsSummary: DictationSessionMetricsSummary {
        metricsStore.summary(last: 200)
    }

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            NeuSection(icon: "list.bullet.rectangle.portrait", title: "Transcript Log") {
                VStack(alignment: .leading, spacing: VFSpacing.sm) {
                    HStack(spacing: VFSpacing.sm) {
                        TextField("Search transcripts", text: $query)
                            .textFieldStyle(.plain)
                            .glassInputField()

                        iconActionButton(systemName: "doc.on.doc", accessibilityLabel: "Copy all") {
                            store.copy(filteredEntries.map(\.text).joined(separator: "\n"))
                        }

                        iconActionButton(systemName: "trash", accessibilityLabel: "Clear") {
                            store.clearAll()
                        }
                    }

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 4),
                        spacing: 1
                    ) {
                        metricChip(title: "Entries", value: "\(store.entries.count)")
                        metricChip(title: "Success", value: "\(successRatePercent)%")
                        metricChip(title: "Avg STT", value: averageLatencyLabel)
                        metricChip(title: "Avg E2E", value: averageEndToEndLabel)
                        if !topProviderLabel.isEmpty {
                            metricChip(title: "Top provider", value: topProviderLabel)
                        }
                        if !topAppLabel.isEmpty {
                            metricChip(title: "Top app", value: topAppLabel)
                        }
                    }
                    .background(VFColor.border)
                    .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))

                    if filteredEntries.isEmpty {
                        Text(query.isEmpty ? "No transcripts yet." : "No transcripts match your search.")
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.muted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, VFSpacing.xl)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(filteredEntries.prefix(100)) { entry in
                                HStack(alignment: .top, spacing: 14) {
                                    Text(Self.timeFormatter.string(from: entry.timestamp))
                                        .font(VFFont.archivo(12, .semibold))
                                        .foregroundStyle(VFColor.muted)
                                        .frame(width: 62, alignment: .leading)
                                        .padding(.top, 1)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.provider)
                                            .font(VFFont.archivo(12.5, .semibold))
                                            .foregroundStyle(VFColor.accent)
                                        Text(entry.appName)
                                            .font(VFFont.archivo(11))
                                            .foregroundStyle(VFColor.muted)
                                    }
                                    .frame(width: 140, alignment: .leading)

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(entry.text)
                                            .font(VFFont.archivo(13))
                                            .foregroundStyle(VFColor.text)
                                            .lineLimit(2)
                                            .textSelection(.enabled)

                                        HStack(spacing: 7) {
                                            HStack(spacing: 5) {
                                                Circle()
                                                    .fill(VFColor.accent)
                                                    .frame(width: 5, height: 5)
                                                Text(entry.status.uppercased())
                                                    .font(VFFont.archivo(10.5, .semibold))
                                                    .tracking(0.4)
                                                    .foregroundStyle(VFColor.muted)
                                            }
                                            if let duration = entry.durationMs {
                                                Text("\(duration) ms")
                                                    .font(VFFont.archivo(11))
                                                    .foregroundStyle(VFColor.muted)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    HStack(spacing: 6) {
                                        iconActionButton(systemName: "arrow.uturn.backward", accessibilityLabel: "Re-insert transcript") {
                                            store.requestReinsert(entry.text)
                                        }
                                        iconActionButton(systemName: "doc.on.doc", accessibilityLabel: "Copy transcript") {
                                            store.copy(entry.text)
                                        }
                                        iconActionButton(systemName: "character.book.closed", accessibilityLabel: "Add to dictionary") {
                                            addToDictionary(entry)
                                        }
                                    }
                                }
                                .padding(.vertical, 15)
                                .padding(.horizontal, 2)
                                .overlay(alignment: .top) {
                                    Rectangle().fill(VFColor.border).frame(height: 1)
                                }
                            }
                        }
                        .padding(.top, VFSpacing.xs)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func iconActionButton(systemName: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VFColor.textPrimary)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(GlassIconButtonStyle(cornerRadius: 9))
        .focusable(true)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Opens the Dictionary & Style tab with a correction entry pre-filled from
    /// the user's current text selection (when one exists in this row) or the
    /// row's full transcript text.
    private func addToDictionary(_ entry: TranscriptLogEntry) {
        let selection = currentSelectedText()
        let text = (selection?.isEmpty == false ? selection! : entry.text)
        CorrectionDictionaryPrefill.request(text: text)
    }

    /// Best-effort read of the focused text selection inside the settings
    /// window (e.g. a selection made in a selectable transcript row).
    private func currentSelectedText() -> String? {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSText else { return nil }
        let range = responder.selectedRange
        let full = responder.string
        guard range.length > 0, let swiftRange = Range(range, in: full) else { return nil }
        return String(full[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stat tile in the metrics grid: uppercase kicker over a heavy value.
    private func metricChip(title: String, value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(VFFont.kicker)
                .tracking(0.8)
                .foregroundStyle(VFColor.muted)
            Text(value)
                .font(value.count > 9 ? VFFont.archivo(12, .bold) : VFFont.statValue)
                .foregroundStyle(tint ?? VFColor.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(VFColor.panel)
    }

    private var successRatePercent: Int {
        guard !store.entries.isEmpty else { return 0 }
        let successCount = store.entries.filter { $0.status == "inserted" }.count
        return Int((Double(successCount) / Double(store.entries.count)) * 100)
    }

    private var averageLatencyLabel: String {
        let durations = store.entries.compactMap(\.durationMs)
        guard !durations.isEmpty else { return "—" }
        let avg = durations.reduce(0, +) / durations.count
        return "\(avg)ms"
    }

    private var averageEndToEndLabel: String {
        guard let avg = metricsSummary.averageEndToEndMs else { return "—" }
        return "\(avg)ms"
    }

    private var topProviderLabel: String {
        let grouped = Dictionary(grouping: store.entries, by: { $0.provider })
        guard let top = grouped.max(by: { $0.value.count < $1.value.count }) else { return "" }
        return "\(top.key) (\(top.value.count))"
    }

    private var topAppLabel: String {
        let grouped = Dictionary(grouping: store.entries, by: { $0.appName })
        guard let top = grouped.max(by: { $0.value.count < $1.value.count }) else { return "" }
        return "\(top.key) (\(top.value.count))"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Neumorphic Toggle Row

private struct NeuToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: VFSpacing.xs) {
                Text(title)
                    .font(VFFont.settingsBody)
                    .foregroundStyle(VFColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            NeuPillToggle(isOn: $isOn, accessibilityLabel: title)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Modernist Square Toggle

/// Zero-radius switch: accent-filled track with a square white knob when on,
/// bordered track with a gray knob when off.
private struct NeuPillToggle: View {
    @Binding var isOn: Bool
    let accessibilityLabel: String

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(isOn ? VFColor.accent : Color.clear)
                    .overlay(
                        Rectangle().stroke(isOn ? VFColor.accent : VFColor.border2, lineWidth: 1)
                    )
                Rectangle()
                    .fill(isOn ? Color.white : VFColor.knobOff)
                    .frame(width: 20, height: 20)
                    .offset(x: isOn ? 23 : 3)
            }
            .frame(width: 46, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(true)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Preview

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .preferredColorScheme(.dark)
    }
}
#endif
