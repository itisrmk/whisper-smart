import SwiftUI
import Carbon.HIToolbox

/// Root settings view hosted in its own `NSWindow`.
/// Dark neumorphic design with soft raised cards, inset controls,
/// and an iOS-like rounded aesthetic.
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──
            VStack(alignment: .leading, spacing: VFSpacing.sm) {
                Text("Settings")
                    .font(VFFont.settingsHeading)
                    .foregroundStyle(VFColor.textPrimary)
                Text("Configure Whisper Smart to your liking")
                    .font(VFFont.settingsBody)
                    .foregroundStyle(VFColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VFSpacing.xxl)
            .padding(.top, VFSpacing.xxl)
            .padding(.bottom, VFSpacing.lg)

            // ── Segmented tab bar ──
            GlassSegmentedControl(
                selection: $selectedTab,
                items: SettingsTab.allCases
            )
            .padding(.horizontal, VFSpacing.xxl)
            .padding(.bottom, VFSpacing.xl)

            // ── Tab content ──
            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    switch selectedTab {
                    case .general:  GeneralSettingsTab()
                    case .hotkey:   HotkeySettingsTab()
                    case .provider: ProviderSettingsTab()
                    case .history:  TranscriptHistoryTab()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, VFSpacing.xxl)
                .padding(.bottom, VFSpacing.xxl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: VFSize.settingsWidth, height: VFSize.settingsHeight)
        .layeredDepthBackground()
        .vfForcedDarkTheme()
        .animation(VFAnimation.fadeMedium, value: selectedTab)
    }
}

// MARK: - Tab Enum

private enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, hotkey, provider, history

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:  return "General"
        case .hotkey:   return "Hotkey"
        case .provider: return "Provider"
        case .history:  return "History"
        }
    }

    var icon: String {
        switch self {
        case .general:  return "gearshape.fill"
        case .hotkey:   return "command"
        case .provider: return "cloud.fill"
        case .history:  return "list.bullet.rectangle.portrait"
        }
    }
}

// MARK: - Glass Segmented Control

/// A custom segmented control styled as a neumorphic pill bar with
/// a soft sliding selection indicator.
private struct GlassSegmentedControl: View {
    @Binding var selection: SettingsTab
    let items: [SettingsTab]

    @Namespace private var segmentNS

    var body: some View {
        HStack(spacing: VFSpacing.xxs) {
            ForEach(items) { item in
                let isSelected = (selection == item)
                Button {
                    withAnimation(VFAnimation.springSnappy) {
                        selection = item
                    }
                } label: {
                    HStack(spacing: VFSpacing.sm) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(item.label)
                            .font(VFFont.segmentLabel)
                    }
                    .foregroundStyle(isSelected ? VFColor.textPrimary : VFColor.textSecondary)
                    .padding(.horizontal, VFSpacing.lg)
                    .padding(.vertical, VFSpacing.sm + 2)
                    .frame(maxWidth: .infinity)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: VFRadius.segment, style: .continuous)
                                .fill(VFColor.glass2)
                                .shadow(color: VFColor.neuDark, radius: 4, x: 2, y: 2)
                                .shadow(color: VFColor.neuLight, radius: 1, x: -1, y: -1)
                                .overlay(
                                    RoundedRectangle(cornerRadius: VFRadius.segment, style: .continuous)
                                        .stroke(
                                            LinearGradient(
                                                stops: [
                                                    .init(color: Color.white.opacity(0.10), location: 0.0),
                                                    .init(color: .clear, location: 0.4),
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 0.5
                                        )
                                )
                                .matchedGeometryEffect(id: "segment", in: segmentNS)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(VFSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.pill, style: .continuous)
                .fill(VFColor.controlInset)
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.pill, style: .continuous)
                        .stroke(
                            LinearGradient(
                                stops: [
                                    .init(color: VFColor.neuInsetDark, location: 0.0),
                                    .init(color: .clear, location: 0.5),
                                    .init(color: VFColor.neuInsetLight, location: 1.0),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: VFColor.neuInsetDark, radius: 4, x: 2, y: 2)
        )
    }
}

// MARK: - Section Container

/// A titled neumorphic card section for settings content.
private struct NeuSection<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.lg) {
            VStack(alignment: .leading, spacing: VFSpacing.sm) {
                HStack(spacing: VFSpacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VFColor.accentFallback)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(VFColor.accentFallback.opacity(0.15))
                        )
                    Text(title)
                        .font(VFFont.settingsTitle)
                        .foregroundStyle(VFColor.textPrimary)
                }

                // Subtle accent underline for visual hierarchy
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [VFColor.accentFallback.opacity(0.25), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
            }

            content()
        }
        .padding(VFSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

// Keep backward compat alias
private typealias GlassSection = NeuSection

// MARK: - Separator

private struct NeuDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: VFColor.neuInsetDark.opacity(0.5), location: 0),
                        .init(color: VFColor.glassBorder, location: 0.5),
                        .init(color: VFColor.neuInsetLight, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: 1)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("dictationOverlayMode") private var overlayModeRaw = DictationOverlayMode.topCenterWaveform.rawValue
    @AppStorage("recordingSoundsEnabled") private var recordingSoundsEnabled = true
    @AppStorage("postProcessingPipelineEnabled") private var postProcessingPipelineEnabled = true
    @AppStorage("commandModeScaffoldEnabled") private var commandModeScaffoldEnabled = false

    @State private var availableInputDevices: [AudioInputDevice] = []
    @State private var selectedInputDeviceUID: String = ""
    @State private var inputDeviceMenuExpanded = false

    @State private var silenceTimeoutSeconds = DictationWorkflowSettings.silenceTimeoutSeconds
    @State private var insertionMode = DictationWorkflowSettings.insertionMode
    @State private var perAppDefaultsJSON = DictationWorkflowSettings.perAppDefaultsJSON
    @State private var snippetsJSON = DictationWorkflowSettings.snippetsJSON
    @State private var correctionDictionaryJSON = DictationWorkflowSettings.correctionDictionaryJSON
    @State private var customAIInstructions = DictationWorkflowSettings.customAIInstructions
    @State private var developerModeEnabled = DictationWorkflowSettings.developerModeEnabled
    @State private var voiceCommandFormattingEnabled = DictationWorkflowSettings.voiceCommandFormattingEnabled

    @State private var permSnap = PermissionDiagnostics.snapshot()

    @State private var perAppProfiles: [PerAppProfileDraft] = []
    @State private var snippetRows: [PhraseMappingDraft] = []
    @State private var correctionRows: [PhraseMappingDraft] = []

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

