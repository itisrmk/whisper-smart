import AVFoundation
import AppKit
import Speech
import SwiftUI

// MARK: - Steps

/// Wispr-Flow-style guided first run: one idea per screen, sequential
/// permission cards, a live mic check, and a guaranteed-success practice
/// dictation before the user is released into the wild.
enum OnboardingFlowStep: Int, CaseIterable {
    case welcome
    case permissions
    case engine
    case micCheck
    case hotkey
    case practice
    case finish

    var kicker: String {
        switch self {
        case .welcome:     return "WELCOME"
        case .permissions: return "PERMISSIONS"
        case .engine:      return "ENGINE"
        case .micCheck:    return "MIC CHECK"
        case .hotkey:      return "YOUR SHORTCUT"
        case .practice:    return "TRY IT"
        case .finish:      return "ALL SET"
        }
    }

    var title: String {
        switch self {
        case .welcome:     return "Speak. Don't type."
        case .permissions: return "Two quick permissions"
        case .engine:      return "Pick your transcription engine"
        case .micCheck:    return "Let's hear you"
        case .hotkey:      return "One key starts everything"
        case .practice:    return "Your first dictation"
        case .finish:      return "You're all set"
        }
    }
}

// MARK: - Engine presets

private enum OnboardingEnginePreset: String, CaseIterable, Identifiable {
    case localPrivate
    case balanced
    case cloudFast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localPrivate: return "Local Private"
        case .balanced:     return "Balanced"
        case .cloudFast:    return "Cloud Fast"
        }
    }

    var subtitle: String {
        switch self {
        case .localPrivate: return "Whisper runs fully on your Mac. Nothing leaves it."
        case .balanced:     return "Parakeet MLX — fast, accurate, and still 100% local."
        case .cloudFast:    return "OpenAI Whisper API with your own key."
        }
    }

    var icon: String {
        switch self {
        case .localPrivate: return "internaldrive.fill"
        case .balanced:     return "bird.fill"
        case .cloudFast:    return "cloud.bolt.fill"
        }
    }

    var isRecommended: Bool { self == .balanced }

    var providerKind: STTProviderKind {
        switch self {
        case .localPrivate: return .whisper
        case .balanced:     return .parakeet
        case .cloudFast:    return .openaiAPI
        }
    }
}

// MARK: - Mic level meter

/// Lightweight input-level meter for the mic-check step. Separate from
/// `AudioCaptureService` so onboarding never touches the dictation pipeline.
final class MicLevelMeter: ObservableObject {
    @Published var level: CGFloat = 0
    @Published var didDetectSpeech = false

    private let engine = AVAudioEngine()
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            var sum: Float = 0
            for i in 0..<frames { sum += channel[i] * channel[i] }
            let rms = sqrt(sum / Float(frames))
            let normalized = CGFloat(min(max(rms * 18, 0), 1))
            DispatchQueue.main.async {
                self.level = normalized
                if normalized > 0.14 { self.didDetectSpeech = true }
            }
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        level = 0
    }
}

// MARK: - Root flow view

struct OnboardingFlowView: View {
    @ObservedObject var stateSubject: BubbleStateSubject
    let onPermissionsChanged: () -> Void
    let onFinished: () -> Void

    @State private var step: OnboardingFlowStep = .welcome

    // Permissions
    @State private var permissionSnapshot = PermissionDiagnostics.snapshot()
    @State private var didPromptAccessibility = false

    // Engine
    @State private var selectedPreset: OnboardingEnginePreset = .balanced
    @StateObject private var mlxInstaller = MLXModelInstaller.shared
    /// The MLX model whose install onboarding kicked off, if any. Drives the
    /// compact progress row on the steps after the engine choice.
    @State private var onboardingInstallModel: MLXModel?
    @State private var runtimeBootstrapDetail = ""

    // Mic check
    @StateObject private var micMeter = MicLevelMeter()
    @State private var levelHistory: [CGFloat] = Array(repeating: 0, count: 24)

    // Hotkey
    @State private var hotkeyBinding = HotkeyBinding.load()

