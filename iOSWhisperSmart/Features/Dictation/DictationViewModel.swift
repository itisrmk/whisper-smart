import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(ActivityKit)
import ActivityKit
#endif

struct DictationTextPostProcessor {
    static func apply(_ text: String, rules: [ReplacementRule], style: OutputStyleMode) -> String {
        let withRules = applyReplacementRules(text, rules: rules)
        return applyStyle(withRules, style: style)
    }

    static func applyReplacementRules(_ text: String, rules: [ReplacementRule]) -> String {
        rules.reduce(text) { partial, rule in
            let pattern = NSRegularExpression.escapedPattern(for: rule.find.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !pattern.isEmpty else { return partial }
            guard let regex = try? NSRegularExpression(pattern: "\\b\(pattern)\\b", options: [.caseInsensitive]) else {
                return partial
            }
            let range = NSRange(partial.startIndex..<partial.endIndex, in: partial)
            return regex.stringByReplacingMatches(in: partial, options: [], range: range, withTemplate: rule.replaceWith)
        }
    }

    static func applyStyle(_ text: String, style: OutputStyleMode) -> String {
        let cleaned = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return cleaned }

        switch style {
        case .message:
            return ensureEndingPunctuation(sentenceCase(cleaned), fallback: ".")
        case .email:
            let bodyParagraphs = cleaned
                .components(separatedBy: CharacterSet(charactersIn: "\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { ensureEndingPunctuation(sentenceCase($0), fallback: ".") }

            let body = bodyParagraphs.isEmpty
                ? ensureEndingPunctuation(sentenceCase(cleaned), fallback: ".")
                : bodyParagraphs.joined(separator: "\n\n")

            return "Hi,\n\n\(body)\n\nBest regards,"
        case .notes:
            let lines = cleaned
                .components(separatedBy: CharacterSet(charactersIn: ".;\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if lines.isEmpty {
                return "• \(ensureEndingPunctuation(sentenceCase(cleaned), fallback: "."))"
            }
            return lines
                .map { ensureEndingPunctuation(sentenceCase($0), fallback: ".") }
                .map { "• \($0)" }
                .joined(separator: "\n")
        }
    }

    private static func sentenceCase(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    private static func ensureEndingPunctuation(_ value: String, fallback: Character) -> String {
        guard let last = value.last else { return value }
        if [".", "!", "?", ":"].contains(last) {
            return value
        }
        return value + String(fallback)
    }
}

final class DictationLiveActivityManager {
    #if canImport(ActivityKit)
    @available(iOS 16.1, *)
    private var activity: Activity<DictationLiveActivityAttributes>?
    #endif

    func start() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = DictationLiveActivityAttributes(startedAt: Date())
        let initial = DictationLiveActivityAttributes.ContentState(transcriptPreview: "Listening…", isCapturing: true)
        do {
            activity = try Activity.request(attributes: attributes, content: .init(state: initial, staleDate: nil))
        } catch {
            // Graceful fallback: no-op when unsupported/fails on simulator.
        }
        #endif
    }

    func update(transcript: String, isCapturing: Bool) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        guard let activity else { return }

        let preview = String(transcript.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        let state = DictationLiveActivityAttributes.ContentState(
            transcriptPreview: preview.isEmpty ? "Listening…" : preview,
            isCapturing: isCapturing
        )

        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
        #endif
    }

    func end(finalTranscript: String) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        guard let activity else { return }

        let preview = String(finalTranscript.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        let finalState = DictationLiveActivityAttributes.ContentState(
            transcriptPreview: preview.isEmpty ? "Done" : preview,
            isCapturing: false
        )

        Task {
            await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
        }
        self.activity = nil
        #endif
    }
}

enum DictationLaunchSource {
    case manual
    case keyboardHandoff
}

@MainActor
final class DictationViewModel: ObservableObject {
    @Published private(set) var state: DictationSessionState = .idle
    @Published var permissionDenied = false
    @Published var privacyIndicator = "All transcription is local."

    var transcript: String { state.transcript }
    var selectedEngine: EnginePolicy { settings.privacyMode.mappedEngine }

    private let localService: SpeechToTextService
    private let cloudService: SpeechToTextService
    private let settings: AppSettings
    private let historyStore: TranscriptHistoryStore
    private let metricsStore: ReliabilityMetricsStore
    private let liveActivityManager: DictationLiveActivityManager

    private var activeService: SpeechToTextService?
    private var usedCloudForCurrentSession = false
    private var sessionStartedAt: Date?
    private var activeLaunchSource: DictationLaunchSource = .manual
    private var keyboardSilenceTimer: Timer?
    private var lastPartialAt: Date?
    private let keyboardAutoStopPolicy = KeyboardLaunchAutoStopPolicy()

    init(
        settings: AppSettings,
        historyStore: TranscriptHistoryStore,
        metricsStore: ReliabilityMetricsStore,
        localService: SpeechToTextService = AppleSpeechRecognizerService(),
        cloudService: SpeechToTextService? = nil,
        liveActivityManager: DictationLiveActivityManager = DictationLiveActivityManager()
    ) {
        self.settings = settings
        self.historyStore = historyStore
        self.metricsStore = metricsStore
        self.localService = localService
        self.liveActivityManager = liveActivityManager
        self.cloudService = cloudService ?? OpenAICloudSpeechService(apiKeyProvider: {
            KeychainService.shared.read(for: SecureKeys.openAIAPIKey)
        })
    }

    func requestPermissionsOnly(completion: @escaping (Bool) -> Void) {
        Task {
            let hasPermission = await localService.requestPermissions()
            await MainActor.run {
                self.permissionDenied = !hasPermission
                if !hasPermission {
                    self.state = .error("Permissions denied for microphone or speech recognition.")
                }
                completion(hasPermission)
            }
        }
    }

    func startDictation(source: DictationLaunchSource = .manual) {
        if state.isCapturing {
            return
        }

        requestPermissionsOnly { [weak self] hasPermission in
            guard let self, hasPermission else { return }

            self.metricsStore.trackStart()
            self.sessionStartedAt = Date()
            self.activeLaunchSource = source
            self.lastPartialAt = nil
            self.stopKeyboardSilenceTimer()

            let service = self.resolveServiceForStart()
            self.metricsStore.trackSessionRouting(usedCloud: self.usedCloudForCurrentSession)
            self.activeService = service
            self.bindCallbacks(for: service)

            do {
                self.state = DictationSessionReducer.reduce(state: self.state, event: .start)
                self.liveActivityManager.start()
                try service.startRecognition()
                self.startKeyboardSilenceTimerIfNeeded()
            } catch {
                if self.selectedEngine == .balanced, service === self.cloudService {
                    self.startBalancedFallbackToLocal(error: error)
                } else {
                    self.metricsStore.trackFailure()
                    self.state = DictationSessionReducer.reduce(state: self.state, event: .fail(error.localizedDescription))
                }
            }
        }
    }

    func stopDictation() {
        stopKeyboardSilenceTimer()
        activeService?.stopRecognition()
        if !transcript.isEmpty, case .partial = state {
            state = .final(transcript)
        }
    }

    func reset() {
        stopKeyboardSilenceTimer()
        activeService?.stopRecognition()
        state = .idle
        liveActivityManager.end(finalTranscript: "")
    }

    func copyToClipboard() {
        #if canImport(UIKit)
        UIPasteboard.general.string = transcript
        #endif
    }

    func updateEngine(_ engine: EnginePolicy) {
        settings.privacyMode = {
            switch engine {
            case .localApple: return .privateOffline
            case .balanced: return .balanced
            case .cloudOpenAI: return .cloudFast
            }
        }()
    }

    private func resolveServiceForStart() -> SpeechToTextService {
        usedCloudForCurrentSession = false

        let hasAPIKey = KeychainService.shared.read(for: SecureKeys.openAIAPIKey)?.isEmpty == false

        switch selectedEngine {
        case .localApple:
            privacyIndicator = "All transcription is local."
            return localService
        case .cloudOpenAI:
            let policy = CloudTranscriptionPolicy.evaluate(
                cloudEnabled: settings.cloudTranscriptionEnabled,
                cloudConsentGranted: settings.cloudConsentGranted,
                hasAPIKey: hasAPIKey,
                requireNetwork: false,
                networkReachable: NetworkMonitor.shared.isReachable
            )

            guard policy.isAllowed else {
                if let reason = policy.reason {
                    metricsStore.trackBlockedCloud(reason: reason)
                }
                privacyIndicator = "Cloud mode requested but blocked: \(policy.reason?.userMessage ?? "Unknown cloud policy block"). Using local transcription."
                return localService
            }

            usedCloudForCurrentSession = true
            privacyIndicator = "Cloud mode: audio is sent to OpenAI when you stop dictation."
            return cloudService
        case .balanced:
            let policy = CloudTranscriptionPolicy.evaluate(
                cloudEnabled: settings.cloudTranscriptionEnabled,
                cloudConsentGranted: settings.cloudConsentGranted,
                hasAPIKey: hasAPIKey,
                requireNetwork: true,
                networkReachable: NetworkMonitor.shared.isReachable
            )

            if policy.isAllowed {
                usedCloudForCurrentSession = true
                privacyIndicator = "Balanced mode: cloud enhancement is active (with local fallback)."
                return cloudService
            }

            if let reason = policy.reason {
                metricsStore.trackBlockedCloud(reason: reason)
            }
            privacyIndicator = "Balanced mode: using local transcription (\(policy.reason?.userMessage ?? "cloud unavailable"))."
            return localService
        }
    }

    private func startBalancedFallbackToLocal(error: Error) {
        usedCloudForCurrentSession = false
        metricsStore.trackLocalFallback()
        privacyIndicator = "Cloud unavailable. Continued in local mode."
        bindCallbacks(for: localService)
        do {
            try localService.startRecognition()
            startKeyboardSilenceTimerIfNeeded()
        } catch let fallbackError {
            metricsStore.trackFailure()
            state = DictationSessionReducer.reduce(state: state, event: .fail("Cloud error: \(error.localizedDescription). Local fallback error: \(fallbackError.localizedDescription)"))
        }
    }

    private func bindCallbacks(for service: SpeechToTextService) {
        service.onPartialResult = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.lastPartialAt = Date()
                self.state = DictationSessionReducer.reduce(state: self.state, event: .partial(text))
                self.liveActivityManager.update(transcript: text, isCapturing: true)
            }
        }

        service.onFinalResult = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.stopKeyboardSilenceTimer()
                let transformed = DictationTextPostProcessor.apply(
                    text,
                    rules: self.settings.replacementRules,
                    style: self.settings.outputStyleMode
                )
                self.state = DictationSessionReducer.reduce(state: self.state, event: .final(transformed))
                self.historyStore.updateRetentionPolicy(self.settings.retentionPolicy)
                self.historyStore.add(transcript: transformed, engine: self.selectedEngine, usedCloud: self.usedCloudForCurrentSession)
                KeyboardCompanionStore.shared.saveFinalTranscript(transformed)

                if let started = self.sessionStartedAt {
                    self.metricsStore.trackSuccess(latencyMs: Date().timeIntervalSince(started) * 1000)
                }

                self.liveActivityManager.end(finalTranscript: transformed)
            }
        }

        service.onError = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.stopKeyboardSilenceTimer()
                if self.selectedEngine == .balanced, service === self.cloudService {
                    self.startBalancedFallbackToLocal(error: NSError(domain: "CloudSTT", code: 0, userInfo: [NSLocalizedDescriptionKey: message]))
                } else {
                    self.metricsStore.trackFailure()
                    self.state = DictationSessionReducer.reduce(state: self.state, event: .fail(message))
                }
            }
        }
    }

    private func startKeyboardSilenceTimerIfNeeded() {
        guard activeLaunchSource == .keyboardHandoff else { return }

        stopKeyboardSilenceTimer()
        keyboardSilenceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.evaluateKeyboardSilenceAutoStop(now: Date())
        }
    }

    private func stopKeyboardSilenceTimer() {
        keyboardSilenceTimer?.invalidate()
        keyboardSilenceTimer = nil
    }

    private func evaluateKeyboardSilenceAutoStop(now: Date) {
        guard activeLaunchSource == .keyboardHandoff, state.isCapturing else { return }
        guard keyboardAutoStopPolicy.shouldAutoStop(lastPartialAt: lastPartialAt, now: now) else { return }
        stopDictation()
    }
}
