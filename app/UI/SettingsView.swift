import SwiftUI
import Carbon.HIToolbox
import AppKit

/// Root settings view hosted in its own `NSWindow`.
/// Dark neumorphic design with soft raised cards, inset controls,
/// and an iOS-like rounded aesthetic.
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    @State private var showOnboarding: Bool
    @State private var onboardingPreset: OnboardingPreset = .localPrivate
    @State private var onboardingStep: OnboardingStep = .welcome

    init(initialTabRawValue: String? = nil, forceOnboarding: Bool = false) {
        if let initialTabRawValue,
           let initialTab = SettingsTab(rawValue: initialTabRawValue) {
            _selectedTab = State(initialValue: initialTab)
        } else {
            _selectedTab = State(initialValue: .general)
        }
        _showOnboarding = State(initialValue: forceOnboarding || ProductOnboardingPreferences.shouldPresentOnLaunch)
    }

    var body: some View {
        HStack(spacing: VFSpacing.md) {
            SettingsSidebar(
                selectedTab: $selectedTab,
                onOpenOnboarding: {
                    onboardingStep = .welcome
                    showOnboarding = true
                }
            )
                .frame(width: 220)

            VStack(alignment: .leading, spacing: VFSpacing.md) {
                SettingsPaneHeader(selectedTab: selectedTab)

                ScrollView(.vertical, showsIndicators: false) {
                    selectedTabContent
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.bottom, VFSpacing.xxl)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(VFSpacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [VFColor.surface1.opacity(0.96), VFColor.surface2.opacity(0.88)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous)
                            .stroke(VFColor.glassBorder.opacity(0.9), lineWidth: 1)
                    )
                    .overlay(
                        GrainTexture(opacity: 0.010, cellSize: 2)
                            .clipShape(RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous))
                    )
            )
        }
        .padding(VFSpacing.md)
        .frame(width: VFSize.settingsWidth, height: VFSize.settingsHeight)
        .layeredDepthBackground()
        .clipShape(RoundedRectangle(cornerRadius: VFRadius.window, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VFRadius.window, style: .continuous)
                .stroke(VFColor.glassBorder.opacity(0.9), lineWidth: 1)
        )
        .overlay(alignment: .center) {
            if showOnboarding {
                ProductOnboardingOverlay(
                    step: $onboardingStep,
                    selectedPreset: $onboardingPreset,
                    onClose: {
                        ProductOnboardingPreferences.markCompleted()
                        showOnboarding = false
                    },
                    onApplyPreset: { preset in
                        applyOnboardingPreset(preset)
                    },
                    onOpenProvider: {
                        withAnimation(VFAnimation.springSnappy) {
                            selectedTab = .provider
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(12)
            }
        }
        .vfForcedDarkTheme()
        .animation(VFAnimation.fadeMedium, value: selectedTab)
        .animation(VFAnimation.fadeFast, value: showOnboarding)
        .onReceive(NotificationCenter.default.publisher(for: .productOnboardingRequested)) { _ in
            onboardingStep = .welcome
            showOnboarding = true
        }
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsTab()
        case .hotkey:
            HotkeySettingsTab()
        case .provider:
            ProviderSettingsTab()
        case .history:
            TranscriptHistoryTab()
        }
    }

    private func applyOnboardingPreset(_ preset: OnboardingPreset) {
        let providerKind: STTProviderKind
        switch preset {
        case .localPrivate:
            providerKind = .whisper
        case .balanced:
            providerKind = .parakeet
        case .cloudFast:
            providerKind = .openaiAPI
        }

        providerKind.saveSelection()
        NotificationCenter.default.post(name: .sttProviderDidChange, object: nil)

        withAnimation(VFAnimation.springSnappy) {
            selectedTab = .provider
        }
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

    var subtitle: String {
        switch self {
        case .general: return "Startup, audio, workflow"
        case .hotkey: return "Global shortcut controls"
        case .provider: return "Models and cloud setup"
        case .history: return "Transcript metrics and logs"
        }
    }
}

private enum OnboardingStep: Int {
    case welcome
    case permissions
    case finish
}

private enum OnboardingPreset: String, CaseIterable, Identifiable {
    case localPrivate
    case balanced
    case cloudFast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localPrivate: return "Local Private"
        case .balanced: return "Balanced"
        case .cloudFast: return "Cloud Fast"
        }
    }

    var subtitle: String {
        switch self {
        case .localPrivate: return "Whisper local, no cloud dependency"
        case .balanced: return "Parakeet local model + manual install"
        case .cloudFast: return "OpenAI Whisper API with your key"
        }
    }

    var icon: String {
        switch self {
        case .localPrivate: return "internaldrive.fill"
        case .balanced: return "bird.fill"
        case .cloudFast: return "cloud.bolt.fill"
        }
    }
}

private struct ProductOnboardingOverlay: View {
    @Binding var step: OnboardingStep
    @Binding var selectedPreset: OnboardingPreset
    let onClose: () -> Void
    let onApplyPreset: (OnboardingPreset) -> Void
    let onOpenProvider: () -> Void