    // Practice
    @State private var practiceText = ""
    @State private var practiceCelebrated = false
    @State private var celebrationWasDemo = false
    @State private var demoRunning = false
    @State private var demoStatusLabel = ""
    @FocusState private var practiceFieldFocused: Bool

    private let permissionTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, VFSpacing.xxxl)
                .padding(.top, VFSpacing.xxxl)

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, VFSpacing.xxxl)
                .padding(.top, VFSpacing.lg)

            modelInstallStatusRow
                .padding(.horizontal, VFSpacing.xxxl)
                .padding(.bottom, VFSpacing.sm)

            footer
                .padding(.horizontal, VFSpacing.xxxl)
                .padding(.bottom, VFSpacing.xl)
        }
        .frame(width: 760, height: 620)
        .background(VFColor.bg)
        .onReceive(permissionTimer) { _ in
            guard step == .permissions else { return }
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mlxRuntimeBootstrapDidChange)) { _ in
            let snapshot = MLXRuntimeBootstrapManager.shared.statusSnapshot()
            runtimeBootstrapDetail = snapshot.phase == .bootstrapping ? snapshot.detail : ""
        }
        .animation(VFAnimation.fadeMedium, value: step)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: VFSpacing.sm) {
            HStack(spacing: 3) {
                ForEach(OnboardingFlowStep.allCases, id: \.rawValue) { s in
                    Rectangle()
                        .fill(s.rawValue <= step.rawValue ? VFColor.accent : VFColor.panel2)
                        .frame(height: 3)
                }
            }

            Text("STEP \(step.rawValue + 1) OF \(OnboardingFlowStep.allCases.count) — \(step.kicker)")
                .font(VFFont.kicker)
                .kerning(1.2)
                .foregroundStyle(VFColor.muted)
                .padding(.top, VFSpacing.xs)

            Text(step.title)
                .font(VFFont.settingsHeading)
                .foregroundStyle(VFColor.text)

            Rectangle()
                .fill(VFColor.rule)
                .frame(width: 44, height: 2)
        }
    }

    // MARK: Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:     welcomeStep
        case .permissions: permissionsStep
        case .engine:      engineStep
        case .micCheck:    micCheckStep
        case .hotkey:      hotkeyStep
        case .practice:    practiceStep
        case .finish:      finishStep
        }
    }

    // MARK: Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: VFSpacing.lg) {
            Text("Hold a key, talk, release — your words land wherever your cursor is. Any app, three times faster than typing.")
                .font(VFFont.settingsBody)
                .foregroundStyle(VFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: VFSpacing.sm) {
                finishBullet(icon: "keyboard.fill", text: "Hold your dictation key from any app — Slack, email, docs, code.")
                finishBullet(icon: "waveform", text: "Speak naturally. Messy phrasing is fine; it comes out clean.")
                finishBullet(icon: "text.cursor", text: "Release, and the text lands right where your cursor is.")
            }
            .padding(VFSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Rectangle()
                    .fill(VFColor.panel)
                    .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
            )

            Text("Setup takes about two minutes.")
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.muted)
        }
    }

    // MARK: Permissions

    private var permissionsStep: some View {
        let micGranted = permissionSnapshot.microphone.isUsable
        let axGranted = permissionSnapshot.accessibility.isUsable

        return VStack(alignment: .leading, spacing: VFSpacing.md) {
            Text("Whisper Smart needs macOS's blessing to hear you and to type for you. Grant one to reveal the next.")
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionCard(
                icon: "mic.fill",
                title: "Microphone",
                why: "So Whisper Smart can hear you while you dictate.",
                granted: micGranted,
                revealed: true,
                buttonLabel: permissionSnapshot.microphone == .notAsked ? "Allow Microphone" : "Open System Settings",
                action: {
                    if permissionSnapshot.microphone == .notAsked {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            DispatchQueue.main.async { refreshPermissions() }
                        }
                    } else {
                        openPrivacyPane("Privacy_Microphone")
                    }
                }
            )

            permissionCard(
                icon: "accessibility",
                title: "Accessibility",
                why: "So Whisper Smart can place your words into other apps at the cursor.",
                granted: axGranted,
                revealed: micGranted,
                buttonLabel: didPromptAccessibility ? "Open System Settings" : "Allow Accessibility",
                action: {
                    if didPromptAccessibility {
                        openPrivacyPane("Privacy_Accessibility")
                    } else {
                        didPromptAccessibility = true
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(options)
                    }
                }
            )

            permissionCard(
                icon: "waveform.badge.mic",
                title: "Speech Recognition",
                why: "Powers the built-in Apple engine — your instant fallback while a local model installs.",
                granted: permissionSnapshot.speechRecognition.isUsable,
                revealed: micGranted && axGranted,
                buttonLabel: permissionSnapshot.speechRecognition == .notAsked ? "Allow Speech" : "Open System Settings",
                action: {
                    if permissionSnapshot.speechRecognition == .notAsked {
                        SFSpeechRecognizer.requestAuthorization { _ in
                            DispatchQueue.main.async { refreshPermissions() }
                        }
                    } else {
                        openPrivacyPane("Privacy_SpeechRecognition")
                    }
                }
            )

            if micGranted && !axGranted {
                Text("Granted it in System Settings? Come back here — we detect it automatically.")
                    .font(VFFont.settingsFootnote)
                    .foregroundStyle(VFColor.muted)
            }
            if micGranted && axGranted {
                Text("You're good to go — Speech Recognition is optional but recommended.")
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.success)
            }
        }
    }

    private func permissionCard(
        icon: String,
        title: String,
        why: String,
        granted: Bool,
        revealed: Bool,
        buttonLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: VFSpacing.md) {
            Image(systemName: revealed ? icon : "lock.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(granted ? VFColor.success : (revealed ? VFColor.accent : VFColor.muted))
                .frame(width: 36, height: 36)
                .background(Rectangle().fill(VFColor.panel2))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(VFFont.settingsBody)
                    .foregroundStyle(VFColor.text)
                Text(revealed ? why : "Unlocks after the previous permission.")
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if granted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Granted")
                }
                .font(VFFont.pillLabel)
                .foregroundStyle(VFColor.success)
            } else if revealed {
                Button(buttonLabel, action: action)
                    .buttonStyle(OnboardingCapsuleButtonStyle(tone: .primary))
            }
        }
        .padding(VFSpacing.md)
        .background(
            Rectangle()
                .fill(VFColor.panel)
                .overlay(Rectangle().stroke(granted ? VFColor.success.opacity(0.5) : VFColor.border, lineWidth: 1))
        )
        .opacity(revealed ? 1 : 0.5)
    }

    // MARK: Engine

    private var engineStep: some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            Text("Where should transcription run? You can change this anytime in Settings → Provider.")
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textSecondary)

            HStack(spacing: VFSpacing.sm) {
                ForEach(OnboardingEnginePreset.allCases) { preset in
                    Button {
                        selectEnginePreset(preset)
                    } label: {
                        VStack(alignment: .leading, spacing: VFSpacing.xs) {
                            HStack {
                                Image(systemName: preset.icon)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(VFColor.accent)
                                Spacer()
                                if selectedPreset == preset {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(VFColor.accent)
                                }
                            }
                            Text(preset.title)
                                .font(VFFont.settingsBody)
                                .foregroundStyle(VFColor.text)
                            Text(preset.subtitle)
                                .font(VFFont.settingsCaption)
                                .foregroundStyle(VFColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            if preset.isRecommended {
                                Text("RECOMMENDED")
                                    .font(VFFont.kicker)
                                    .kerning(1)
                                    .foregroundStyle(VFColor.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Rectangle().fill(VFColor.accentSoft))
                            }
                        }
                        .padding(VFSpacing.md)
                        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
                        .background(
                            Rectangle()
                                .fill(selectedPreset == preset ? VFColor.active : VFColor.panel)
                                .overlay(
                                    Rectangle().stroke(
                                        selectedPreset == preset ? VFColor.accent : VFColor.border,
                                        lineWidth: selectedPreset == preset ? 1.5 : 1
                                    )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(engineFootnote)
                .font(VFFont.settingsFootnote)
                .foregroundStyle(VFColor.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let model = selectedLocalModel, !mlxInstaller.isInstalled(model) {
                engineDownloadStatus(for: model)
            }
        }
        .onAppear {
            // Start (or resume) the local model download as soon as the user
            // lands on this step so the progress bar reflects real state and
            // Continue can gate on completion.
            beginModelInstallIfNeeded()
        }
    }

    /// The local MLX model backing the currently selected preset, or nil for
    /// the cloud engine (which has no local download to gate on).
    private var selectedLocalModel: MLXModel? {
        MLXModelCatalog.selectedModel(for: selectedPreset.providerKind)
    }

    /// Inline progress panel on the engine step. A real progress bar while the
    /// model downloads, a graceful fallback note if it fails, so the user never
    /// advances into the practice step with a half-installed model.
    @ViewBuilder
    private func engineDownloadStatus(for model: MLXModel) -> some View {
        switch mlxInstaller.phase {
        case .installing(let modelID, let detail) where modelID == model.id:
            let hasProgress = mlxInstaller.installProgress > 0
            VStack(alignment: .leading, spacing: VFSpacing.xs) {
                HStack(spacing: VFSpacing.xs) {
                    if hasProgress {
                        Text("Downloading \(model.displayName)")
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.text)
                        Spacer(minLength: 0)
                        Text("\(Int((mlxInstaller.installProgress * 100).rounded()))%")
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.accent)
                            .monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                        Text(runtimeBootstrapDetail.isEmpty ? detail : runtimeBootstrapDetail)
                            .font(VFFont.settingsCaption)
                            .foregroundStyle(VFColor.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                if hasProgress {
                    ProgressView(value: mlxInstaller.installProgress)
                        .tint(VFColor.accent)
                }
                Text("Hang tight — this finishes before your first dictation so the test won't error out.")
                    .font(VFFont.settingsFootnote)
                    .foregroundStyle(VFColor.muted)
            }
            .padding(VFSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Rectangle()
                    .fill(VFColor.panel)
                    .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
            )
        case .failed(let modelID, _) where modelID == model.id:
            HStack(alignment: .firstTextBaseline, spacing: VFSpacing.xs) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VFColor.muted)
                Text("The \(model.displayName) download hit a snag. You can continue — Whisper Smart uses Apple's built-in engine until you retry it from Settings → Provider.")
                    .font(VFFont.settingsFootnote)
                    .foregroundStyle(VFColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(VFSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Rectangle()
                    .fill(VFColor.panel)
                    .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
            )
        default:
            HStack(spacing: VFSpacing.xs) {
                ProgressView().controlSize(.small)
                Text("Preparing download…")
                    .font(VFFont.settingsCaption)
                    .foregroundStyle(VFColor.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var engineFootnote: String {
        guard let model = MLXModelCatalog.selectedModel(for: selectedPreset.providerKind) else {
            return "The cloud engine needs your OpenAI API key — add it in Settings → Provider."
        }
        if mlxInstaller.isInstalled(model) {
            return "\(model.displayName) is already installed on this Mac — you're ready to go."
        }
        if case .installing(let modelID, _) = mlxInstaller.phase, modelID == model.id {
            return "Downloading \(model.displayName) (\(model.approxSizeLabel)) now — you can keep going while it installs."
        }
        return "\(model.displayName) (\(model.approxSizeLabel)) downloads in the background — you can keep going while it installs."
    }

    // MARK: Mic check

    private var micCheckStep: some View {
        VStack(alignment: .leading, spacing: VFSpacing.lg) {
            Text("Say something out loud — the bars should stay low when you're silent and jump when you speak.")
                .font(VFFont.settingsBody)
                .foregroundStyle(VFColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 4) {
                ForEach(levelHistory.indices, id: \.self) { i in
                    Rectangle()
                        .fill(levelHistory[i] > 0.14 ? VFColor.accent : VFColor.muted.opacity(0.5))
                        .frame(width: 8, height: max(6, levelHistory[i] * 120))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .center)
            .padding(VFSpacing.lg)
            .background(
                Rectangle()
                    .fill(VFColor.panel)
                    .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
            )
            .onAppear { micMeter.start() }
            .onDisappear { micMeter.stop() }
            .onReceive(micMeter.$level) { newLevel in
                levelHistory.removeFirst()
                levelHistory.append(newLevel)
            }

            if micMeter.didDetectSpeech {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Mic sounds great!")
                }
                .font(VFFont.settingsBody)
                .foregroundStyle(VFColor.success)
            } else {
                Text("Nothing moving? Check your input device in System Settings → Sound.")
                    .font(VFFont.settingsFootnote)
                    .foregroundStyle(VFColor.muted)
            }
        }
    }

    // MARK: Hotkey

    private var hotkeyStep: some View {
        VStack(alignment: .leading, spacing: VFSpacing.lg) {
            Text("Hold it to talk, release to finish. Works from any app, anywhere on your Mac.")
                .font(VFFont.settingsBody)
                .foregroundStyle(VFColor.textSecondary)

            HStack {
                Spacer()
                OnboardingKeycap(label: keycapLabel(for: hotkeyBinding), pulsing: true)
                Spacer()
            }
            .padding(.vertical, VFSpacing.md)

            Text("Or pick a different one:")
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textPrimary)

            HStack(spacing: VFSpacing.xs) {
                ForEach(HotkeyBinding.presets, id: \.displayString) { preset in
                    let isSelected = preset == hotkeyBinding
                    Button {
                        applyHotkey(preset)
                    } label: {
                        Text(preset.displayString)
                            .font(VFFont.pillLabel)
                            .foregroundStyle(isSelected ? Color.white : VFColor.text)
                            .padding(.horizontal, VFSpacing.sm)
                            .padding(.vertical, 8)
                            .background(
                                Rectangle()
                                    .fill(isSelected ? VFColor.accent : VFColor.panel2)
                                    .overlay(Rectangle().stroke(isSelected ? VFColor.accent : VFColor.border, lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Want a fully custom combo? Settings → Hotkey has a recorder.")
                .font(VFFont.settingsFootnote)
                .foregroundStyle(VFColor.muted)
        }
    }

    // MARK: Practice

    private var practiceStep: some View {
        VStack(alignment: .leading, spacing: VFSpacing.md) {
            VStack(alignment: .leading, spacing: VFSpacing.xs) {
                practiceInstruction(number: "1", text: "Click into the box below so your cursor is there.")
                practiceInstruction(number: "2", text: "Hold \(keycapLabel(for: hotkeyBinding)) and say: \u{201C}Hello! This is me typing with my voice.\u{201D}")
                practiceInstruction(number: "3", text: "Release the key. Your words appear at the cursor.")
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $practiceText)
                    .font(VFFont.settingsBody)
                    .foregroundStyle(VFColor.text)
                    .scrollContentBackground(.hidden)
                    .padding(VFSpacing.sm)
                    .frame(height: 120)
                    .background(
                        Rectangle()
                            .fill(VFColor.panel)
                            .overlay(
                                Rectangle().stroke(
                                    practiceFieldFocused ? VFColor.accent : VFColor.border2,
                                    lineWidth: practiceFieldFocused ? 1.5 : 1
                                )
                            )
                    )
                    .focused($practiceFieldFocused)

                if practiceText.isEmpty {
                    Text("Your dictation lands here…")
                        .font(VFFont.settingsBody)
                        .foregroundStyle(VFColor.muted)
                        .padding(.top, VFSpacing.sm + 8)
                        .padding(.leading, VFSpacing.sm + 5)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    practiceFieldFocused = true
                }
            }
            .onChange(of: practiceText) { _, newValue in
                if !practiceCelebrated, !demoRunning,
                   newValue.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 {
                    withAnimation(VFAnimation.springBounce) {
                        celebrationWasDemo = false
                        practiceCelebrated = true
                    }
                }
            }

            if demoRunning {
                HStack(spacing: 6) {
                    Image(systemName: "play.circle.fill")
                    Text(demoStatusLabel)
                }
                .font(VFFont.pillLabel)
                .foregroundStyle(VFColor.accent)
            } else if stateSubject.state != .idle {
                HStack(spacing: 6) {
                    Image(systemName: stateSubject.state.sfSymbol)
                    Text(stateSubject.state.label)
                }
                .font(VFFont.pillLabel)
                .foregroundStyle(stateSubject.state.tintColor)
            }

            if !practiceCelebrated && !demoRunning {
                Button {
                    runPracticeDemo()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                        Text("Watch a quick demo instead")
                    }
                }
                .buttonStyle(.plain)
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.accent)
            }

            if practiceCelebrated {
                VStack(alignment: .leading, spacing: VFSpacing.xxs) {
                    Text(celebrationWasDemo ? "That's dictation — messy speech in, clean text out." : "Well done! That was a real dictation.")
                        .font(VFFont.settingsBody)
                        .foregroundStyle(VFColor.success)
                    Text(celebrationWasDemo
                         ? "Notice the \u{201C}at 3, no actually 4\u{201D} got cleaned up automatically. Now you try: hold \(keycapLabel(for: hotkeyBinding)), speak, release — or continue and try anywhere later."
                         : "It works exactly like this in Slack, email, docs — anywhere your cursor blinks. Try again with something messy like \u{201C}let's meet at 3, no wait, 4\u{201D} and watch it come out clean.")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(VFSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Rectangle()
                        .fill(VFColor.success.opacity(0.08))
                        .overlay(Rectangle().stroke(VFColor.success.opacity(0.5), lineWidth: 1))
                )
            }
        }
    }

    /// Scripted typewriter demo: "speaks" a messy sentence into the practice
    /// box, then swaps in the cleaned-up transcript — the core value demo for
    /// users who can't (or won't) dictate yet.
    private func runPracticeDemo() {
        guard !demoRunning else { return }
        demoRunning = true
        practiceText = ""

        let messy = "Umm hi Greg, let's connect soon. Are you available at 3, no actually 4?"
        let clean = "Hi Greg, let's connect soon. Are you available at 4?"

        Task { @MainActor in
            demoStatusLabel = "Listening… (demo — this is what you'd say)"
            for character in messy {
                practiceText.append(character)
                try? await Task.sleep(nanoseconds: 28_000_000)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)

            demoStatusLabel = "Transcribing… (demo)"
            try? await Task.sleep(nanoseconds: 800_000_000)

            practiceText = clean
            demoRunning = false
            withAnimation(VFAnimation.springBounce) {
                celebrationWasDemo = true
                practiceCelebrated = true
            }
        }
    }

    private func practiceInstruction(number: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VFSpacing.xs) {
            Text(number)
                .font(VFFont.archivo(10, .bold))
                .foregroundStyle(Color.white)
                .frame(width: 16, height: 16)
                .background(Rectangle().fill(VFColor.accent))
            Text(text)
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Finish

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: VFSpacing.lg) {
            HStack {
                Spacer()
                VStack(spacing: VFSpacing.sm) {
                    OnboardingKeycap(label: keycapLabel(for: hotkeyBinding), pulsing: false)
                    Text("Your dictation key. Hold, speak, release.")
                        .font(VFFont.settingsCaption)
                        .foregroundStyle(VFColor.muted)
                }
                Spacer()
            }
            .padding(.vertical, VFSpacing.sm)

            VStack(alignment: .leading, spacing: VFSpacing.xs) {
                finishBullet(icon: "globe", text: "Works in every app — dictate straight into Slack, email, docs, code.")
                finishBullet(icon: "mic.fill", text: "The mic icon in your menu bar is always there for settings and history.")
                finishBullet(icon: "gearshape.fill", text: "Settings opens next — fine-tune your engine, hotkey, and style there.")
                finishBullet(icon: "arrow.counterclockwise", text: "Replay this setup anytime from Settings → Onboarding.")
            }
            .padding(VFSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Rectangle()
                    .fill(VFColor.panel2)
                    .overlay(Rectangle().stroke(VFColor.border, lineWidth: 1))
            )
        }
    }

    private func finishBullet(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VFSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VFColor.accent)
                .frame(width: 16)
            Text(text)
                .font(VFFont.settingsCaption)
                .foregroundStyle(VFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Model install status

    /// Compact one-liner tracking the background MLX model install kicked off
    /// on the engine step. Shown on every step after the engine choice so the
    /// user always knows where their local model stands.
    @ViewBuilder
    private var modelInstallStatusRow: some View {
        if step.rawValue >= OnboardingFlowStep.micCheck.rawValue,
           let model = onboardingInstallModel {
            switch mlxInstaller.phase {
            case .installing(let modelID, let detail) where modelID == model.id:
                HStack(spacing: VFSpacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text(runtimeBootstrapDetail.isEmpty ? detail : runtimeBootstrapDetail)
                        .font(VFFont.settingsFootnote)
                        .foregroundStyle(VFColor.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            case .failed(let modelID, _) where modelID == model.id:
                HStack(alignment: .firstTextBaseline, spacing: VFSpacing.xs) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(VFColor.muted)
                    Text("The \(model.displayName) download hit a snag — no problem, Whisper Smart will use Apple's built-in engine until you install it from Settings → Provider.")
                        .font(VFFont.settingsFootnote)
                        .foregroundStyle(VFColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            default:
                if mlxInstaller.isInstalled(model) {
                    HStack(spacing: VFSpacing.xs) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(model.displayName) installed — your local engine is ready.")
                            .font(VFFont.settingsFootnote)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(VFColor.success)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step != .welcome && step != .finish {
                Button("Back") {
                    goBack()
                }
                .buttonStyle(OnboardingCapsuleButtonStyle(tone: .neutral))
            }

            Spacer()

            if step == .practice && !practiceCelebrated {
                Button("Skip practice") {
                    advance()
                }
                .buttonStyle(.plain)
                .font(VFFont.settingsFootnote)
                .foregroundStyle(VFColor.muted)
                .padding(.trailing, VFSpacing.md)
            }

            Button(continueLabel) {
                advance()
            }
            .buttonStyle(OnboardingCapsuleButtonStyle(tone: .primary))
            .disabled(!canContinue)
        }
    }

    private var continueLabel: String {
        switch step {
        case .welcome:     return "Let's go"
        case .permissions: return "Continue"
        case .engine:
            if let model = selectedLocalModel, !mlxInstaller.isInstalled(model) {
                if case .installing(let modelID, _) = mlxInstaller.phase, modelID == model.id {
                    return "Downloading…"
                }
            }
            return "Use this engine"
        case .micCheck:    return "Sounds good"
        case .hotkey:      return "Continue"
        case .practice:    return "Continue"
        case .finish:      return "Start dictating"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .permissions:
            return permissionSnapshot.microphone.isUsable && permissionSnapshot.accessibility.isUsable
        case .engine:
            // Cloud engine (no local model) or already-installed model: free to go.
            guard let model = selectedLocalModel, !mlxInstaller.isInstalled(model) else { return true }
            // A failed download still lets the user proceed on the Apple fallback.
            if case .failed(let modelID, _) = mlxInstaller.phase, modelID == model.id { return true }
            // Otherwise the local model is still downloading — hold here so the
            // practice step never fires against a missing model.
            return false
        case .practice:
            return practiceCelebrated
        default:
            return true
        }
    }

    // MARK: Flow control

    private func advance() {
        switch step {
        case .engine:
            applyEnginePreset()
        case .finish:
            ProductOnboardingPreferences.markCompleted()
            onFinished()
            return
        default:
            break
        }
        if let next = OnboardingFlowStep(rawValue: step.rawValue + 1) {
            withAnimation(VFAnimation.fadeMedium) { step = next }
        }
    }

    private func goBack() {
        if let prev = OnboardingFlowStep(rawValue: step.rawValue - 1) {
            withAnimation(VFAnimation.fadeMedium) { step = prev }
        }
    }

    private func refreshPermissions() {
        let previous = permissionSnapshot
        permissionSnapshot = PermissionDiagnostics.snapshot()
        if !previous.accessibility.isUsable && permissionSnapshot.accessibility.isUsable {
            // Accessibility just landed — let the app bootstrap the hotkey
            // monitor so the practice step works.
            onPermissionsChanged()
        }
    }

    private func applyEnginePreset() {
        selectedPreset.providerKind.saveSelection()
        NotificationCenter.default.post(name: .sttProviderDidChange, object: nil)
        // Safety net: the default (Balanced) can be confirmed without ever
        // clicking a card, so make sure its model install is running too.
        beginModelInstallIfNeeded()
    }

    private func selectEnginePreset(_ preset: OnboardingEnginePreset) {
        guard preset != selectedPreset else { return }
        selectedPreset = preset
        beginModelInstallIfNeeded()
    }

    /// Kicks off the runtime bootstrap + model download for the selected local
    /// preset in the background. Picking a local engine card is the download
    /// consent (the footnote spells out size and behavior); onboarding never
    /// blocks on the install — Apple Speech covers dictation until it lands.
    private func beginModelInstallIfNeeded() {
        let model = MLXModelCatalog.selectedModel(for: selectedPreset.providerKind)

        // Switched away from an onboarding-started install: stop the old
        // download so we don't pull gigabytes the user no longer wants.
        var cancelledInFlightInstall = false
        if let inFlight = onboardingInstallModel, inFlight.id != model?.id {
            if case .installing(let modelID, _) = mlxInstaller.phase, modelID == inFlight.id {
                mlxInstaller.cancelInstall()
                cancelledInFlightInstall = true
            }
            onboardingInstallModel = nil
        }

        guard let model, !mlxInstaller.isInstalled(model) else { return }
        if cancelledInFlightInstall {
            // cancelInstall() resets the installer phase via an async hop to
            // the main queue, so `phase` still reads `.installing(oldModel)`
            // here — both the guard below and install()'s own re-entrancy
            // guard would wrongly bail and the new model would never start.
            // Queue the new install behind that pending reset (FIFO on main).
            onboardingInstallModel = model
            let installer = mlxInstaller
            DispatchQueue.main.async {
                installer.install(model)
            }
            return
        }
        if case .installing = mlxInstaller.phase { return }
        onboardingInstallModel = model
        mlxInstaller.install(model)
    }

    private func applyHotkey(_ binding: HotkeyBinding) {
        hotkeyBinding = binding
        binding.save()
        NotificationCenter.default.post(
            name: .hotkeyBindingDidChange,
            object: nil,
            userInfo: ["binding": binding.toUserInfo()]
        )
    }

    private func keycapLabel(for binding: HotkeyBinding) -> String {
        if binding.displayString.hasSuffix(" Hold") {
            return String(binding.displayString.dropLast(" Hold".count))
        }
        return binding.displayString
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Keycap

private struct OnboardingKeycap: View {
    let label: String
    let pulsing: Bool

    @State private var pulse = false

    var body: some View {
        Text(label)
            .font(VFFont.archivo(26, .heavy))
            .foregroundStyle(VFColor.text)
            .padding(.horizontal, VFSpacing.xl)
            .padding(.vertical, VFSpacing.md)
            .background(
                Rectangle()
                    .fill(VFColor.panel)
                    .overlay(Rectangle().stroke(VFColor.border2, lineWidth: 2))
            )
            .overlay(
                Rectangle()
                    .stroke(VFColor.accent.opacity(pulsing && pulse ? 0.7 : 0), lineWidth: 2)
                    .scaleEffect(pulse ? 1.10 : 1.0)
            )
            .onAppear {
                guard pulsing else { return }
                withAnimation(VFAnimation.pulseLoop) { pulse = true }
            }
    }
}

// MARK: - Button style

private struct OnboardingCapsuleButtonStyle: ButtonStyle {
    enum Tone { case primary, neutral }
    var tone: Tone = .primary

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VFFont.pillLabel)
            .foregroundStyle(tone == .primary ? Color.white : VFColor.text)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Rectangle()
                    .fill(tone == .primary ? VFColor.accent : VFColor.panel2)
                    .overlay(
                        Rectangle().stroke(
                            tone == .primary ? VFColor.accentDark : VFColor.border2,
                            lineWidth: 1
                        )
                    )
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
    }
}
