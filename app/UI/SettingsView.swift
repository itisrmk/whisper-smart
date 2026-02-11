import SwiftUI
import Carbon.HIToolbox

/// Root settings view hosted in its own `NSWindow`.
/// Uses a dark glass theme with a custom segmented tab bar
/// and card-based sections.
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──
            Text("Settings")
                .font(VFFont.settingsHeading)
                .foregroundStyle(VFColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, VFSpacing.xl)
                .padding(.top, VFSpacing.xl)
                .padding(.bottom, VFSpacing.lg)

            // ── Segmented tab bar ──
            GlassSegmentedControl(
                selection: $selectedTab,
                items: SettingsTab.allCases
            )
            .padding(.horizontal, VFSpacing.xl)
            .padding(.bottom, VFSpacing.lg)

            // ── Tab content ──
            Group {
                switch selectedTab {
                case .general:  GeneralSettingsTab()
                case .hotkey:   HotkeySettingsTab()
                case .provider: ProviderSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, VFSpacing.xl)
            .padding(.bottom, VFSpacing.xl)
        }
        .frame(width: VFSize.settingsWidth, height: VFSize.settingsHeight)
        .layeredDepthBackground()
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

/// A custom segmented control styled as a glass pill bar with
/// a sliding selection indicator.
private struct GlassSegmentedControl: View {
    @Binding var selection: SettingsTab
    let items: [SettingsTab]

    @Namespace private var segmentNS