    @State private var permissionSnapshot = PermissionDiagnostics.snapshot()

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.48))
                .ignoresSafeArea()
                .onTapGesture {}

            VStack(alignment: .leading, spacing: VFSpacing.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: VFSpacing.xxs) {
                        Text("Welcome to Whisper Smart")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(VFColor.textPrimary)
                        Text("Set your default dictation mode and verify permissions in under a minute.")
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.textSecondary)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(VFColor.textSecondary)
                    }
                    .buttonStyle(GlassIconButtonStyle())
                }

                HStack(spacing: VFSpacing.xs) {
                    onboardingStepChip(label: "1", title: "Mode", isActive: step == .welcome)
                    onboardingStepChip(label: "2", title: "Permissions", isActive: step == .permissions)
                    onboardingStepChip(label: "3", title: "Finish", isActive: step == .finish)
                }

                switch step {
                case .welcome:
                    welcomeContent
                case .permissions:
                    permissionsContent
                case .finish:
                    finishContent
                }

                HStack {
                    if step != .welcome {
                        Button("Back") {
                            withAnimation(VFAnimation.fadeFast) {
                                step = OnboardingStep(rawValue: max(0, step.rawValue - 1)) ?? .welcome
                            }
                        }
                        .buttonStyle(GlassCapsuleButtonStyle(tone: .neutral))
                    }

                    Spacer()

                    switch step {
                    case .welcome:
                        Button("Continue") {
                            withAnimation(VFAnimation.fadeFast) {
                                step = .permissions
                            }
                        }
                        .buttonStyle(GlassCapsuleButtonStyle(tone: .primary))
                    case .permissions:
                        Button("Continue") {
                            withAnimation(VFAnimation.fadeFast) {
                                step = .finish
                            }
                        }
                        .buttonStyle(GlassCapsuleButtonStyle(tone: .primary))
                    case .finish:
                        Button("Apply and Open Provider") {
                            onApplyPreset(selectedPreset)
                            onOpenProvider()
                            onClose()
                        }
                        .buttonStyle(GlassCapsuleButtonStyle(tone: .primary))
                    }
                }
            }
            .padding(VFSpacing.lg)
            .frame(width: 700)
            .background(
                RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [VFColor.surface1.opacity(0.98), VFColor.surface2.opacity(0.95)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous)
                            .stroke(VFColor.glassBorder.opacity(0.95), lineWidth: 1)
                    )
                    .shadow(color: VFShadow.raisedControlColor.opacity(0.35), radius: 20, y: 10)
            )
            .overlay(
                GrainTexture(opacity: 0.012, cellSize: 2)
                    .clipShape(RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous))
            )
        }
        .onAppear {
            permissionSnapshot = PermissionDiagnostics.snapshot()
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            Text("Choose your default mode")
                .font(VFFont.settingsBody)
                .foregroundStyle(VFColor.textPrimary)

            HStack(spacing: VFSpacing.sm) {
                ForEach(OnboardingPreset.allCases) { preset in
                    Button {
                        selectedPreset = preset
                    } label: {
                        VStack(alignment: .leading, spacing: VFSpacing.xs) {
                            HStack {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(VFColor.textPrimary)
                                Spacer()
                                if selectedPreset == preset {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(VFColor.accentFallback)
                                }
                            }
                            Text(preset.title)
                                .font(VFFont.settingsBody)
                                .foregroundStyle(VFColor.textPrimary)
                            Text(preset.subtitle)
                                .font(VFFont.settingsCaption)
                                .foregroundStyle(VFColor.textSecondary)
                                .lineLimit(2)
                        }
                        .padding(VFSpacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(
                                    selectedPreset == preset
                                        ? VFColor.surface3.opacity(0.92)
                                        : VFColor.surface2.opacity(0.70)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(
                                            selectedPreset == preset
                                                ? VFColor.accentFallback.opacity(0.75)
                                                : VFColor.glassBorder.opacity(0.7),
                                            lineWidth: 0.8
                                        )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            Text("Permission readiness")
                .font(VFFont.settingsBody)
                .foregroundStyle(VFColor.textPrimary)

            VStack(spacing: VFSpacing.xs) {
                permissionRow("Accessibility", status: permissionSnapshot.accessibility)
                permissionRow("Microphone", status: permissionSnapshot.microphone)
                permissionRow("Speech Recognition", status: permissionSnapshot.speechRecognition)
            }

            HStack(spacing: VFSpacing.sm) {
                Button("Request Permissions") {
                    PermissionDiagnostics.requestAllInOrder { snap in
                        permissionSnapshot = snap
                    }
                }
                .buttonStyle(GlassCapsuleButtonStyle(tone: .primary))

                Button("Open Privacy Settings") {
                    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(GlassCapsuleButtonStyle(tone: .neutral))
            }
        }
    }

    private var finishContent: some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            Text("You are ready")
                .font(VFFont.settingsBody)
                .foregroundStyle(VFColor.textPrimary)

            VStack(alignment: .leading, spacing: VFSpacing.xs) {
                Text("Selected mode: \(selectedPreset.title)")
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.textPrimary)
                Text("Next: open Provider to install local model/runtime or save your cloud API key.")
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.textSecondary)
                Text("Tip: you can reopen onboarding anytime from the sidebar.")
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.textSecondary)
            }
            .padding(VFSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(VFColor.surface2.opacity(0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(VFColor.glassBorder.opacity(0.75), lineWidth: 0.8)
                    )
            )
        }
    }

    private func onboardingStepChip(label: String, title: String, isActive: Bool) -> some View {
        HStack(spacing: VFSpacing.xs) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(isActive ? VFColor.textPrimary : VFColor.textSecondary)
            Text(title)
                .font(VFFont.settingsCaption)
                .foregroundStyle(isActive ? VFColor.textPrimary : VFColor.textSecondary)
        }
        .padding(.horizontal, VFSpacing.sm)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill((isActive ? VFColor.surface3 : VFColor.surface2).opacity(isActive ? 0.95 : 0.7))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke((isActive ? VFColor.accentFallback : VFColor.glassBorder).opacity(0.75), lineWidth: 0.7)
                )
        )
    }

    private func permissionRow(_ title: String, status: PermissionDiagnostics.Status) -> some View {
        HStack {
            Text(title)
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textPrimary)
            Spacer()
            Text(status.actionHint)
                .font(VFFont.settingsFootnote)
                .foregroundStyle(status.isUsable ? VFColor.success : VFColor.textSecondary)
        }
        .padding(.horizontal, VFSpacing.sm)
        .padding(.vertical, VFSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(VFColor.surface2.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(VFColor.glassBorder.opacity(0.72), lineWidth: 0.7)
                )
        )
    }
}

private struct SettingsSidebar: View {
    @Binding var selectedTab: SettingsTab
    let onOpenOnboarding: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            VStack(alignment: .leading, spacing: VFSpacing.xs) {
                HStack(spacing: VFSpacing.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [VFColor.accentFallback.opacity(0.35), VFColor.surface2],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(VFColor.glassBorder, lineWidth: 1)
                            )
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VFColor.textPrimary)
                    }
                    .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Whisper Smart")
                            .font(VFFont.settingsBody)
                            .foregroundStyle(VFColor.textPrimary)
                        Text("Preferences")
                            .font(VFFont.settingsFootnote)
                            .foregroundStyle(VFColor.textSecondary)
                    }
                }
            }

            NeuDivider()

            VStack(spacing: VFSpacing.xs) {
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

            Button(action: onOpenOnboarding) {
                HStack(spacing: VFSpacing.xs) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Onboarding")
                        .font(VFFont.settingsFootnote)
                }
            }
            .buttonStyle(GlassCapsuleButtonStyle(tone: .neutral))

            HStack(spacing: VFSpacing.xs) {
                Image(systemName: "applelogo")
                    .font(.system(size: 10, weight: .medium))
                Text("macOS native")
                    .font(VFFont.settingsFootnote)
            }
            .foregroundStyle(VFColor.textTertiary)
            .padding(.horizontal, VFSpacing.sm)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(VFColor.surface2.opacity(0.70))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(VFColor.glassBorder.opacity(0.8), lineWidth: 0.7)
                    )
            )
        }
        .padding(VFSpacing.md)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [VFColor.surface1.opacity(0.94), VFColor.bgElevated.opacity(0.94)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous)
                        .stroke(VFColor.glassBorder.opacity(0.9), lineWidth: 1)
                )
        )
    }
}