    private let profileStyles = ["formal", "casual", "concise", "developer"]

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
                            .font(VFFont.pillLabel)
                            .foregroundStyle(VFColor.textPrimary)
                    }
                    .menuStyle(.borderlessButton)
                }
                NeuDivider()
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
                        HStack(spacing: VFSpacing.xs) {
                            Text(selectedInputDeviceName)
                                .font(VFFont.pillLabel)
                                .foregroundStyle(VFColor.textPrimary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, VFSpacing.md)
                        .padding(.vertical, VFSpacing.sm)
                        .background(
                            Capsule()
                                .fill(VFColor.glass3)
                                .shadow(color: VFColor.neuDark, radius: 3, x: 2, y: 2)
                                .shadow(color: VFColor.neuLight, radius: 1, x: -1, y: -1)
                                .overlay(
                                    Capsule()
                                        .stroke(
                                            LinearGradient(
                                                stops: [
                                                    .init(color: Color.white.opacity(0.08), location: 0),
                                                    .init(color: .clear, location: 0.4),
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 0.5
                                        )
                                )
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 180)
                }
                NeuDivider()
                NeuToggleRow(
                    title: "Recording sounds",
                    subtitle: "Play a short sound when recording starts and stops",
                    isOn: $recordingSoundsEnabled
                )
                NeuDivider()
                NeuToggleRow(
                    title: "Transcript cleanup pipeline",
                    subtitle: "Apply conservative text cleanup after transcription",
                    isOn: $postProcessingPipelineEnabled
                )
                NeuDivider()
                NeuToggleRow(
                    title: "Command mode scaffold",
                    subtitle: "Route command-style phrases through a safe passthrough scaffold",
                    isOn: $commandModeScaffoldEnabled
                )
            }

            NeuSection(icon: "wand.and.stars", title: "Workflow") {
                VStack(alignment: .leading, spacing: VFSpacing.md) {
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
                                .font(VFFont.pillLabel)
                                .foregroundStyle(VFColor.textPrimary)
                        }
                        .menuStyle(.borderlessButton)
                    }

                    NeuDivider()

                    perAppProfilesEditor
                }
            }

            NeuSection(icon: "sparkles.rectangle.stack", title: "Intelligence") {
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

                    VStack(alignment: .leading, spacing: VFSpacing.sm) {
                        Text("Custom AI instructions (cloud)")
                            .font(VFFont.settingsBody)
                            .foregroundStyle(VFColor.textPrimary)

                        TextEditor(text: $customAIInstructions)
                            .font(.system(size: 11, design: .rounded))
                            .frame(height: 78)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(VFColor.glass3.opacity(0.45))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(VFColor.glassBorder, lineWidth: 0.5)
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

                    NeuDivider()

                    snippetsEditor

                    NeuDivider()

                    correctionDictionaryEditor
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
                            .padding(.horizontal, VFSpacing.md)
                            .padding(.vertical, VFSpacing.sm)
                            .background(
                                Capsule()
                                    .fill(VFColor.glass3)
                                    .shadow(color: VFColor.neuDark, radius: 3, x: 2, y: 2)
                                    .shadow(color: VFColor.neuLight, radius: 1, x: -1, y: -1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, VFSpacing.xs)
                }
            }
        }
        .onAppear {
            // Ensure old `showBubble` users get migrated to the new mode key.
            overlayModeRaw = DictationOverlaySettings.overlayMode.rawValue
            recordingSoundsEnabled = DictationOverlaySettings.recordingSoundsEnabled
            permSnap = PermissionDiagnostics.snapshot()
            silenceTimeoutSeconds = DictationWorkflowSettings.silenceTimeoutSeconds
            insertionMode = DictationWorkflowSettings.insertionMode
            perAppDefaultsJSON = DictationWorkflowSettings.perAppDefaultsJSON
            snippetsJSON = DictationWorkflowSettings.snippetsJSON
            correctionDictionaryJSON = DictationWorkflowSettings.correctionDictionaryJSON
            customAIInstructions = DictationWorkflowSettings.customAIInstructions
            developerModeEnabled = DictationWorkflowSettings.developerModeEnabled
            voiceCommandFormattingEnabled = DictationWorkflowSettings.voiceCommandFormattingEnabled

            // Load available input devices
            availableInputDevices = AudioDeviceManager.availableInputDevices()
            selectedInputDeviceUID = DictationWorkflowSettings.selectedInputDeviceUID

            perAppProfiles = parsePerAppProfiles(from: perAppDefaultsJSON)
            snippetRows = parsePhraseMap(from: snippetsJSON)
            correctionRows = parsePhraseMap(from: correctionDictionaryJSON)
        }
        .onChange(of: overlayModeRaw) { _, newValue in
            DictationOverlaySettings.overlayMode = DictationOverlayMode(rawValue: newValue) ?? .topCenterWaveform
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
                            .textFieldStyle(.roundedBorder)

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
                            }
                            .buttonStyle(.plain)
                        }

                        HStack(spacing: VFSpacing.sm) {
                            TextField(
                                "Optional prefix",
                                text: Binding(
                                    get: { perAppProfiles[index].prefix },
                                    set: { perAppProfiles[index].prefix = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)

                            TextField(
                                "Optional suffix",
                                text: Binding(
                                    get: { perAppProfiles[index].suffix },
                                    set: { perAppProfiles[index].suffix = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
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
                            .textFieldStyle(.roundedBorder)

                            TextField(
                                "Expansion text",
                                text: Binding(
                                    get: { snippetRows[index].value },
                                    set: { snippetRows[index].value = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)

                            Button(role: .destructive) {
                                snippetRows.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.plain)
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
                            .textFieldStyle(.roundedBorder)

                            TextField(
                                "To",
                                text: Binding(
                                    get: { correctionRows[index].value },
                                    set: { correctionRows[index].value = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)

                            Button(role: .destructive) {
                                correctionRows.remove(at: index)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.plain)
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
            RoundedRectangle(cornerRadius: VFRadius.field, style: .continuous)
                .fill(VFColor.glass2.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.field, style: .continuous)
                        .stroke(VFColor.glassBorder.opacity(0.85), lineWidth: 0.6)
                )
                .overlay(
                    GrainTexture(opacity: 0.012, cellSize: 2)
                        .clipShape(RoundedRectangle(cornerRadius: VFRadius.field, style: .continuous))
                )
        )
    }

    @ViewBuilder
    private func editorRowContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            content()
        }
        .padding(VFSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.field - 1, style: .continuous)
                .fill(VFColor.glass3.opacity(0.40))
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.field - 1, style: .continuous)
                        .stroke(VFColor.glassBorder.opacity(0.75), lineWidth: 0.5)
                )
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
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(VFColor.error.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(VFColor.error.opacity(0.35), lineWidth: 0.6)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func emptyStateCard(_ text: String) -> some View {
        Text(text)
            .font(VFFont.settingsCaption)
            .foregroundStyle(VFColor.textSecondary)
            .padding(VFSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(VFColor.controlInset.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(VFColor.glassBorder, lineWidth: 0.5)
                    )
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
            .foregroundStyle(VFColor.textOnAccent)
            .padding(.horizontal, VFSpacing.md)
            .padding(.vertical, VFSpacing.sm)
            .background(
                Capsule()
                    .fill(VFColor.accentGradient)
                    .shadow(color: VFColor.neuDark.opacity(configuration.isPressed ? 0.20 : 0.35), radius: configuration.isPressed ? 2 : 5, x: 0, y: configuration.isPressed ? 1 : 3)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.20), lineWidth: 0.6)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
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
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.accentFallback)
                }
                .buttonStyle(.plain)
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
                            HStack(spacing: VFSpacing.sm) {
                                if isRecording {
                                    Circle()
                                        .fill(VFColor.error)
                                        .frame(width: 6, height: 6)
                                    Text(liveModifiers.isEmpty ? "Press shortcut…" : liveModifiers)
                                        .font(VFFont.pillLabel)
                                        .foregroundStyle(VFColor.textPrimary)
                                } else {
                                    Text(currentBinding.displayString)
                                        .font(VFFont.pillLabel)
                                        .foregroundStyle(VFColor.textPrimary)
                                }
                            }
                            .padding(.horizontal, VFSpacing.md)
                            .padding(.vertical, VFSpacing.sm)
                            .frame(minWidth: 110)
                            .background(
                                Group {
                                    if isRecording {
                                        Capsule()
                                            .fill(VFColor.controlInset)
                                            .overlay(
                                                Capsule()
                                                    .stroke(VFColor.accentFallback.opacity(0.5), lineWidth: 1.5)
                                            )
                                            .shadow(color: VFColor.accentFallback.opacity(0.15), radius: 6)
                                    } else {
                                        Capsule()
                                            .fill(VFColor.glass3)
                                            .shadow(color: VFColor.neuDark, radius: 3, x: 2, y: 2)
                                            .shadow(color: VFColor.neuLight, radius: 1, x: -1, y: -1)
                                            .overlay(
                                                Capsule()
                                                    .stroke(
                                                        LinearGradient(
                                                            stops: [
                                                                .init(color: Color.white.opacity(0.08), location: 0),
                                                                .init(color: .clear, location: 0.4),
                                                            ],
                                                            startPoint: .top,
                                                            endPoint: .bottom
                                                        ),
                                                        lineWidth: 0.5
                                                    )
                                            )
                                    }
                                }
                            )
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
                            .foregroundStyle(VFColor.textPrimary)
                            .padding(.horizontal, VFSpacing.md)
                            .padding(.vertical, VFSpacing.sm)
                            .background(
                                Capsule()
                                    .fill(VFColor.glass3)
                                    .shadow(color: VFColor.neuDark, radius: 3, x: 2, y: 2)
                                    .shadow(color: VFColor.neuLight, radius: 1, x: -1, y: -1)
                                    .overlay(
                                        Capsule()
                                            .stroke(
                                                LinearGradient(
                                                    stops: [
                                                        .init(color: Color.white.opacity(0.08), location: 0),
                                                        .init(color: .clear, location: 0.4),
                                                    ],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                ),
                                                lineWidth: 0.5
                                            )
                                    )
                            )
                        }
                        .menuStyle(.borderlessButton)
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
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        return parts.joined(separator: " ")
    }

    private var presetDisplayString: String {
        if selectedPresetIndex >= 0 && selectedPresetIndex < HotkeyBinding.presets.count {
            return HotkeyBinding.presets[selectedPresetIndex].displayString
        }
        return "Custom"
    }

    private static func initialPresetIndex() -> Int {
        let current = HotkeyBinding.load()
        return HotkeyBinding.presets.firstIndex(of: current) ?? -1
    }
}

// MARK: - Notification name for binding changes

extension Notification.Name {
    static let hotkeyBindingDidChange = Notification.Name("hotkeyBindingDidChange")
}

// MARK: - Notification for provider changes

extension Notification.Name {
    static let sttProviderDidChange = Notification.Name("sttProviderDidChange")
}

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
            case .light: return "Whisper Tiny/Base · fastest local"
            case .balanced: return "Parakeet TDT 0.6B v3 · local ONNX (experimental)"
            case .best: return "Whisper Large-v3 Turbo · highest local accuracy"
            case .cloud: return "OpenAI Whisper API · remote transcription"
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
    @StateObject private var downloadState = ModelDownloadState(variant: .parakeetCTC06B)
    @StateObject private var whisperInstaller = WhisperModelInstaller.shared
    @StateObject private var whisperRuntimeInstaller = WhisperRuntimeInstaller.shared
    @StateObject private var ttsPlaceholderDownloader = TTSModelPlaceholderDownloader.shared
    @State private var openAIAPIKey = DictationProviderPolicy.openAIAPIKey

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
    }

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            NeuSection(icon: "waveform.and.mic", title: "Smart Model Selection") {
                VStack(alignment: .leading, spacing: VFSpacing.lg) {
                    Text("Choose a one-click STT preset. If host prerequisites (Apple Command Line Tools, make, Python/venv) are missing, setup fails fast with guidance and Whisper Smart falls back to Apple Speech.")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)

                    VStack(spacing: VFSpacing.md) {
                        ForEach(SmartModelPreset.allCases) { preset in
                            presetCard(preset)
                        }
                    }

                    if selectedKind == .parakeet {
                        ModelDownloadRow(kind: .parakeet, downloadState: downloadState)
                    }

                    if selectedKind == .whisper || selectedKind == .openaiAPI {
                        providerConfigurationSection
                    }
                }
            }

            NeuSection(icon: "speaker.wave.3.fill", title: "Text-to-Speech (Preview)") {
                VStack(alignment: .leading, spacing: VFSpacing.sm) {
                    Text("One-click TTS model option")
                        .font(VFFont.settingsBody)
                        .foregroundStyle(VFColor.textPrimary)

                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: VFSpacing.xxs) {
                            Text("\(TTSModelPlaceholderOption.qwen3CustomVoice.displayName)")
                                .font(VFFont.settingsCaption)
                                .foregroundStyle(VFColor.textPrimary)
                            Text("Download preview assets in one click. Synthesis runtime is not integrated yet, so this does not alter STT behavior.")
                                .font(VFFont.settingsCaption)
                                .foregroundStyle(VFColor.textSecondary)
                        }
                        Spacer()

                        switch ttsPlaceholderDownloader.phase {
                        case .downloading:
                            profileActionButton(title: "Downloading…", isPrimary: true, enabled: false) {}
                        case .ready:
                            installedChip(label: "Preview Assets Downloaded", color: VFColor.accentFallback)
                        case .idle, .failed:
                            profileActionButton(title: "Download", isPrimary: true, enabled: true) {
                                DictationFeatureFlags.ttsPlaceholderEnabled = true
                                ttsPlaceholderDownloader.downloadPreviewAsset()
                            }
                        }
                    }

                    switch ttsPlaceholderDownloader.phase {
                    case .idle:
                        statusText("Preview only. TTS synthesis is coming soon.", severity: .info)
                    case .downloading:
                        statusText("Downloading preview assets…", severity: .info)
                    case .ready(let localPath):
                        Text("Preview assets ready at \(localPath). TTS synthesis is not yet enabled in this build.")
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.textSecondary)
                            .textSelection(.enabled)
                    case .failed(let message):
                        statusText(sanitizedStatusMessage(message, fallback: "Couldn’t download preview assets. Check your connection and try again."), severity: .error)
                    }
                }
            }
        }
        .onAppear {
            syncDownloadState(for: selectedKind)
            DictationProviderPolicy.cloudFallbackEnabled = true
            openAIAPIKey = DictationProviderPolicy.openAIAPIKey
            whisperRuntimeInstaller.refreshState()
            whisperInstaller.refreshState()
            ttsPlaceholderDownloader.refresh()
        }
    }

    @ViewBuilder
    private var providerConfigurationSection: some View {
        if selectedKind == .openaiAPI {
            VStack(alignment: .leading, spacing: VFSpacing.xs) {
                Text("OpenAI API key")
                    .font(VFFont.settingsBody)
                    .foregroundStyle(VFColor.textPrimary)
                SecureField("sk-...", text: $openAIAPIKey)
                    .textFieldStyle(.roundedBorder)
                Button("Save API Key") {
                    DictationProviderPolicy.openAIAPIKey = openAIAPIKey
                    NotificationCenter.default.post(name: .sttProviderDidChange, object: nil)
                }
                .buttonStyle(.plain)
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textPrimary)

                Text("OpenAI-compatible endpoints (including Qwen-hosted gateways) are not yet configurable in this build; this profile currently targets OpenAI's official endpoint.")
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.textSecondary)
            }
        } else if selectedKind == .whisper {
            VStack(alignment: .leading, spacing: VFSpacing.sm) {
                Text("Whisper Local setup")
                    .font(VFFont.settingsBody)
                    .foregroundStyle(VFColor.textPrimary)

                HStack(spacing: VFSpacing.sm) {
                    switch whisperRuntimeInstaller.phase {
                    case .notInstalled:
                        profileActionButton(title: "Install runtime", enabled: true) {
                            whisperRuntimeInstaller.installRuntime()
                        }
                        Text("Builds and installs whisper-cli in app-managed runtime storage. Requires Apple Command Line Tools (xcode-select) and make on host.")
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.textSecondary)
                    case .installing:
                        profileActionButton(title: "Cancel", enabled: true) {
                            whisperRuntimeInstaller.cancelInstall()
                        }
                        statusText("Installing runtime…", severity: .info)
                    case .ready:
                        installedChip(label: "Runtime Ready")
                    case .failed(let message):
                        statusText(sanitizedStatusMessage(message, fallback: "Couldn’t install runtime. Install required tools, then try again."), severity: runtimeFailureSeverity(for: message))
                    }
                }

                HStack(spacing: VFSpacing.sm) {
                    Menu {
                        ForEach(WhisperModelTier.allCases) { tier in
                            Button("\(tier.displayName) · \(tier.qualityBand) · \(tier.approxSizeLabel)") {
                                whisperInstaller.setTier(tier)
                            }
                        }
                    } label: {
                        Text("\(whisperInstaller.selectedTier.displayName) · \(whisperInstaller.selectedTier.qualityBand)")
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.textPrimary)
                            .padding(.horizontal, VFSpacing.md)
                            .padding(.vertical, VFSpacing.sm)
                            .background(Capsule().fill(VFColor.glass3))
                    }
                    .menuStyle(.borderlessButton)

                    switch whisperInstaller.phase {
                    case .notInstalled:
                        profileActionButton(title: "Download model", enabled: true) {
                            whisperInstaller.downloadSelectedModel()
                        }
                    case .downloading(_, let progress):
                        profileActionButton(title: "Cancel", enabled: true) {
                            whisperInstaller.cancel()
                        }
                        Text("\(Int(progress * 100))%")
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.textSecondary)
                    case .ready:
                        installedChip(label: "Model Ready")
                    case .failed(let message):
                        statusText(sanitizedStatusMessage(message, fallback: "Couldn’t download the model. Please retry."), severity: .error)
                    }
                }
            }
        }
    }

    private func presetCard(_ preset: SmartModelPreset) -> some View {
        let diagnostics = STTProviderResolver.diagnostics(for: preset.provider)
        let isActive = activePreset == preset

        return VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: VFSpacing.xxs) {
                    Text(preset.title)
                        .font(VFFont.settingsBody)
                        .foregroundStyle(VFColor.textPrimary)
                    Text(preset.subtitle)
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)
                }
                Spacer()
                Circle()
                    .fill(isActive ? VFColor.accentFallback : VFColor.controlInset)
                    .frame(width: 10, height: 10)
            }

            HStack(spacing: VFSpacing.sm) {
                if isActive {
                    installedChip(label: "Selected", color: VFColor.accentFallback)
                } else {
                    profileActionButton(title: "Use", isPrimary: true, enabled: true) {
                        applyPreset(preset)
                    }
                }
                setupActionButton(for: preset)
            }

            if diagnostics.usesFallback, let reason = diagnostics.fallbackReason {
                statusText(
                    friendlyFallbackMessage(reason),
                    severity: fallbackSeverity(for: reason)
                )
            }
        }
        .padding(VFSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.button, style: .continuous)
                .fill(isActive ? VFColor.glass3 : VFColor.glass1)
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.button)
                        .stroke(isActive ? VFColor.accentFallback.opacity(0.6) : VFColor.glassBorder, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func setupActionButton(for preset: SmartModelPreset) -> some View {
        switch preset {
        case .balanced:
            if !ModelVariant.parakeetCTC06B.isDownloaded {
                profileActionButton(title: "Download", enabled: ModelVariant.parakeetCTC06B.hasDownloadSource) {
                    downloadParakeetProfile()
                }
            } else {
                installedChip(label: "Installed")
            }
        case .light:
            if !whisperRuntimeIsReady {
                profileActionButton(title: "Install runtime", enabled: true) {
                    whisperRuntimeInstaller.installRuntime()
                }
            } else if !whisperModelInstalled([.tinyEn, .baseEn]) {
                profileActionButton(title: "Download", enabled: true) {
                    whisperInstaller.setTier(.baseEn)
                    whisperInstaller.downloadSelectedModel()
                }
            } else {
                installedChip(label: "Installed")
            }
        case .best:
            if !whisperRuntimeIsReady {
                profileActionButton(title: "Install runtime", enabled: true) {
                    whisperRuntimeInstaller.installRuntime()
                }
            } else if !whisperModelInstalled([.largeV3Turbo]) {
                profileActionButton(title: "Download", enabled: true) {
                    downloadWhisperLargeProfile()
                }
            } else {
                installedChip(label: "Installed")
            }
        case .cloud:
            profileActionButton(title: "API Key", enabled: true) {
                selectProvider(.openaiAPI)
            }
        }
    }

    private func applyPreset(_ preset: SmartModelPreset) {
        switch preset {
        case .light:
            whisperInstaller.setTier(whisperModelInstalled([.tinyEn]) ? .tinyEn : .baseEn)
            selectProvider(.whisper)
            whisperInstaller.refreshState()
        case .balanced:
            _ = ParakeetModelSourceConfigurationStore.shared.selectSource(
                id: "hf_parakeet_tdt06b_v3_onnx",
                for: ModelVariant.parakeetCTC06B.id
            )
            selectProvider(.parakeet)
            syncDownloadState(for: .parakeet)
            downloadState.reset()
        case .best:
            whisperInstaller.setTier(.largeV3Turbo)
            selectProvider(.whisper)
            whisperInstaller.refreshState()
        case .cloud:
            selectProvider(.openaiAPI)
        }
    }

    private func downloadParakeetProfile() {
        _ = ParakeetModelSourceConfigurationStore.shared.selectSource(
            id: "hf_parakeet_tdt06b_v3_onnx",
            for: ModelVariant.parakeetCTC06B.id
        )
        selectProvider(.parakeet)
        syncDownloadState(for: .parakeet)
        downloadState.reset()
        ModelDownloaderService.shared.download(variant: .parakeetCTC06B, state: downloadState)
    }

    private func downloadWhisperLargeProfile() {
        whisperInstaller.setTier(.largeV3Turbo)
        selectProvider(.whisper)
        whisperInstaller.downloadSelectedModel()
    }

    private var whisperRuntimeIsReady: Bool {
        if case .ready = whisperRuntimeInstaller.phase { return true }
        return false
    }

    private func whisperModelInstalled(_ tiers: [WhisperModelTier]) -> Bool {
        tiers.contains { tier in
            let path = whisperInstaller.localModelURL(for: tier).path
            guard FileManager.default.fileExists(atPath: path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int64 else {
                return false
            }
            return size > 10_000_000
        }
    }

    private var activePreset: SmartModelPreset {
        switch selectedKind {
        case .openaiAPI:
            return .cloud
        case .parakeet:
            return .balanced
        case .whisper:
            return whisperInstaller.selectedTier == .largeV3Turbo ? .best : .light
        case .appleSpeech, .stub:
            return .light
        }
    }

    @ViewBuilder
    private func statusText(_ message: String, severity: ProviderMessageSeverity) -> some View {
        Text(message)
            .font(VFFont.settingsCaption)
            .foregroundStyle(severity.color)
    }

    private func fallbackSeverity(for reason: String) -> ProviderMessageSeverity {
        let normalized = reason.lowercased()
        if normalized.contains("failed") || normalized.contains("error") {
            return .error
        }
        return .warning
    }

    private func runtimeFailureSeverity(for message: String) -> ProviderMessageSeverity {
        let normalized = message.lowercased()
        if normalized.contains("xcode-select") || normalized.contains("command line tools") || normalized.contains("make") {
            return .warning
        }
        return .error
    }

    private func friendlyFallbackMessage(_ reason: String) -> String {
        let normalized = reason.lowercased()
        if normalized.contains("api key") {
            return "Setup needed: add your OpenAI API key to use Cloud mode."
        }
        if normalized.contains("disabled") {
            return "Setup needed: enable cloud fallback to use Cloud mode."
        }
        if normalized.contains("model") && normalized.contains("not ready") {
            return "Setup needed: download the model to finish setup."
        }
        if normalized.contains("runtime") && normalized.contains("not integrated") {
            return "Balanced mode is still experimental in this build; Apple Speech will be used for now."
        }
        if normalized.contains("runtime bootstrap failed") {
            return "Setup needed: repair the local runtime, then try again."
        }
        return "Setup needed before this provider can run."
    }

    private func sanitizedStatusMessage(_ message: String, fallback: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }

        let lower = trimmed.lowercased()
        if lower.contains("http") || lower.contains("nsurl") || lower.contains("domain=") || lower.contains("code=") || lower.contains("exit ") {
            return fallback
        }

        let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
        return firstLine.count > 140 ? fallback : firstLine
    }

    private func profileActionButton(
        title: String,
        isPrimary: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(isPrimary ? VFColor.textOnAccent : VFColor.textPrimary)
                .padding(.horizontal, VFSpacing.sm)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isPrimary ? VFColor.accentFallback : VFColor.glass3)
                        .overlay(Capsule().stroke(VFColor.glassBorder, lineWidth: 0.7))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func installedChip(label: String, color: Color = VFColor.success) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, VFSpacing.sm)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(color.opacity(0.14))
                    .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 0.7))
            )
    }

    private func selectProvider(_ kind: STTProviderKind) {
        selectedKind = kind
        kind.saveSelection()
        syncDownloadState(for: kind)
        NotificationCenter.default.post(name: .sttProviderDidChange, object: nil)
    }

    private func syncDownloadState(for kind: STTProviderKind) {
        if let variant = kind.defaultVariant {
            downloadState.rebind(to: variant)
        }
    }
}