    var body: some View {
        HStack(spacing: VFSpacing.xs) {
            ForEach(items) { item in
                let isSelected = (selection == item)
                Button {
                    withAnimation(VFAnimation.springSnappy) {
                        selection = item
                    }
                } label: {
                    HStack(spacing: VFSpacing.xs) {
                        Image(systemName: item.icon)
                            .font(.system(size: 12, weight: .medium))
                        Text(item.label)
                            .font(VFFont.segmentLabel)
                    }
                    .foregroundStyle(isSelected ? VFColor.textPrimary : VFColor.textSecondary)
                    .padding(.horizontal, VFSpacing.md)
                    .padding(.vertical, VFSpacing.sm)
                    .frame(maxWidth: .infinity)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: VFRadius.segment, style: .continuous)
                                .fill(VFColor.glass2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: VFRadius.segment, style: .continuous)
                                        .stroke(VFColor.glassBorder, lineWidth: 1)
                                )
                                .matchedGeometryEffect(id: "segment", in: segmentNS)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(VFSpacing.xs)
        .glassCard(cornerRadius: VFRadius.pill, fill: VFColor.glass1)
    }
}

// MARK: - Section Container

/// A titled card section for settings content.
private struct GlassSection<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            HStack(spacing: VFSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VFColor.accentFallback)
                Text(title)
                    .font(VFFont.settingsTitle)
                    .foregroundStyle(VFColor.textPrimary)
            }

            content()
        }
        .padding(VFSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showBubble")    private var showBubble = true

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            GlassSection(icon: "slider.horizontal.3", title: "Behavior") {
                GlassToggleRow(
                    title: "Launch at login",
                    subtitle: "Start automatically when you log in",
                    isOn: $launchAtLogin
                )
                Divider().overlay(VFColor.glassBorder)
                GlassToggleRow(
                    title: "Show floating bubble",
                    subtitle: "Overlay indicator on screen",
                    isOn: $showBubble
                )
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
            GlassSection(icon: "command", title: "Global Shortcut") {
                VStack(alignment: .leading, spacing: VFSpacing.md) {
                    // Combined shortcut display / recorder field
                    HStack {
                        Text("Dictation shortcut")
                            .font(VFFont.settingsBody)
                            .foregroundStyle(VFColor.textPrimary)

                        Spacer()

                        // Click the pill to toggle recording
                        Button {
                            if isRecording {
                                cancelRecording()
                            } else {
                                startRecording()
                            }
                        } label: {
                            HStack(spacing: VFSpacing.xs) {
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
                            .frame(minWidth: 100)
                            .background(
                                Capsule()
                                    .fill(isRecording ? VFColor.glass2 : VFColor.glass3)
                                    .overlay(
                                        Capsule()
                                            .stroke(
                                                isRecording ? VFColor.accentFallback.opacity(0.6) : VFColor.glassBorder,
                                                lineWidth: isRecording ? 1.5 : 1
                                            )
                                    )
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

                    Divider().overlay(VFColor.glassBorder)

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
                            HStack(spacing: VFSpacing.xs) {
                                Text(presetDisplayString)
                                    .font(VFFont.pillLabel)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(VFColor.textPrimary)
                            .padding(.horizontal, VFSpacing.md)
                            .padding(.vertical, VFSpacing.sm)
                            .background(
                                Capsule()
                                    .fill(VFColor.glass3)
                                    .overlay(
                                        Capsule()
                                            .stroke(VFColor.glassBorder, lineWidth: 1)
                                    )
                            )
                        }
                        .menuStyle(.borderlessButton)
                        .disabled(isRecording)
                        .opacity(isRecording ? 0.5 : 1.0)
                    }

                    Text("Pick a preset or click the shortcut pill to record a custom combo.")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textTertiary)
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

        // Monitor keyDown for the final key in a combo (or Esc to cancel)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleKeyDown(event)
            return nil // swallow
        }

        // Monitor flagsChanged so the pill shows live modifier state
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

        // Attempt to build a binding from the event
        guard let binding = HotkeyBinding.from(event: event) else {
            // Show validation hint — need at least one modifier
            withAnimation(VFAnimation.fadeFast) {
                validationError = "Add a modifier key (⌘ ⌥ ⌃ ⇧) with that key."
            }
            clearValidationAfterDelay()
            return
        }

        // Valid combo — apply instantly
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
        NotificationCenter.default.post(name: .hotkeyBindingDidChange, object: binding)
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
    @StateObject private var downloadState = ModelDownloadState(variant: .parakeetCTC06B)

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            GlassSection(icon: "cloud.fill", title: "Transcription Provider") {
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
                                    selectedKind = kind
                                    kind.saveSelection()
                                    NotificationCenter.default.post(
                                        name: .sttProviderDidChange, object: nil
                                    )
                                }
                            }
                        } label: {
                            HStack(spacing: VFSpacing.xs) {
                                Text(selectedKind.displayName)
                                    .font(VFFont.pillLabel)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(VFColor.textPrimary)
                            .padding(.horizontal, VFSpacing.md)
                            .padding(.vertical, VFSpacing.sm)
                            .background(
                                Capsule()
                                    .fill(VFColor.glass3)
                                    .overlay(
                                        Capsule()
                                            .stroke(VFColor.glassBorder, lineWidth: 1)
                                    )
                            )
                        }
                        .menuStyle(.borderlessButton)
                    }

                    // Model download section (only for providers that need it)
                    if selectedKind.requiresModelDownload {
                        Divider().overlay(VFColor.glassBorder)
                        ModelDownloadRow(
                            kind: selectedKind,
                            downloadState: downloadState
                        )
                    }

                    Text(providerCaption)
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textTertiary)
                }
            }
        }
    }

    private var providerCaption: String {
        switch selectedKind {
        case .stub:
            return "Stub provider returns a fixed placeholder. Useful for testing the pipeline."
        case .whisper:
            return "On-device transcription via Whisper.cpp. Download a model to get started."
        case .parakeet:
            return "On-device transcription via NVIDIA Parakeet. Download the model for one-click setup."
        case .openaiAPI:
            return "Cloud transcription via OpenAI Whisper API. Requires an API key (coming soon)."
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
            }

            // Error message
            if case .failed(let message) = downloadState.phase {
                Text(message)
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.error)
            }
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        switch downloadState.phase {
        case .notReady, .failed:
            Button {
                ModelDownloaderService.shared.download(
                    variant: downloadState.variant,
                    state: downloadState
                )
            } label: {
                HStack(spacing: VFSpacing.xs) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                    Text("Download")
                        .font(VFFont.pillLabel)
                }
                .foregroundStyle(VFColor.textPrimary)
                .padding(.horizontal, VFSpacing.md)
                .padding(.vertical, VFSpacing.sm)
                .background(
                    Capsule()
                        .fill(VFColor.accentFallback)
                        .overlay(
                            Capsule()
                                .stroke(VFColor.glassBorder, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

        case .downloading:
            Button {
                ModelDownloaderService.shared.cancel(
                    variant: downloadState.variant,
                    state: downloadState
                )
            } label: {
                HStack(spacing: VFSpacing.xs) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                    Text("Cancel")
                        .font(VFFont.pillLabel)
                }
                .foregroundStyle(VFColor.textSecondary)
                .padding(.horizontal, VFSpacing.md)
                .padding(.vertical, VFSpacing.sm)
                .background(
                    Capsule()
                        .fill(VFColor.glass3)
                        .overlay(
                            Capsule()
                                .stroke(VFColor.glassBorder, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

        case .ready:
            HStack(spacing: VFSpacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(VFColor.success)
                Text("Ready")
                    .font(VFFont.pillLabel)
                    .foregroundStyle(VFColor.success)
            }
            .padding(.horizontal, VFSpacing.md)
            .padding(.vertical, VFSpacing.sm)
        }
    }
}

// MARK: - Glass Toggle Row

private struct GlassToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: VFSpacing.xxs) {
                Text(title)
                    .font(VFFont.settingsBody)
                    .foregroundStyle(VFColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textTertiary)
                }
            }

            Spacer()

            GlassPillToggle(isOn: $isOn)
        }
    }
}

// MARK: - Glass Pill Toggle

private struct GlassPillToggle: View {
    @Binding var isOn: Bool

    private let width: CGFloat = 44
    private let height: CGFloat = 26
    private let knobPad: CGFloat = 3

    var body: some View {
        let knobSize = height - knobPad * 2

        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? VFColor.accentFallback : VFColor.glass3)
                .overlay(
                    Capsule()
                        .stroke(VFColor.glassBorder, lineWidth: 1)
                )

            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .frame(width: knobSize, height: knobSize)
                .padding(knobPad)
        }
        .frame(width: width, height: height)
        .onTapGesture {
            withAnimation(VFAnimation.springSnappy) {
                isOn.toggle()
            }
        }
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