private struct SidebarNavItem: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: VFSpacing.sm) {
            Image(systemName: tab.icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.label)
                    .font(VFFont.settingsBody)
                    .lineLimit(1)
                Text(tab.subtitle)
                    .font(VFFont.settingsFootnote)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(
            isSelected
                ? VFColor.textPrimary
                : (hovering ? VFColor.textPrimary.opacity(0.92) : VFColor.textSecondary)
        )
        .padding(.horizontal, VFSpacing.sm)
        .padding(.vertical, VFSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isSelected
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [VFColor.surface3.opacity(0.96), VFColor.surface2.opacity(0.96)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        : AnyShapeStyle((hovering ? VFColor.interactiveHover : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isSelected ? VFColor.glassBorder.opacity(0.95) : VFColor.glassBorder.opacity(hovering ? 0.5 : 0),
                            lineWidth: isSelected ? 1 : 0.8
                        )
                )
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(VFColor.textPrimary.opacity(isSelected ? 0.36 : 0))
                .frame(width: 2)
                .padding(.vertical, 8)
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
        VStack(alignment: .leading, spacing: VFSpacing.xs) {
            Text(selectedTab.label)
                .font(VFFont.settingsHeading)
                .foregroundStyle(VFColor.textPrimary)
            Text(selectedTab.subtitle)
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textSecondary)
        }
        .padding(.horizontal, VFSpacing.sm)
        .padding(.top, VFSpacing.sm)
    }
}

private struct SettingsHeroBanner: View {
    let selectedTab: SettingsTab

    var body: some View {
        HStack(alignment: .center, spacing: VFSpacing.lg) {
            VStack(alignment: .leading, spacing: VFSpacing.xs) {
                Text("Settings")
                    .font(VFFont.settingsHeading)
                    .foregroundStyle(VFColor.textPrimary)
                Text("Configure Whisper Smart with local-first defaults and polished cloud fallback.")
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.textSecondary)
                    .lineLimit(2)

                HStack(spacing: VFSpacing.xs) {
                    Text("Current")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(VFColor.textTertiary)
                    Text(selectedTab.label)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(VFColor.accentFallback)
                        .padding(.horizontal, VFSpacing.sm)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(VFColor.accentFallback.opacity(0.16))
                                .overlay(Capsule(style: .continuous).stroke(VFColor.accentFallback.opacity(0.40), lineWidth: 0.6))
                        )
                }
            }

            Spacer(minLength: VFSpacing.md)

            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [VFColor.surface3.opacity(0.95), VFColor.surface2.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(VFColor.glassBorder.opacity(0.9), lineWidth: 1)
                    )

                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [VFColor.textureMeshCool.opacity(0.48), .clear],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 60
                        )
                    )
                    .blendMode(.screen)

                VStack(spacing: 5) {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VFColor.textPrimary)
                    Text("WS")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(VFColor.textSecondary)
                }
            }
            .frame(width: 56, height: 56)
            .shadow(color: VFShadow.raisedControlColor.opacity(0.9), radius: 10, y: 4)
        }
        .padding(VFSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [VFColor.surface1.opacity(0.96), VFColor.surface2.opacity(0.88)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous)
                        .stroke(VFColor.glassBorder, lineWidth: 1)
                )
                .overlay(
                    GrainTexture(opacity: 0.010, cellSize: 2)
                        .clipShape(RoundedRectangle(cornerRadius: VFRadius.card, style: .continuous))
                )
                .shadow(color: VFShadow.cardColor.opacity(0.85), radius: 12, y: 5)
        )
    }
}

// MARK: - Glass Segmented Control

/// A custom segmented control styled as a neumorphic pill bar with
/// a soft sliding selection indicator.
private struct GlassSegmentedControl: View {
    @Binding var selection: SettingsTab
    let items: [SettingsTab]

    @Namespace private var segmentNS
    @State private var hoveredTab: SettingsTab?

    var body: some View {
        HStack(spacing: VFSpacing.xxs) {
            ForEach(items) { item in
                let isSelected = (selection == item)
                let isHovered = hoveredTab == item
                HStack(spacing: VFSpacing.sm) {
                    Image(systemName: item.icon)
                        .font(.system(size: 11, weight: .semibold))
                    Text(item.label)
                        .font(VFFont.segmentLabel)
                }
                .foregroundStyle(isSelected ? VFColor.textPrimary : (isHovered ? VFColor.textPrimary.opacity(0.92) : VFColor.textSecondary))
                .padding(.horizontal, VFSpacing.lg)
                .padding(.vertical, VFSpacing.sm)
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [VFColor.surface3.opacity(0.95), VFColor.surface2.opacity(0.95)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: Color.black.opacity(0.35), radius: 8, y: 3)
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(VFColor.glassBorder, lineWidth: 1)
                            )
                            .matchedGeometryEffect(id: "segment", in: segmentNS)
                    } else if isHovered {
                        Capsule(style: .continuous)
                            .fill(VFColor.interactiveHover)
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(VFColor.glassBorder.opacity(0.45), lineWidth: 0.8)
                            )
                    }
                }
                .contentShape(Capsule(style: .continuous))
                .onTapGesture {
                    withAnimation(VFAnimation.springSnappy) {
                        selection = item
                    }
                }
                .onHover { isHovering in
                    hoveredTab = isHovering ? item : (hoveredTab == item ? nil : hoveredTab)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(VFSpacing.xs)
        .frame(minHeight: 44)
        .background(
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [VFColor.surface1.opacity(0.92), VFColor.bgElevated.opacity(0.96)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(VFColor.glassBorder.opacity(0.9), lineWidth: 1)
                )
                .overlay(
                    GrainTexture(opacity: 0.010, cellSize: 2)
                        .clipShape(Capsule(style: .continuous))
                )
                .shadow(color: Color.black.opacity(0.25), radius: 8, y: 2)
        )
    }
}

// MARK: - Section Container