private struct ProviderDiagnosticsView: View {
    let diagnostics: ProviderRuntimeDiagnostics
    let selectedKind: STTProviderKind
    @State private var runtimeBootstrapStatus = ParakeetRuntimeBootstrapManager.shared.statusSnapshot()

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack(spacing: VFSpacing.sm) {
                Circle()
                    .fill(healthColor)
                    .frame(width: 8, height: 8)
                Text("Runtime Diagnostics")
                    .font(VFFont.settingsBody)
                    .foregroundStyle(VFColor.textPrimary)
                Spacer()
                if diagnostics.usesFallback {
                    Text("Fallback")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(VFColor.textPrimary)
                        .padding(.horizontal, VFSpacing.sm)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(VFColor.error.opacity(0.22))
                                .overlay(Capsule().stroke(VFColor.error.opacity(0.45), lineWidth: 0.5))
                        )
                }
                Text(diagnostics.healthLevel.rawValue)
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(healthColor)
            }

            DiagnosticLine(label: "Requested", value: diagnostics.requestedKind.displayName)
            DiagnosticLine(label: "Effective", value: diagnostics.effectiveKind.displayName)

            if selectedKind != diagnostics.requestedKind {
                Text("Refreshing runtime diagnostics for \(selectedKind.displayName)…")
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.textSecondary)
            }

            if let fallbackReason = diagnostics.fallbackReason {
                HStack(alignment: .top, spacing: VFSpacing.xs) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(VFColor.error)
                    Text("Fallback reason: \(fallbackReason)")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.error)
                }
            }

            if shouldShowParakeetRepairAction {
                HStack(spacing: VFSpacing.sm) {
                    Button {
                        ParakeetRuntimeBootstrapManager.shared.repairRuntimeInBackground()
                    } label: {
                        HStack(spacing: VFSpacing.xs) {
                            if runtimeBootstrapStatus.phase == .bootstrapping {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.small)
                                    .tint(VFColor.textPrimary)
                            } else {
                                Image(systemName: "wrench.and.screwdriver.fill")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text(repairButtonLabel)
                                .font(VFFont.pillLabel)
                        }
                        .foregroundStyle(VFColor.textPrimary)
                        .padding(.horizontal, VFSpacing.md)
                        .padding(.vertical, VFSpacing.sm)
                        .background(
                            Capsule()
                                .fill(VFColor.glass3)
                                .shadow(color: VFColor.neuDark, radius: 3, x: 2, y: 2)
                                .shadow(color: VFColor.neuLight, radius: 1, x: -1, y: -1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(runtimeBootstrapStatus.phase == .bootstrapping)

                    Text("One-click repair reinstalls the local Parakeet Python runtime.")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)
                }
            }

            ForEach(diagnostics.checks) { check in
                HStack(alignment: .top, spacing: VFSpacing.xs) {
                    Image(systemName: check.isPassing ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(check.isPassing ? VFColor.success : VFColor.error)
                    VStack(alignment: .leading, spacing: VFSpacing.xxs) {
                        Text(check.title)
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.textPrimary)
                        Text(check.detail)
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.textSecondary)
                    }
                }
            }

            Text("Last updated \(Self.timestampFormatter.string(from: diagnostics.timestamp))")
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textTertiary)
        }
        .onAppear {
            runtimeBootstrapStatus = ParakeetRuntimeBootstrapManager.shared.statusSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .parakeetRuntimeBootstrapDidChange)) { _ in
            runtimeBootstrapStatus = ParakeetRuntimeBootstrapManager.shared.statusSnapshot()
        }
    }

    private var healthColor: Color {
        switch diagnostics.healthLevel {
        case .healthy:
            return VFColor.success
        case .degraded:
            return VFColor.accentFallback
        case .unavailable:
            return VFColor.error
        }
    }

    private var shouldShowParakeetRepairAction: Bool {
        selectedKind == .parakeet || diagnostics.requestedKind == .parakeet || diagnostics.effectiveKind == .parakeet
    }

    private var repairButtonLabel: String {
        switch runtimeBootstrapStatus.phase {
        case .idle, .failed:
            return "Repair Parakeet Runtime"
        case .bootstrapping:
            return "Repairing…"
        case .ready:
            return "Reinstall Runtime"
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
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

private struct ModelDownloadRow: View {
    let kind: STTProviderKind
    @ObservedObject var downloadState: ModelDownloadState
    private let sourceStore = ParakeetModelSourceConfigurationStore.shared

    @State private var selectedSourceID: String
    @State private var customModelURL: String
    @State private var customTokenizerURL: String
    @State private var sourceConfigurationError: String?

    init(kind: STTProviderKind, downloadState: ModelDownloadState) {
        self.kind = kind
        _downloadState = ObservedObject(wrappedValue: downloadState)

        let sourceStore = ParakeetModelSourceConfigurationStore.shared
        let variantID = downloadState.variant.id
        let draft = sourceStore.customSourceDraft(for: variantID)

        _selectedSourceID = State(initialValue: sourceStore.selectedSourceID(for: variantID))
        _customModelURL = State(initialValue: draft.modelURL)
        _customTokenizerURL = State(initialValue: draft.tokenizerURL)
        _sourceConfigurationError = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: VFSpacing.xxs) {
                    Text("Model")
                        .font(VFFont.settingsBody)
                        .foregroundStyle(VFColor.textPrimary)
                    Text(downloadState.variant.displayName)
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)
                }

                Spacer()

                downloadButton
            }

            NeuDivider()

            DiagnosticLine(label: "Status", value: downloadStatusDetail)

            if let sourceError = downloadState.variant.downloadUnavailableReason {
                HStack(alignment: .top, spacing: VFSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 1.0, green: 0.74, blue: 0.34))
                    Text("Setup needed: \(sourceError)")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(Color(red: 1.0, green: 0.74, blue: 0.34))
                }
            }

            // Progress bar
            if case .downloading(let progress) = downloadState.phase {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(VFColor.accentFallback)
                    .padding(.vertical, VFSpacing.xxs)
            }

            // Error message with retry hint
            if case .failed(let message) = downloadState.phase {
                HStack(alignment: .top, spacing: VFSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(VFColor.error)
                    Text(sanitizedDownloadError(message))
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.error)
                }
            }

            // Show validation status when ready
            if case .ready = downloadState.phase {
                Text(downloadState.variant.validationStatus)
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.textTertiary)
            }
        }
        .onAppear {
            refreshSourceStateFromStore()
        }
        .onReceive(NotificationCenter.default.publisher(for: .parakeetModelSourceDidChange)) { _ in
            refreshSourceStateFromStore()
            downloadState.reset()
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        switch downloadState.phase {
        case .notReady:
            downloadActionButton(
                label: "Download",
                icon: "arrow.down.circle.fill",
                isEnabled: downloadState.variant.hasDownloadSource
            )

        case .failed:
            HStack(spacing: VFSpacing.sm) {
                downloadActionButton(
                    label: "Retry",
                    icon: "arrow.clockwise.circle.fill",
                    isEnabled: downloadState.variant.hasDownloadSource
                )

                if hasAlternateSource {
                    Button {
                        switchToAlternateSource()
                    } label: {
                        Text("Try mirror")
                            .font(VFFont.pillLabel)
                            .foregroundStyle(VFColor.textPrimary)
                            .padding(.horizontal, VFSpacing.md)
                            .padding(.vertical, VFSpacing.sm)
                            .background(
                                Capsule()
                                    .fill(VFColor.glass3)
                                    .overlay(
                                        Capsule()
                                            .stroke(VFColor.glassBorder, lineWidth: 0.8)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isDownloading)
                    .opacity(isDownloading ? 0.5 : 1.0)
                }
            }

        case .downloading:
            Button {
                ModelDownloaderService.shared.cancel(
                    variant: downloadState.variant,
                    state: downloadState
                )
            } label: {
                HStack(spacing: VFSpacing.sm) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Cancel")
                        .font(VFFont.pillLabel)
                }
                .foregroundStyle(VFColor.textSecondary)
                .padding(.horizontal, VFSpacing.lg)
                .padding(.vertical, VFSpacing.sm)
                .background(
                    Capsule()
                        .fill(VFColor.glass3)
                        .shadow(color: VFColor.neuDark, radius: 3, x: 2, y: 2)
                        .shadow(color: VFColor.neuLight, radius: 1, x: -1, y: -1)
                )
            }
            .buttonStyle(.plain)

        case .ready:
            HStack(spacing: VFSpacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VFColor.success)
                Text("Ready")
                    .font(VFFont.pillLabel)
                    .foregroundStyle(VFColor.success)
            }
            .padding(.horizontal, VFSpacing.md)
            .padding(.vertical, VFSpacing.sm)
        }
    }

    private func downloadActionButton(label: String, icon: String, isEnabled: Bool) -> some View {
        Button {
            ModelDownloaderService.shared.download(
                variant: downloadState.variant,
                state: downloadState
            )
        } label: {
            HStack(spacing: VFSpacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(VFFont.pillLabel)
            }
            .foregroundStyle(isEnabled ? VFColor.textOnAccent : VFColor.textDisabled)
            .padding(.horizontal, VFSpacing.md)
            .padding(.vertical, VFSpacing.sm)
            .background(
                Capsule()
                    .fill(isEnabled ? VFColor.accentFallback : VFColor.glass3)
                    .overlay(
                        Capsule()
                            .stroke(isEnabled ? VFColor.glassBorder : VFColor.neuInsetLight, lineWidth: 1)
                    )
                    .shadow(
                        color: isEnabled ? VFColor.accentFallback.opacity(0.20) : VFColor.neuDark.opacity(0.35),
                        radius: isEnabled ? 6 : 3,
                        y: isEnabled ? 2 : 1
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var sourcePickerMenu: some View {
        Menu {
            ForEach(sourceOptions) { source in
                Button(source.displayName) {
                    selectSource(source.id)
                }
            }
        } label: {
            HStack(spacing: VFSpacing.sm) {
                Text(selectedSourceDisplayName)
                    .font(VFFont.pillLabel)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(VFColor.textPrimary)
            .padding(.horizontal, VFSpacing.md)
            .padding(.vertical, VFSpacing.sm)
            .background(
                Capsule()
                    .fill(VFColor.glass3)
                    .shadow(color: VFColor.neuDark, radius: 3, x: 2, y: 2)
                    .shadow(color: VFColor.neuLight, radius: 1, x: -1, y: -1)
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(isDownloading)
        .opacity(isDownloading ? 0.5 : 1.0)
    }

    private var customSourceEditor: some View {
        VStack(alignment: .leading, spacing: VFSpacing.xs) {
            Text("Custom source")
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textSecondary)

            TextField("https://example.com/model.onnx", text: $customModelURL)
                .textFieldStyle(.roundedBorder)
                .disabled(isDownloading)

            TextField("https://example.com/vocab.txt (optional)", text: $customTokenizerURL)
                .textFieldStyle(.roundedBorder)
                .disabled(isDownloading)

            HStack {
                Button("Save Custom Source") {
                    saveCustomSource()
                }
                .buttonStyle(.plain)
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textPrimary)
                .padding(.horizontal, VFSpacing.md)
                .padding(.vertical, VFSpacing.xs)
                .background(
                    Capsule()
                        .fill(VFColor.accentFallback)
                        .overlay(
                            Capsule()
                                .stroke(VFColor.glassBorder, lineWidth: 1)
                        )
                )
                .disabled(isDownloading)
                .opacity(isDownloading ? 0.5 : 1.0)

                Text("Model must be .onnx; tokenizer supports .model, .json, or .txt.")
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.textSecondary)
            }
        }
    }

    private var sourceOptions: [ParakeetModelSourceOption] {
        sourceStore.availableSources(for: downloadState.variant.id)
    }

    private var hasAlternateSource: Bool {
        sourceOptions.contains(where: { $0.id != selectedSourceID && $0.modelURL != nil })
    }

    private var selectedSourceDisplayName: String {
        sourceOptions.first(where: { $0.id == selectedSourceID })?.displayName
            ?? downloadState.variant.configuredSourceDisplayName
    }

    private var isDownloading: Bool {
        if case .downloading = downloadState.phase { return true }
        return false
    }

    private var downloadStatusDetail: String {
        switch downloadState.phase {
        case .notReady:
            return "Not downloaded"
        case .downloading(let progress):
            return "Downloading (\(Int(progress * 100))%)"
        case .ready:
            return "Ready - \(downloadState.variant.validationStatus)"
        case .failed:
            return "Download failed"
        }
    }

    private func refreshSourceStateFromStore() {
        selectedSourceID = sourceStore.selectedSourceID(for: downloadState.variant.id)
        let draft = sourceStore.customSourceDraft(for: downloadState.variant.id)
        customModelURL = draft.modelURL
        customTokenizerURL = draft.tokenizerURL
    }

    private func selectSource(_ sourceID: String) {
        let error = sourceStore.selectSource(id: sourceID, for: downloadState.variant.id)
        sourceConfigurationError = error
        refreshSourceStateFromStore()
        downloadState.reset()
    }

    private func switchToAlternateSource() {
        guard let alternate = sourceOptions.first(where: { $0.id != selectedSourceID && $0.modelURL != nil }) else {
            return
        }
        selectSource(alternate.id)
    }

    private func saveCustomSource() {
        let error = sourceStore.saveCustomSource(
            modelURLString: customModelURL,
            tokenizerURLString: customTokenizerURL,
            for: downloadState.variant.id
        )
        sourceConfigurationError = error
        refreshSourceStateFromStore()
        downloadState.reset()
    }

    private func sanitizedDownloadError(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Download failed. Please retry."
        }

        let lower = trimmed.lowercased()
        if lower.contains("http 404") {
            return "Source file was not found (HTTP 404). Try mirror or retry."
        }
        if lower.contains("http") {
            return "Download failed due to a network/server issue. Please retry."
        }
        if lower.contains("timed out") {
            return "Download timed out. Please retry."
        }

        let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
        if firstLine.count > 140 || lower.contains("domain=") || lower.contains("code=") {
            return "Download failed. Please retry."
        }
        return firstLine
    }
}

// MARK: - Transcript History

private struct TranscriptHistoryTab: View {
    @ObservedObject private var store = TranscriptLogStore.shared
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

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            NeuSection(icon: "list.bullet.rectangle.portrait", title: "Transcript Log") {
                VStack(alignment: .leading, spacing: VFSpacing.sm) {
                    HStack(spacing: VFSpacing.sm) {
                        TextField("Search transcripts", text: $query)
                            .textFieldStyle(.roundedBorder)

                        iconActionButton(systemName: "doc.on.doc", accessibilityLabel: "Copy all") {
                            store.copy(filteredEntries.map(\.text).joined(separator: "\n"))
                        }

                        iconActionButton(systemName: "trash", accessibilityLabel: "Clear") {
                            store.clearAll()
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: VFSpacing.sm) {
                            metricChip(title: "Entries", value: "\(store.entries.count)")
                            metricChip(title: "Success", value: "\(successRatePercent)%")
                            metricChip(title: "Avg STT", value: averageLatencyLabel)
                            if !topProviderLabel.isEmpty {
                                metricChip(title: "Top provider", value: topProviderLabel)
                            }
                            if !topAppLabel.isEmpty {
                                metricChip(title: "Top app", value: topAppLabel)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    if filteredEntries.isEmpty {
                        Text("No transcripts yet.")
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.textSecondary)
                            .padding(.vertical, VFSpacing.sm)
                    } else {
                        VStack(spacing: VFSpacing.sm) {
                            ForEach(filteredEntries.prefix(100)) { entry in
                                HStack(alignment: .top, spacing: VFSpacing.md) {
                                    Text(Self.timeFormatter.string(from: entry.timestamp))
                                        .font(VFFont.settingsCaption)
                                        .foregroundStyle(VFColor.textTertiary)
                                        .frame(width: 70, alignment: .leading)

                                    VStack(alignment: .leading, spacing: VFSpacing.xxs) {
                                        Text(entry.provider)
                                            .font(VFFont.settingsCaption)
                                            .foregroundStyle(VFColor.accentFallback)
                                        Text(entry.appName)
                                            .font(.system(size: 10, weight: .regular, design: .rounded))
                                            .foregroundStyle(VFColor.textTertiary)
                                    }
                                    .frame(width: 120, alignment: .leading)

                                    VStack(alignment: .leading, spacing: VFSpacing.xxs) {
                                        Text(entry.text)
                                            .font(VFFont.settingsCaption)
                                            .foregroundStyle(VFColor.textPrimary)
                                            .lineLimit(2)

                                        HStack(spacing: VFSpacing.sm) {
                                            Text(entry.status)
                                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                                .foregroundStyle(VFColor.textSecondary)
                                            if let duration = entry.durationMs {
                                                Text("\(duration)ms")
                                                    .font(.system(size: 10, weight: .regular, design: .rounded))
                                                    .foregroundStyle(VFColor.textTertiary)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    HStack(spacing: VFSpacing.xs) {
                                        iconActionButton(systemName: "arrow.uturn.backward", accessibilityLabel: "Re-insert transcript") {
                                            store.requestReinsert(entry.text)
                                        }
                                        iconActionButton(systemName: "doc.on.doc", accessibilityLabel: "Copy transcript") {
                                            store.copy(entry.text)
                                        }
                                    }
                                }
                                .padding(.vertical, VFSpacing.xs)

                                NeuDivider()
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
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VFColor.glass3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(VFColor.glassBorder, lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(VFColor.textTertiary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(VFColor.textPrimary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, VFSpacing.sm)
        .padding(.vertical, VFSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(VFColor.glass3)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(VFColor.glassBorder, lineWidth: 0.5)
                )
        )
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
                }
            }

            Spacer()

            NeuPillToggle(isOn: $isOn)
        }
    }
}

// MARK: - Neumorphic Pill Toggle

/// iOS-style toggle with neumorphic track: inset when off, raised when on.
private struct NeuPillToggle: View {
    @Binding var isOn: Bool

    private let width: CGFloat = 46
    private let height: CGFloat = 28
    private let knobPad: CGFloat = 3

    var body: some View {
        let knobSize = height - knobPad * 2

        ZStack(alignment: isOn ? .trailing : .leading) {
            // Track
            Capsule()
                .fill(isOn ? VFColor.accentFallback : VFColor.controlTrackOff)
                .overlay(
                    Group {
                        if isOn {
                            Capsule()
                                .stroke(
                                    LinearGradient(
                                        stops: [
                                            .init(color: Color.white.opacity(0.15), location: 0),
                                            .init(color: .clear, location: 0.5),
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        } else {
                            Capsule()
                                .stroke(
                                    LinearGradient(
                                        stops: [
                                            .init(color: VFColor.neuInsetDark, location: 0.0),
                                            .init(color: .clear, location: 0.5),
                                            .init(color: VFColor.neuInsetLight, location: 1.0),
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        }
                    }
                )
                .shadow(color: isOn ? VFColor.accentFallback.opacity(0.25) : .clear, radius: 6)

            // Knob
            Circle()
                .fill(
                    LinearGradient(
                        colors: [VFColor.controlKnobTop, VFColor.controlKnobBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
                .frame(width: knobSize, height: knobSize)
                .padding(knobPad)
        }
        .frame(width: width, height: height)
        .onTapGesture {
            withAnimation(VFAnimation.springSnappy) {
                isOn.toggle()
            }
        }
        .accessibilityAddTraits(.isToggle)
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
