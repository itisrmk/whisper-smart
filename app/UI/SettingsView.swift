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
                Text("Configure Visperflow to your liking")
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
            Group {
                switch selectedTab {
                case .general:  GeneralSettingsTab()
                case .hotkey:   HotkeySettingsTab()
                case .provider: ProviderSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, VFSpacing.xxl)
            .padding(.bottom, VFSpacing.xxl)
        }
        .frame(width: VFSize.settingsWidth, height: VFSize.settingsHeight)
        .layeredDepthBackground()
        .vfForcedDarkTheme()
        .animation(VFAnimation.fadeMedium, value: selectedTab)
    }
}

// MARK: - Tab Enum

private enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, hotkey, provider

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:  return "General"
        case .hotkey:   return "Hotkey"
        case .provider: return "Provider"
        }
    }

    var icon: String {
        switch self {
        case .general:  return "gearshape.fill"
        case .hotkey:   return "command"
        case .provider: return "cloud.fill"
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
        .glassCard()
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
    @AppStorage("showBubble")    private var showBubble = true

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
                NeuToggleRow(
                    title: "Show floating bubble",
                    subtitle: "Overlay indicator on screen",
                    isOn: $showBubble
                )
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
            permSnap = PermissionDiagnostics.snapshot()
        }
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
    @State private var selectedKind: STTProviderKind = STTProviderKind.loadSelection()
    /// Shared download state — rebound to the active variant when the provider changes.
    @StateObject private var downloadState = ModelDownloadState(variant: .parakeetCTC06B)
    @ObservedObject private var diagnosticsStore = ProviderRuntimeDiagnosticsStore.shared

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            NeuSection(icon: "cloud.fill", title: "Transcription Provider") {
                VStack(alignment: .leading, spacing: VFSpacing.md) {
                    // Provider picker
                    HStack {
                        Text("Provider")
                            .font(VFFont.settingsBody)
                            .foregroundStyle(VFColor.textPrimary)

                        Spacer()

                        Menu {
                            ForEach(STTProviderKind.allCases) { kind in
                                Button(kind.displayName) {
                                    selectProvider(kind)
                                }
                            }
                        } label: {
                            HStack(spacing: VFSpacing.sm) {
                                Text(selectedKind.displayName)
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
                    }

                    // Model download section (only for providers that need it)
                    if selectedKind.requiresModelDownload {
                        NeuDivider()
                        ModelDownloadRow(
                            kind: selectedKind,
                            downloadState: downloadState
                        )
                    }

                    Text(providerCaption)
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)
                        .padding(.top, VFSpacing.xxs)

                    NeuDivider()

                    ProviderDiagnosticsView(
                        diagnostics: diagnosticsStore.latest,
                        selectedKind: selectedKind
                    )
                }
            }
        }
        .onAppear {
            // Sync download state to the persisted provider on appear.
            syncDownloadState(for: selectedKind)
        }
    }

    private func selectProvider(_ kind: STTProviderKind) {
        selectedKind = kind
        kind.saveSelection()
        syncDownloadState(for: kind)
        NotificationCenter.default.post(name: .sttProviderDidChange, object: nil)
    }

    /// Rebind the download state to the correct variant for the selected provider.
    private func syncDownloadState(for kind: STTProviderKind) {
        if let variant = kind.defaultVariant {
            downloadState.rebind(to: variant)
        }
    }

    private var providerCaption: String {
        switch selectedKind {
        case .appleSpeech:
            return "Real transcription via Apple Speech framework. Works on-device with no setup required."
        case .parakeet:
            return "Local ONNX inference via NVIDIA Parakeet. Runtime is auto-bootstrapped by the app; use Repair Parakeet Runtime if diagnostics report issues."
        case .whisper:
            return "Experimental — Whisper.cpp integration not yet implemented. Coming in a future release."
        case .openaiAPI:
            return "Experimental — OpenAI Whisper API not yet implemented. Coming in a future release."
        case .stub:
            return "Testing only — does not transcribe. Select Apple Speech for real transcription."
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
                    Text(message)
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
            downloadActionButton(
                label: "Retry",
                icon: "arrow.clockwise.circle.fill",
                isEnabled: downloadState.variant.hasDownloadSource
            )

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