/// A titled neumorphic card section for settings content.
private struct NeuSection<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: () -> Content
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: VFSpacing.lg) {
            VStack(alignment: .leading, spacing: VFSpacing.sm) {
                HStack(spacing: VFSpacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VFColor.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(VFColor.surface3.opacity(0.88))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(VFColor.glassBorder.opacity(0.8), lineWidth: 1)
                                )
                        )
                    Text(title)
                        .font(VFFont.settingsTitle)
                        .foregroundStyle(VFColor.textPrimary)
                }

                // Subtle accent underline for visual hierarchy
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [VFColor.accentFallback.opacity(0.32), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
            }

            content()
        }
        .padding(VFSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: VFRadius.card, fill: VFColor.surface1)
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(VFColor.textureMeshCool.opacity(0.18))
                .frame(width: 96, height: 96)
                .blur(radius: 26)
                .offset(x: 36, y: -36)
                .allowsHitTesting(false)
        }
        .opacity(revealed ? 1 : 0.0)
        .offset(y: revealed ? 0 : 8)
        .onAppear {
            guard !revealed else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                revealed = true
            }
        }
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
                        .init(color: .clear, location: 0.0),
                        .init(color: VFColor.glassBorder.opacity(0.55), location: 0.22),
                        .init(color: VFColor.accentFallback.opacity(0.16), location: 0.5),
                        .init(color: VFColor.glassBorder.opacity(0.55), location: 0.78),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}

private struct GlassFieldModifier: ViewModifier {
    var cornerRadius: CGFloat = VFRadius.field
    var verticalPadding: CGFloat = VFSpacing.xs

    func body(content: Content) -> some View {
        content
            .font(VFFont.settingsCaption)
            .foregroundStyle(VFColor.textPrimary)
            .padding(.horizontal, VFSpacing.sm)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [VFColor.bgElevated.opacity(0.96), VFColor.surface1.opacity(0.88)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(VFColor.glassBorder.opacity(0.88), lineWidth: 0.9)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.10), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    )
            )
    }
}

private extension View {
    func glassInputField(cornerRadius: CGFloat = VFRadius.field, verticalPadding: CGFloat = VFSpacing.xs) -> some View {
        modifier(GlassFieldModifier(cornerRadius: cornerRadius, verticalPadding: verticalPadding))
    }

