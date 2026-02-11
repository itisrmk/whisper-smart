import SwiftUI

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
        .background(VFColor.glass0)
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
    @State private var selectedPresetIndex: Int = Self.initialPresetIndex()

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            GlassSection(icon: "command", title: "Global Shortcut") {
                VStack(alignment: .leading, spacing: VFSpacing.md) {
                    // Current shortcut display
                    HStack {
                        Text("Dictation shortcut")
                            .font(VFFont.settingsBody)
                            .foregroundStyle(VFColor.textPrimary)

                        Spacer()

                        Text(currentDisplayString)
                            .font(VFFont.pillLabel)
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
                                Text(currentDisplayString)
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

                    Text("Select a shortcut preset. Hold the key (or key combo) to start dictation, release to stop.")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textTertiary)
                }
            }
        }
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
        VStack(spacing: VFSpacing.lg) {
            GlassSection(icon: "cloud.fill", title: "Transcription Provider") {
                ProviderSettingsPlaceholder()
            }
        }
    }
}

/// Placeholder for provider configuration.
struct ProviderSettingsPlaceholder: View {
    @State private var selectedProvider = "Whisper (local)"

    private let providers = [
        "Whisper (local)",
        "OpenAI Whisper API",
        "Deepgram",
        "AssemblyAI",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            HStack {
                Text("Provider")
                    .font(VFFont.settingsBody)
                    .foregroundStyle(VFColor.textPrimary)

                Spacer()

                Menu {
                    ForEach(providers, id: \.self) { p in
                        Button(p) { selectedProvider = p }
                    }
                } label: {
                    HStack(spacing: VFSpacing.xs) {
                        Text(selectedProvider)
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

            Text("Provider-specific settings will appear here once the core transcription layer is connected.")
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textTertiary)
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