    func glassSelectPill() -> some View {
        self
            .font(VFFont.pillLabel)
            .foregroundStyle(VFColor.textPrimary)
            .padding(.horizontal, VFSpacing.md)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [VFColor.surface3, VFColor.surface2],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(VFColor.glassBorder, lineWidth: 0.9)
                    )
            )
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
            .padding(.horizontal, VFSpacing.md)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(fillGradient(pressed: configuration.isPressed))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(borderColor.opacity(configuration.isPressed ? 0.9 : 1.0), lineWidth: 0.9)
                    )
                    .shadow(
                        color: VFShadow.raisedControlColor.opacity(configuration.isPressed ? 0.15 : 0.30),
                        radius: configuration.isPressed ? 2 : VFShadow.raisedControlRadius,
                        y: configuration.isPressed ? 1 : VFShadow.raisedControlY
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(VFAnimation.fadeFast, value: configuration.isPressed)
    }

    private func fillGradient(pressed: Bool) -> LinearGradient {
        switch tone {
        case .primary:
            return LinearGradient(
                colors: pressed
                    ? [VFColor.accentDeep, VFColor.accentHover]
                    : [VFColor.accentFallback, VFColor.accentHover],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .neutral:
            return LinearGradient(
                colors: pressed
                    ? [VFColor.surface2, VFColor.bgElevated]
                    : [VFColor.surface3, VFColor.surface2],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .danger:
            return LinearGradient(
                colors: pressed
                    ? [VFColor.error.opacity(0.85), VFColor.error.opacity(0.75)]
                    : [VFColor.error.opacity(0.95), VFColor.error.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var borderColor: Color {
        switch tone {
        case .primary:
            return Color.white.opacity(0.25)
        case .neutral:
            return VFColor.glassBorder
        case .danger:
            return VFColor.error.opacity(0.55)
        }
    }
}

private struct GlassIconButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: configuration.isPressed
                                ? [VFColor.surface2, VFColor.bgElevated]
                                : [VFColor.surface3, VFColor.surface2],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(VFColor.glassBorder.opacity(0.85), lineWidth: 0.8)
                    )
                    .shadow(
                        color: VFShadow.raisedControlColor.opacity(configuration.isPressed ? 0.12 : 0.28),
                        radius: configuration.isPressed ? 2 : 6,
                        y: configuration.isPressed ? 1 : 2
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(VFAnimation.fadeFast, value: configuration.isPressed)
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
    @State private var defaultWritingStyle = DictationWorkflowSettings.defaultWritingStyle
    @State private var defaultDomainPreset = DictationWorkflowSettings.defaultDomainPreset
    @State private var perAppDefaultsJSON = DictationWorkflowSettings.perAppDefaultsJSON
    @State private var snippetsJSON = DictationWorkflowSettings.snippetsJSON
    @State private var correctionDictionaryJSON = DictationWorkflowSettings.correctionDictionaryJSON
    @State private var customAIInstructions = DictationWorkflowSettings.customAIInstructions
    @State private var developerModeEnabled = DictationWorkflowSettings.developerModeEnabled
    @State private var voiceCommandFormattingEnabled = DictationWorkflowSettings.voiceCommandFormattingEnabled
    @FocusState private var customInstructionsFocused: Bool

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
                        Text(selectedInputDeviceName)
                            .lineLimit(1)
                            .glassSelectPill()
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
                                .glassSelectPill()
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
                        .menuStyle(.borderlessButton)
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
                        .menuStyle(.borderlessButton)
                    }

                    NeuDivider()

                    VStack(alignment: .leading, spacing: VFSpacing.sm) {
                        Text("Custom AI instructions (cloud)")
                            .font(VFFont.settingsBody)
                            .foregroundStyle(VFColor.textPrimary)

                        TextEditor(text: $customAIInstructions)
                            .font(.system(size: 11, design: .rounded))
                            .focused($customInstructionsFocused)
                            .frame(height: 78)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(VFColor.glass2.opacity(0.48))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(
                                                customInstructionsFocused ? VFColor.focusRing : VFColor.glassBorder,
                                                lineWidth: customInstructionsFocused ? 1.6 : 0.6
                                            )
                                    )
                                    .shadow(
                                        color: customInstructionsFocused ? VFColor.focusGlow : .clear,
                                        radius: customInstructionsFocused ? 8 : 0
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
                        }
                        .buttonStyle(GlassCapsuleButtonStyle(tone: .neutral))
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
            defaultWritingStyle = DictationWorkflowSettings.defaultWritingStyle
            defaultDomainPreset = DictationWorkflowSettings.defaultDomainPreset
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
                .frame(width: 14, height: 14)
        }
        .buttonStyle(GlassIconButtonStyle(cornerRadius: 7))
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
            .foregroundStyle(VFColor.textOnAccent)
            .padding(.horizontal, VFSpacing.md)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: configuration.isPressed
                                ? [VFColor.accentDeep, VFColor.accentHover]
                                : [VFColor.accentFallback, VFColor.accentHover],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.24), lineWidth: 0.7))
                    .shadow(
                        color: VFShadow.raisedControlColor.opacity(configuration.isPressed ? 0.16 : 0.34),
                        radius: configuration.isPressed ? 2 : 8,
                        y: configuration.isPressed ? 1 : 3
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
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(VFColor.textOnAccent)
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
                            .frame(minWidth: 110)
                            .animation(VFAnimation.fadeFast, value: isRecording)
                            .animation(VFAnimation.fadeFast, value: liveModifiers)
                        }
                        .buttonStyle(GlassCapsuleButtonStyle(tone: isRecording ? .primary : .neutral))
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
    static let productOnboardingRequested = Notification.Name("productOnboardingRequested")
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
            case .balanced: return "Parakeet TDT 0.6B v3 · local experimental"
            case .best: return "Whisper Large-v3 Turbo · highest local accuracy"
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
    @StateObject private var downloadState = ModelDownloadState.sharedParakeet
    @StateObject private var whisperInstaller = WhisperModelInstaller.shared
    @StateObject private var whisperRuntimeInstaller = WhisperRuntimeInstaller.shared
    @State private var openAIAPIKey = DictationProviderPolicy.openAIAPIKey
    @State private var openAIEndpointProfile = DictationProviderPolicy.openAIEndpointProfile
    @State private var openAIBaseURL = DictationProviderPolicy.openAIBaseURL
    @State private var openAIModel = DictationProviderPolicy.openAIModel
    @State private var openAIAPIKeyStatusMessage: String?
    @State private var openAIAPIKeyStatusSeverity: ProviderMessageSeverity = .info

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
    }

    var body: some View {
        VStack(spacing: VFSpacing.lg) {
            NeuSection(icon: "waveform.and.mic", title: "Smart Model Selection") {
                VStack(alignment: .leading, spacing: VFSpacing.lg) {
                    Text("Choose a one-click STT preset. Parakeet setup is user-initiated from this tab; Whisper local runtime still requires host build tools (Apple Command Line Tools + make).")
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

            // TTS preview section removed.
        }
        .onAppear {
            syncDownloadState(for: selectedKind)
            DictationProviderPolicy.cloudFallbackEnabled = true
            openAIAPIKey = DictationProviderPolicy.openAIAPIKey
            openAIEndpointProfile = DictationProviderPolicy.openAIEndpointProfile
            openAIBaseURL = DictationProviderPolicy.openAIBaseURL
            openAIModel = DictationProviderPolicy.openAIModel
            openAIAPIKeyStatusMessage = nil
            whisperRuntimeInstaller.refreshState()
            whisperInstaller.refreshState()
        }
    }

    @ViewBuilder
    private var providerConfigurationSection: some View {
        if selectedKind == .openaiAPI {
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
                                if profile == .openAIOfficial {
                                    openAIBaseURL = profile.defaultBaseURL
                                    openAIModel = profile.defaultModel
                                    DictationProviderPolicy.openAIBaseURL = openAIBaseURL
                                    DictationProviderPolicy.openAIModel = openAIModel
                                }
                                openAIAPIKeyStatusMessage = nil
                            }
                        }
                    } label: {
                        Text(openAIEndpointProfile.displayName)
                            .glassSelectPill()
                    }
                    .menuStyle(.borderlessButton)
                }

                HStack(spacing: VFSpacing.sm) {
                    VStack(alignment: .leading, spacing: VFSpacing.xs) {
                        Text("Base URL")
                            .font(VFFont.settingsBody)
                            .foregroundStyle(VFColor.textPrimary)
                        TextField(openAIEndpointProfile.defaultBaseURL, text: $openAIBaseURL)
                            .textFieldStyle(.plain)
                            .glassInputField()
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
                            .onSubmit {
                                persistOpenAIEndpointConfiguration()
                            }
                    }
                }

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
                    profileActionButton(title: "Save Endpoint", enabled: true) {
                        persistOpenAIEndpointConfiguration()
                    }
                    profileActionButton(title: "Paste & Save", isPrimary: true, enabled: true) {
                        pasteAndSaveOpenAIAPIKey()
                    }
                    profileActionButton(title: "Save API Key", enabled: true) {
                        persistOpenAIAPIKey()
                    }
                }

                if let status = openAIAPIKeyStatusMessage {
                    statusText(status, severity: openAIAPIKeyStatusSeverity)
                }

                Text("Supports official OpenAI and compatible self-hosted gateways that expose `/v1/audio/transcriptions`.")
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
                            .glassSelectPill()
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
        let presetStatus = presetStatusMessage(for: preset, diagnostics: diagnostics)
        let isActive = activePreset == preset

        return VStack(alignment: .leading, spacing: VFSpacing.md) {
            HStack(alignment: .top, spacing: VFSpacing.md) {
                presetArtwork(for: preset, isActive: isActive)

                VStack(alignment: .leading, spacing: VFSpacing.xxs) {
                    Text(preset.title)
                        .font(VFFont.settingsBody)
                        .foregroundStyle(VFColor.textPrimary)
                    Text(preset.subtitle)
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)
                        .lineLimit(2)
                }
                Spacer()

                ZStack {
                    Circle()
                        .fill(isActive ? VFColor.accentFallback : VFColor.controlInset)
                        .frame(width: 11, height: 11)
                    if isActive {
                        Circle()
                            .stroke(VFColor.focusRing.opacity(0.75), lineWidth: 1.5)
                            .frame(width: 17, height: 17)
                    }
                }
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

            if let presetStatus {
                statusText(presetStatus.message, severity: presetStatus.severity)
            }
        }
        .padding(VFSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.button + 1, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isActive
                            ? [VFColor.surface3.opacity(0.94), VFColor.surface2.opacity(0.92)]
                            : [VFColor.surface1.opacity(0.92), VFColor.surface2.opacity(0.88)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.button + 1)
                        .stroke(isActive ? VFColor.accentFallback.opacity(0.6) : VFColor.glassBorder, lineWidth: 1)
                )
                .overlay(
                    GrainTexture(opacity: 0.008, cellSize: 2)
                        .clipShape(RoundedRectangle(cornerRadius: VFRadius.button + 1, style: .continuous))
                )
                .shadow(color: Color.black.opacity(0.23), radius: 7, y: 2)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: VFRadius.button + 1, style: .continuous)
                .fill((isActive ? VFColor.accentFallback : VFColor.glassBorder).opacity(isActive ? 0.66 : 0.28))
                .frame(width: 2)
                .padding(.vertical, 8)
        }
    }

    private func presetArtwork(for preset: SmartModelPreset, isActive: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            presetTint(for: preset).opacity(0.36),
                            VFColor.surface2.opacity(0.95),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isActive ? presetTint(for: preset).opacity(0.56) : VFColor.glassBorder.opacity(0.75), lineWidth: 0.9)
                )

            VStack(spacing: 3) {
                Image(systemName: presetSymbol(for: preset))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VFColor.textPrimary)
                Text(preset.shortBadge)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(VFColor.textSecondary)
            }
        }
        .frame(width: 38, height: 38)
    }

    private func presetSymbol(for preset: SmartModelPreset) -> String {
        switch preset {
        case .light:
            return "hare.fill"
        case .balanced:
            return "bird.fill"
        case .best:
            return "trophy.fill"
        case .cloud:
            return "icloud.fill"
        }
    }

    private func presetTint(for preset: SmartModelPreset) -> Color {
        switch preset {
        case .light:
            return VFColor.success
        case .balanced:
            return VFColor.accentFallback
        case .best:
            return Color(red: 0.98, green: 0.77, blue: 0.39)
        case .cloud:
            return Color(red: 0.56, green: 0.69, blue: 0.97)
        }
    }

    @ViewBuilder
    private func setupActionButton(for preset: SmartModelPreset) -> some View {
        switch preset {
        case .balanced:
            if !ModelVariant.parakeetCTC06B.isDownloaded {
                switch downloadState.phase {
                case .downloading(let progress):
                    installedChip(label: "Preparing \(Int(progress * 100))%", color: VFColor.accentFallback)
                default:
                    installedChip(label: "Preparing…", color: VFColor.accentFallback)
                }
            } else {
                installedChip(label: "Installed")
            }
        case .light:
            if !whisperModelInstalled([.tinyEn, .baseEn]) {
                profileActionButton(title: "Download", enabled: true) {
                    downloadWhisperLightProfile()
                }
            } else {
                installedChip(label: "Installed")
            }
        case .best:
            if !whisperModelInstalled([.largeV3Turbo]) {
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
            downloadParakeetProfile()
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

    private func downloadWhisperLightProfile() {
        whisperInstaller.setTier(whisperModelInstalled([.tinyEn]) ? .tinyEn : .baseEn)
        selectProvider(.whisper)
        if !whisperRuntimeIsReady {
            whisperRuntimeInstaller.installRuntime()
            return
        }
        whisperInstaller.downloadSelectedModel()
    }

    private func downloadWhisperLargeProfile() {
        whisperInstaller.setTier(.largeV3Turbo)
        selectProvider(.whisper)
        if !whisperRuntimeIsReady {
            whisperRuntimeInstaller.installRuntime()
            return
        }
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

    private struct PresetStatus {
        let message: String
        let severity: ProviderMessageSeverity
    }

    private func presetStatusMessage(for preset: SmartModelPreset, diagnostics: ProviderRuntimeDiagnostics) -> PresetStatus? {
        switch preset {
        case .light:
            if !whisperRuntimeIsReady {
                return PresetStatus(message: "Install Whisper runtime to enable Light.", severity: .warning)
            }
            if !whisperModelInstalled([.tinyEn, .baseEn]) {
                return PresetStatus(message: "Download Tiny or Base model to enable Light.", severity: .warning)
            }
        case .balanced:
            if !ModelVariant.parakeetCTC06B.isDownloaded {
                return PresetStatus(message: "Parakeet is selected, but model/runtime are not installed yet.", severity: .warning)
            }
        case .best:
            if !whisperRuntimeIsReady {
                return PresetStatus(message: "Install Whisper runtime to enable Best.", severity: .warning)
            }
            if !whisperModelInstalled([.largeV3Turbo]) {
                return PresetStatus(message: "Download Large-v3 Turbo model to enable Best.", severity: .warning)
            }
        case .cloud:
            let hasAPIKey = !DictationProviderPolicy.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasAPIKey {
                return PresetStatus(message: "Add API key to enable Cloud.", severity: .warning)
            }
        }

        if diagnostics.usesFallback, let reason = diagnostics.fallbackReason {
            return PresetStatus(message: friendlyFallbackMessage(reason), severity: fallbackSeverity(for: reason))
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
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(severity.color.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(severity.color.opacity(0.32), lineWidth: 0.6)
                )
        )
    }

    private func fallbackSeverity(for reason: String) -> ProviderMessageSeverity {
        let normalized = reason.lowercased()
        if normalized.contains("not ready") || normalized.contains("not configured") || normalized.contains("not found") {
            return .warning
        }
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
        if normalized.contains("endpoint") {
            return "Setup needed: check Cloud endpoint URL/model in Provider settings."
        }
        if normalized.contains("disabled") {
            return "Setup needed: enable cloud fallback to use Cloud mode."
        }
        if normalized.contains("model") && normalized.contains("not ready") {
            return "Setup needed: install the Parakeet model/runtime from Provider settings."
        }
        if normalized.contains("runtime") && normalized.contains("not integrated") {
            return "Balanced currently uses Apple Speech fallback in this build."
        }
        if normalized.contains("runtime bootstrap failed") {
            return "Setup needed: local runtime is not ready. Open Provider and run setup."
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
        }
        .buttonStyle(GlassCapsuleButtonStyle(tone: isPrimary ? .primary : .neutral))
        .focusable(true)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func installedChip(label: String, color: Color = VFColor.success) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
        }
        .padding(.horizontal, VFSpacing.sm)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.13))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(color.opacity(0.42), lineWidth: 0.7)
                )
        )
    }

    private func selectProvider(_ kind: STTProviderKind) {
        selectedKind = kind
        kind.saveSelection()
        syncDownloadState(for: kind)
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
        DictationProviderPolicy.cloudFallbackEnabled = true
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
    @State private var telemetrySnapshot = ParakeetTelemetrySnapshot.empty

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
                        .foregroundStyle(VFColor.error)
                        .padding(.horizontal, VFSpacing.sm)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(VFColor.error.opacity(0.22))
                                .overlay(Capsule(style: .continuous).stroke(VFColor.error.opacity(0.45), lineWidth: 0.5))
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
                    }
                    .buttonStyle(GlassCapsuleButtonStyle(tone: .neutral))
                    .disabled(runtimeBootstrapStatus.phase == .bootstrapping)

                    Text("Runtime setup is in-app. Use this when manual setup or prior provisioning failed.")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)
                }
            }

            if isParakeetContext {
                DiagnosticLine(label: "Runtime retries", value: "\(telemetrySnapshot.runtimeBootstrapRetryCount)")
                DiagnosticLine(label: "Model retries", value: "\(telemetrySnapshot.modelDownloadRetryCount)")
                DiagnosticLine(label: "Transport retries", value: "\(telemetrySnapshot.modelDownloadTransportRetryCount)")
                DiagnosticLine(label: "Top runtime failure", value: topRuntimeFailureLabel)
                DiagnosticLine(label: "Top model failure", value: topModelFailureLabel)
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
            refreshTelemetrySnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .parakeetRuntimeBootstrapDidChange)) { _ in
            runtimeBootstrapStatus = ParakeetRuntimeBootstrapManager.shared.statusSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .parakeetTelemetryDidChange)) { _ in
            refreshTelemetrySnapshot()
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
        isParakeetContext && runtimeBootstrapStatus.phase == .failed
    }

    private var repairButtonLabel: String {
        switch runtimeBootstrapStatus.phase {
        case .idle, .failed:
            return "Retry Runtime Setup"
        case .bootstrapping:
            return "Provisioning…"
        case .ready:
            return "Reinstall Runtime"
        }
    }

    private var isParakeetContext: Bool {
        selectedKind == .parakeet || diagnostics.requestedKind == .parakeet || diagnostics.effectiveKind == .parakeet
    }

    private var topRuntimeFailureLabel: String {
        topFailureLabel(from: telemetrySnapshot.runtimeBootstrapFailureCounts)
    }

    private var topModelFailureLabel: String {
        topFailureLabel(from: telemetrySnapshot.modelDownloadFailureCounts)
    }

    private func topFailureLabel(from bucket: [String: Int]) -> String {
        guard let top = bucket.max(by: { $0.value < $1.value }) else {
            return "None"
        }
        return "\(top.key) (\(top.value))"
    }

    private func refreshTelemetrySnapshot() {
        Task {
            let snapshot = await ParakeetTelemetryStore.shared.snapshotValue()
            await MainActor.run {
                telemetrySnapshot = snapshot
            }
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
            RoundedRectangle(cornerRadius: VFRadius.pill, style: .continuous)
                .fill(statusAccentColor.opacity(0.72))
                .frame(height: 2)

            HStack {
                HStack(spacing: VFSpacing.md) {
                    modelArtwork

                    VStack(alignment: .leading, spacing: VFSpacing.xxs) {
                        Text("Model")
                            .font(VFFont.settingsBody)
                            .foregroundStyle(VFColor.textPrimary)
                        Text(downloadState.variant.displayName)
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.textSecondary)
                    }
                }

                Spacer()

                statusChip
            }

            NeuDivider()

            DiagnosticLine(label: "Status", value: downloadStatusDetail)
            DiagnosticLine(label: "Source", value: downloadState.variant.configuredSourceDisplayName)
            DiagnosticLine(label: "Files", value: "encoder-model.int8.onnx + decoder_joint-model.int8.onnx + config.json + nemo128.onnx + vocab.txt")
            Text("Installation is manual. Click Install when you want to set up Parakeet.")
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textSecondary)

            if let modelCardURL = URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3") {
                Link(destination: modelCardURL) {
                    Label("View model card", systemImage: "photo")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.accentFallback)
                }
                .buttonStyle(.plain)
            }

            // Progress bar
            if case .downloading(let progress) = downloadState.phase {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(VFColor.accentFallback)
                    .padding(.vertical, VFSpacing.xxs)
            }

            if case .failed(let message) = downloadState.phase {
                HStack(alignment: .top, spacing: VFSpacing.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(VFColor.error)
                    Text(sanitizedDownloadError(message))
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.error)
                }

                Button {
                    triggerSetup(forceRuntimeRepair: true)
                } label: {
                    Text("Retry setup")
                        .font(VFFont.pillLabel)
                        .foregroundStyle(VFColor.textPrimary)
                }
                .buttonStyle(GlassCapsuleButtonStyle(tone: .neutral))
            }

            if case .notReady = downloadState.phase {
                Button {
                    triggerSetup()
                } label: {
                    Text("Install Parakeet")
                        .font(VFFont.pillLabel)
                        .foregroundStyle(VFColor.textOnAccent)
                }
                .buttonStyle(GlassCapsuleButtonStyle(tone: .primary))
            }

            // Show validation status when ready
            if case .ready = downloadState.phase {
                Text(downloadState.variant.validationStatus)
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.textTertiary)
            }
        }
        .padding(VFSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: VFRadius.button + 2, style: .continuous)
                .fill(VFColor.surface2.opacity(0.52))
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.button + 2, style: .continuous)
                        .stroke(VFColor.glassBorder.opacity(0.85), lineWidth: 0.8)
                )
        )
    }

    private var modelArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: VFRadius.button, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            VFColor.accentFallback.opacity(0.35),
                            VFColor.controlInset.opacity(0.95)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.button, style: .continuous)
                        .stroke(VFColor.glassBorder, lineWidth: 0.8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VFRadius.button, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [VFColor.textureMeshCool.opacity(0.38), .clear],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: 44
                            )
                        )
                )
                .overlay(
                    GrainTexture(opacity: 0.015, cellSize: 1.8)
                        .clipShape(RoundedRectangle(cornerRadius: VFRadius.button, style: .continuous))
                )

            VStack(spacing: 4) {
                Image(systemName: "bird.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(VFColor.textPrimary)
                Text("TDT v3")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(VFColor.textSecondary)
            }
        }
        .frame(width: 54, height: 54)
        .shadow(color: VFShadow.raisedControlColor.opacity(0.65), radius: 8, y: 2)
    }

    @ViewBuilder
    private var statusChip: some View {
        switch downloadState.phase {
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
            .padding(.vertical, 6)
            .background(statusChipBackground(color: VFColor.success))
        case .downloading(let progress):
            HStack(spacing: VFSpacing.sm) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(VFColor.textPrimary)
                Text("Preparing \(Int(progress * 100))%")
                    .font(VFFont.pillLabel)
                    .foregroundStyle(VFColor.textPrimary)
            }
            .padding(.horizontal, VFSpacing.md)
            .padding(.vertical, 6)
            .background(statusChipBackground(color: VFColor.accentFallback))
        case .failed:
            HStack(spacing: VFSpacing.sm) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VFColor.error)
                Text("Setup failed")
                    .font(VFFont.pillLabel)
                    .foregroundStyle(VFColor.error)
            }
            .padding(.horizontal, VFSpacing.md)
            .padding(.vertical, 6)
            .background(statusChipBackground(color: VFColor.error))
        case .notReady:
            HStack(spacing: VFSpacing.sm) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VFColor.textPrimary)
                Text("Not installed")
                    .font(VFFont.pillLabel)
                    .foregroundStyle(VFColor.textPrimary)
            }
            .padding(.horizontal, VFSpacing.md)
            .padding(.vertical, 6)
            .background(statusChipBackground(color: VFColor.accentFallback))
        }
    }

    private func statusChipBackground(color: Color) -> some View {
        Capsule(style: .continuous)
            .fill(color.opacity(0.14))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(color.opacity(0.42), lineWidth: 0.7)
            )
    }

    private var statusAccentColor: Color {
        switch downloadState.phase {
        case .ready:
            return VFColor.success
        case .failed:
            return VFColor.error
        case .downloading, .notReady:
            return VFColor.accentFallback
        }
    }

    private var downloadStatusDetail: String {
        switch downloadState.phase {
        case .notReady:
            return "Not installed"
        case .downloading(let progress):
            if progress >= 0.99 {
                return "Finalizing model artifacts…"
            }
            return "Downloading (\(Int(progress * 100))%)"
        case .ready:
            return "Ready - \(downloadState.variant.validationStatus)"
        case .failed:
            return "Setup failed. Retry when ready."
        }
    }

    private func triggerSetup(forceRuntimeRepair: Bool = false) {
        guard kind == .parakeet else { return }

        let sourceStore = ParakeetModelSourceConfigurationStore.shared
        if sourceStore.selectedSourceID(for: downloadState.variant.id) != "hf_parakeet_tdt06b_v3_onnx" {
            _ = sourceStore.selectSource(id: "hf_parakeet_tdt06b_v3_onnx", for: downloadState.variant.id)
            downloadState.reset()
        }

        Task {
            await ParakeetProvisioningCoordinator.shared.ensureAutomaticSetupForCurrentSelection(
                forceModelRetry: false,
                forceRuntimeRepair: forceRuntimeRepair,
                reason: "manual_setup_button"
            )
        }

        ModelDownloaderService.shared.download(
            variant: downloadState.variant,
            state: downloadState
        )
    }

    private func sanitizedDownloadError(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Setup is still running. Retry in a few seconds."
        }

        let lower = trimmed.lowercased()
        if lower.contains("decoder joint artifact") || lower.contains("nemo normalizer artifact") || lower.contains("config artifact") {
            return "Finalizing required model files. Press Retry setup in a few seconds."
        }
        if lower.contains("incomplete") {
            return "Model download is incomplete. Retry setup."
        }
        if lower.contains("not connected to internet") || lower.contains("no internet connection") {
            return "No internet connection detected. Retry after reconnecting."
        }
        if lower.contains("http 404") {
            return "Model host returned HTTP 404. Retry setup or switch source."
        }
        if lower.contains("http") {
            return "Network or host error while downloading model. Retry setup."
        }
        if lower.contains("timed out") {
            return "Download timed out. Retry setup."
        }

        let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? trimmed
        if lower.contains("domain=") || lower.contains("code=") {
            return "Setup is still running. Retry in a few seconds."
        }
        if firstLine.count > 160 {
            return String(firstLine.prefix(160)) + "…"
        }
        return firstLine
    }
}

// MARK: - Transcript History

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

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: VFSpacing.sm) {
                            metricChip(title: "Entries", value: "\(store.entries.count)")
                            metricChip(title: "Success", value: "\(successRatePercent)%")
                            metricChip(title: "Avg STT", value: averageLatencyLabel)
                            metricChip(title: "Avg E2E", value: averageEndToEndLabel)
                            metricChip(title: "P95 E2E", value: p95EndToEndLabel)
                            metricChip(title: "Latency SLO", value: sloLabel, tint: sloTint)
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
                                .padding(VFSpacing.sm)
                                .background(
                                    RoundedRectangle(cornerRadius: VFRadius.field, style: .continuous)
                                        .fill(VFColor.surface2.opacity(0.52))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: VFRadius.field, style: .continuous)
                                                .stroke(VFColor.glassBorder.opacity(0.74), lineWidth: 0.7)
                                        )
                                )
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

    private func metricChip(title: String, value: String, tint: Color = VFColor.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(VFColor.textTertiary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, VFSpacing.sm)
        .padding(.vertical, VFSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [VFColor.surface3.opacity(0.95), VFColor.surface2.opacity(0.86)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(VFColor.glassBorder, lineWidth: 0.6)
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

    private var averageEndToEndLabel: String {
        guard let avg = metricsSummary.averageEndToEndMs else { return "—" }
        return "\(avg)ms"
    }

    private var p95EndToEndLabel: String {
        guard let p95 = metricsSummary.p95EndToEndMs else { return "—" }
        return "\(p95)ms"
    }

    private var sloLabel: String {
        guard let p95Pass = metricsSummary.p95MeetsSLO,
              let avgPass = metricsSummary.averageMeetsSLO else {
            return "N/A"
        }
        return (p95Pass && avgPass) ? "On target" : "Needs tuning"
    }

    private var sloTint: Color {
        switch (metricsSummary.averageMeetsSLO, metricsSummary.p95MeetsSLO) {
        case (.some(true), .some(true)):
            return VFColor.success
        case (.some(false), _), (_, .some(false)):
            return VFColor.error
        default:
            return VFColor.textSecondary
        }
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

// MARK: - Neumorphic Pill Toggle

/// iOS-style toggle with neumorphic track: inset when off, raised when on.
private struct NeuPillToggle: View {
    @Binding var isOn: Bool
    let accessibilityLabel: String

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(VFColor.accentFallback)
            .focusable(true)
            .accessibilityLabel(accessibilityLabel)
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
