import Foundation
import Combine
import Speech
import os.log

private let logger = Logger(subsystem: "com.visperflow", category: "STTProviderDiagnostics")

/// Overall runtime health of provider resolution.
enum ProviderHealthLevel: String {
    case healthy = "Healthy"
    case degraded = "Degraded"
    case unavailable = "Unavailable"
}

/// A single provider health check displayed in diagnostics UI.
struct ProviderHealthCheck: Identifiable, Equatable {
    let id: String
    let title: String
    let isPassing: Bool
    let detail: String
}

/// Runtime diagnostics for the currently requested/effective STT provider.
struct ProviderRuntimeDiagnostics {
    let timestamp: Date
    let requestedKind: STTProviderKind
    let effectiveKind: STTProviderKind
    let healthLevel: ProviderHealthLevel
    let checks: [ProviderHealthCheck]
    let fallbackReason: String?

    var usesFallback: Bool {
        requestedKind != effectiveKind
    }

    // MARK: - Regression guard

    /// Debug-only consistency check: when `effectiveKind` differs from
    /// `requestedKind` a `fallbackReason` must be present, and vice-versa
    /// a healthy non-fallback resolution must not carry a stale reason.
    #if DEBUG
    func assertDisplayConsistency(file: StaticString = #fileID, line: UInt = #line) {
        if usesFallback {
            assert(
                fallbackReason != nil && !(fallbackReason?.isEmpty ?? true),
                "Provider mismatch (requested=\(requestedKind.rawValue), effective=\(effectiveKind.rawValue)) but fallbackReason is missing — UI will display incomplete status.",
                file: file, line: line
            )
        } else {
            assert(
                fallbackReason == nil,
                "Provider matches (effective=\(effectiveKind.rawValue)) but a stale fallbackReason is present: '\(fallbackReason ?? "")' — UI will display misleading status.",
                file: file, line: line
            )
        }
    }
    #endif
}

/// Concrete provider plus diagnostics explaining how it was selected.
struct ProviderResolution {
    let provider: STTProvider
    let diagnostics: ProviderRuntimeDiagnostics
}

/// Shared runtime diagnostics store observed by the settings UI.
final class ProviderRuntimeDiagnosticsStore: ObservableObject {
    static let shared = ProviderRuntimeDiagnosticsStore()

    @Published private(set) var latest: ProviderRuntimeDiagnostics

    private init() {
        latest = STTProviderResolver.diagnostics(for: STTProviderKind.loadSelection())
    }

    func publish(_ diagnostics: ProviderRuntimeDiagnostics) {
        #if DEBUG
        diagnostics.assertDisplayConsistency()
        #endif
        if Thread.isMainThread {
            latest = diagnostics
        } else {
            DispatchQueue.main.async {
                self.latest = diagnostics
            }
        }
    }
}

/// Resolves the requested provider kind into a usable runtime provider and
/// emits diagnostics (health checks + fallback rationale).
enum STTProviderResolver {

    struct Environment {
        var microphoneStatus: () -> PermissionDiagnostics.Status
        var speechRecognitionStatus: () -> PermissionDiagnostics.Status
        var speechRecognizerFactory: () -> SFSpeechRecognizer?
        var cloudFallbackEnabled: () -> Bool
        var openAIAPIKey: () -> String
        var parakeetBootstrapStatus: () -> ParakeetRuntimeBootstrapStatus

        static let live = Environment(
            microphoneStatus: { PermissionDiagnostics.microphoneStatus() },
            speechRecognitionStatus: { PermissionDiagnostics.speechRecognitionStatus() },
            speechRecognizerFactory: { SFSpeechRecognizer(locale: .current) },
            cloudFallbackEnabled: { DictationProviderPolicy.cloudFallbackEnabled },
            openAIAPIKey: { DictationProviderPolicy.openAIAPIKey },
            parakeetBootstrapStatus: { ParakeetRuntimeBootstrapManager.shared.statusSnapshot() }
        )
    }

    static func resolve(for requestedKind: STTProviderKind) -> ProviderResolution {
        let diagnostics = diagnostics(for: requestedKind)
        let provider = makeProvider(for: diagnostics)

        if let fallbackReason = diagnostics.fallbackReason {
            logger.warning(
                "Provider fallback requested=\(requestedKind.rawValue, privacy: .public) effective=\(diagnostics.effectiveKind.rawValue, privacy: .public): \(fallbackReason, privacy: .public)"
            )
        } else {
            logger.info(
                "Provider selected requested=\(requestedKind.rawValue, privacy: .public) effective=\(diagnostics.effectiveKind.rawValue, privacy: .public)"
            )
        }

        return ProviderResolution(provider: provider, diagnostics: diagnostics)
    }

    static func diagnostics(for requestedKind: STTProviderKind) -> ProviderRuntimeDiagnostics {
        diagnostics(for: requestedKind, environment: .live)
    }

    static func diagnostics(for requestedKind: STTProviderKind, environment: Environment) -> ProviderRuntimeDiagnostics {
        switch requestedKind {
        case .appleSpeech:
            return appleSpeechDiagnostics(requestedKind: requestedKind, environment: environment)
        case .parakeet:
            return parakeetDiagnostics(requestedKind: requestedKind, environment: environment)
        case .whisper:
            return whisperLocalDiagnostics(requestedKind: requestedKind, environment: environment)
        case .openaiAPI:
            return openAIDiagnostics(requestedKind: requestedKind, environment: environment)
        case .stub:
            return stubDiagnostics(
                requestedKind: requestedKind,
                environment: environment
            )
        }
    }

    // MARK: - Provider-specific diagnostics

    private static func appleSpeechDiagnostics(requestedKind: STTProviderKind, environment: Environment) -> ProviderRuntimeDiagnostics {
        var checks = [microphoneCheck(environment: environment)]
        let speechChecks = appleSpeechReadinessChecks(prefix: nil, environment: environment)
        checks.append(contentsOf: speechChecks)

        let level: ProviderHealthLevel = checks.allSatisfy(\.isPassing) ? .healthy : .degraded

        return ProviderRuntimeDiagnostics(
            timestamp: Date(),
            requestedKind: requestedKind,
            effectiveKind: .appleSpeech,
            healthLevel: level,
            checks: checks,
            fallbackReason: nil
        )
    }

    private static func parakeetDiagnostics(requestedKind: STTProviderKind, environment: Environment) -> ProviderRuntimeDiagnostics {
        var checks = [microphoneCheck(environment: environment)]
        var fallbackReason: String?
        var canUseParakeet = true

        guard let variant = requestedKind.defaultVariant else {
            checks.append(
                ProviderHealthCheck(
                    id: "parakeet.variant",
                    title: "Parakeet Model Variant",
                    isPassing: false,
                    detail: "No Parakeet model variant is configured."
                )
            )
            canUseParakeet = false
            fallbackReason = "No Parakeet model variant is configured in this build."
            return finalizeParakeetDiagnostics(
                requestedKind: requestedKind,
                checks: checks,
                canUseParakeet: canUseParakeet,
                fallbackReason: fallbackReason,
                environment: environment
            )
        }

        let pathResolved = (variant.localURL != nil)
        checks.append(
            ProviderHealthCheck(
                id: "parakeet.model_path",
                title: "Model Path Resolution",
                isPassing: pathResolved,
                detail: pathResolved
                    ? "Model path resolved to Application Support."
                    : "Cannot resolve Application Support model path."
            )
        )
        if !pathResolved {
            canUseParakeet = false
            fallbackReason = "Cannot resolve Parakeet model storage path."
        }

        let modelReady = variant.isDownloaded
        let sourceConfigured = variant.hasDownloadSource || modelReady
        let sourceDetail: String
        if variant.hasDownloadSource {
            sourceDetail = "Using source '\(variant.configuredSourceDisplayName)'."
        } else if modelReady {
            sourceDetail = "Model file is already present on disk."
        } else {
            sourceDetail = variant.downloadUnavailableReason ?? "Model source not configured."
        }
        checks.append(
            ProviderHealthCheck(
                id: "parakeet.model_source",
                title: "Model Source Configuration",
                isPassing: sourceConfigured,
                detail: sourceDetail
            )
        )
        checks.append(
            ProviderHealthCheck(
                id: "parakeet.model_source_url",
                title: "Model Source URL",
                isPassing: sourceConfigured,
                detail: variant.configuredSourceURLDisplay
            )
        )

        if let source = variant.configuredSource {
            if let tokenizerStatus = variant.tokenizerValidationStatus(using: source) {
                checks.append(
                    ProviderHealthCheck(
                        id: "parakeet.tokenizer",
                        title: "Tokenizer Artifact",
                        isPassing: tokenizerStatus.isReady,
                        detail: tokenizerStatus.detail
                    )
                )
            } else {
                checks.append(
                    ProviderHealthCheck(
                        id: "parakeet.tokenizer",
                        title: "Tokenizer Artifact",
                        isPassing: true,
                        detail: "Tokenizer download is optional for this source."
                    )
                )
            }
        }

        if !sourceConfigured, fallbackReason == nil {
            canUseParakeet = false
            fallbackReason = variant.downloadUnavailableReason
                ?? "Model source not configured. Open Settings -> Provider and choose a source."
        }

        checks.append(
            ProviderHealthCheck(
                id: "parakeet.model_ready",
                title: "Model File Validation",
                isPassing: modelReady,
                detail: variant.validationStatus
            )
        )
        if !modelReady, fallbackReason == nil {
            canUseParakeet = false
            fallbackReason = "Parakeet model is not ready (\(variant.validationStatus)). Download from '\(variant.configuredSourceDisplayName)' in Settings -> Provider."
        }

        let runtimeImplemented = ParakeetSTTProvider.inferenceImplemented
        checks.append(
            ProviderHealthCheck(
                id: "parakeet.runtime",
                title: "Parakeet Inference Runtime",
                isPassing: runtimeImplemented,
                detail: runtimeImplemented
                    ? "ONNX runtime integration is available."
                    : "ONNX runtime integration is not wired in this build."
            )
        )
        if !runtimeImplemented, fallbackReason == nil {
            canUseParakeet = false
            fallbackReason = "Parakeet inference runtime is not integrated yet."
        }

        let bootstrapAssessment = parakeetRuntimeBootstrapCheck(environment: environment)
        checks.append(bootstrapAssessment.check)
        if bootstrapAssessment.blocksParakeet, fallbackReason == nil {
            canUseParakeet = false
            fallbackReason = bootstrapAssessment.failureReason
        }

        return finalizeParakeetDiagnostics(
            requestedKind: requestedKind,
            checks: checks,
            canUseParakeet: canUseParakeet,
            fallbackReason: fallbackReason,
            environment: environment
        )
    }

    private static func finalizeParakeetDiagnostics(
        requestedKind: STTProviderKind,
        checks: [ProviderHealthCheck],
        canUseParakeet: Bool,
        fallbackReason: String?,
        environment: Environment
    ) -> ProviderRuntimeDiagnostics {
        let finalChecks = checks

        if canUseParakeet {
            let level: ProviderHealthLevel = finalChecks.allSatisfy(\.isPassing) ? .healthy : .degraded
            return ProviderRuntimeDiagnostics(
                timestamp: Date(),
                requestedKind: requestedKind,
                effectiveKind: .parakeet,
                healthLevel: level,
                checks: finalChecks,
                fallbackReason: nil
            )
        }

        return fallbackToApple(
            requestedKind: requestedKind,
            checks: finalChecks,
            fallbackReason: fallbackReason ?? "Parakeet local model/runtime is unavailable.",
            environment: environment
        )
    }

    private static func whisperLocalDiagnostics(requestedKind: STTProviderKind, environment: Environment) -> ProviderRuntimeDiagnostics {
        var checks = [microphoneCheck(environment: environment)]

        let runtimeReason = WhisperLocalRuntime.unavailableReason()
        checks.append(
            ProviderHealthCheck(
                id: "whisper.runtime",
                title: "Whisper CLI Runtime",
                isPassing: runtimeReason == nil,
                detail: runtimeReason ?? "Local whisper-cli runtime is configured and executable."
            )
        )

        guard runtimeReason == nil else {
            return fallbackToApple(
                requestedKind: requestedKind,
                checks: checks,
                fallbackReason: runtimeReason ?? "Whisper local runtime unavailable.",
                environment: environment
            )
        }

        let level: ProviderHealthLevel = checks.allSatisfy(\.isPassing) ? .healthy : .degraded
        return ProviderRuntimeDiagnostics(
            timestamp: Date(),
            requestedKind: requestedKind,
            effectiveKind: .whisper,
            healthLevel: level,
            checks: checks,
            fallbackReason: nil
        )
    }

    private static func openAIDiagnostics(requestedKind: STTProviderKind, environment: Environment) -> ProviderRuntimeDiagnostics {
        var checks = [microphoneCheck(environment: environment)]

        checks.append(
            ProviderHealthCheck(
                id: "openai.opt_in",
                title: "Cloud Fallback Opt-In",
                isPassing: environment.cloudFallbackEnabled(),
                detail: environment.cloudFallbackEnabled()
                    ? "Cloud fallback has been explicitly enabled by the user."
                    : "Cloud fallback is disabled. Enable it in Settings -> Provider to use OpenAI Whisper API."
            )
        )

        let hasAPIKey = !environment.openAIAPIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        checks.append(
            ProviderHealthCheck(
                id: "openai.api_key",
                title: "OpenAI API Key",
                isPassing: hasAPIKey,
                detail: hasAPIKey
                    ? "API key is configured."
                    : "No API key configured. Set OPENAI_API_KEY or enter one in Settings -> Provider."
            )
        )

        guard environment.cloudFallbackEnabled(), hasAPIKey else {
            let reason = !environment.cloudFallbackEnabled()
                ? "OpenAI Whisper API is disabled until cloud fallback is explicitly enabled."
                : "OpenAI Whisper API requires an API key."
            return fallbackToApple(requestedKind: requestedKind, checks: checks, fallbackReason: reason, environment: environment)
        }

        let level: ProviderHealthLevel = checks.allSatisfy(\.isPassing) ? .healthy : .degraded
        return ProviderRuntimeDiagnostics(
            timestamp: Date(),
            requestedKind: requestedKind,
            effectiveKind: .openaiAPI,
            healthLevel: level,
            checks: checks,
            fallbackReason: nil
        )
    }

    private static func fallbackToApple(
        requestedKind: STTProviderKind,
        checks: [ProviderHealthCheck],
        fallbackReason: String,
        environment: Environment
    ) -> ProviderRuntimeDiagnostics {
        var combined = checks
        let fallbackChecks = appleSpeechReadinessChecks(prefix: "Fallback", environment: environment)
        combined.append(contentsOf: fallbackChecks)
        let fallbackHealthy = fallbackChecks.allSatisfy(\.isPassing)
        let level: ProviderHealthLevel = fallbackHealthy ? .degraded : .unavailable
        return ProviderRuntimeDiagnostics(
            timestamp: Date(),
            requestedKind: requestedKind,
            effectiveKind: .appleSpeech,
            healthLevel: level,
            checks: combined,
            fallbackReason: fallbackReason
        )
    }

    static func selectableProviderKinds() -> [STTProviderKind] {
        STTProviderKind.allCases.filter { kind in
            let diagnostics = diagnostics(for: kind)
            if kind == .stub { return true }
            return diagnostics.effectiveKind == kind
        }
    }

    private static func unavailableProviderDiagnostics(
        requestedKind: STTProviderKind,
        implementationTitle: String,
        implementationReason: String,
        fallbackReason: String,
        environment: Environment
    ) -> ProviderRuntimeDiagnostics {
        var checks = [microphoneCheck(environment: environment)]
        checks.append(
            ProviderHealthCheck(
                id: "\(requestedKind.rawValue).implementation",
                title: implementationTitle,
                isPassing: false,
                detail: implementationReason
            )
        )

        let fallbackChecks = appleSpeechReadinessChecks(prefix: "Fallback", environment: environment)
        checks.append(contentsOf: fallbackChecks)
        let fallbackHealthy = fallbackChecks.allSatisfy(\.isPassing)
        let level: ProviderHealthLevel = fallbackHealthy ? .degraded : .unavailable

        return ProviderRuntimeDiagnostics(
            timestamp: Date(),
            requestedKind: requestedKind,
            effectiveKind: .appleSpeech,
            healthLevel: level,
            checks: checks,
            fallbackReason: fallbackReason
        )
    }

    private static func stubDiagnostics(requestedKind: STTProviderKind, environment: Environment) -> ProviderRuntimeDiagnostics {
        var checks = [microphoneCheck(environment: environment)]
        checks.append(
            ProviderHealthCheck(
                id: "stub.testing_only",
                title: "Stub Runtime",
                isPassing: false,
                detail: "Stub provider is testing-only and intentionally returns no transcript text."
            )
        )

        return ProviderRuntimeDiagnostics(
            timestamp: Date(),
            requestedKind: requestedKind,
            effectiveKind: .stub,
            healthLevel: .degraded,
            checks: checks,
            fallbackReason: nil
        )
    }

    // MARK: - Provider construction

    private static func makeProvider(for diagnostics: ProviderRuntimeDiagnostics) -> STTProvider {
        switch diagnostics.effectiveKind {
        case .appleSpeech:
            return AppleSpeechSTTProvider()
        case .parakeet:
            guard let variant = diagnostics.requestedKind.defaultVariant else {
                logger.error("Parakeet resolved without a configured variant; falling back to Apple Speech provider instance")
                return AppleSpeechSTTProvider()
            }
            return ParakeetSTTProvider(variant: variant)
        case .whisper:
            return WhisperLocalSTTProvider()
        case .openaiAPI:
            return OpenAIWhisperAPISTTProvider()
        case .stub:
            return StubSTTProvider()
        }
    }

    // MARK: - Shared checks

    private static func parakeetRuntimeBootstrapCheck(environment: Environment) -> (
        check: ProviderHealthCheck,
        blocksParakeet: Bool,
        failureReason: String?
    ) {
        let status = environment.parakeetBootstrapStatus()
        let detail = status.detail

        switch status.phase {
        case .idle:
            return (
                ProviderHealthCheck(
                    id: "parakeet.runtime_bootstrap",
                    title: "Parakeet Runtime Bootstrap",
                    isPassing: true,
                    detail: detail
                ),
                false,
                nil
            )
        case .bootstrapping:
            return (
                ProviderHealthCheck(
                    id: "parakeet.runtime_bootstrap",
                    title: "Parakeet Runtime Bootstrap",
                    isPassing: false,
                    detail: detail
                ),
                false,
                nil
            )
        case .ready:
            return (
                ProviderHealthCheck(
                    id: "parakeet.runtime_bootstrap",
                    title: "Parakeet Runtime Bootstrap",
                    isPassing: true,
                    detail: detail
                ),
                false,
                nil
            )
        case .failed:
            return (
                ProviderHealthCheck(
                    id: "parakeet.runtime_bootstrap",
                    title: "Parakeet Runtime Bootstrap",
                    isPassing: false,
                    detail: detail
                ),
                true,
                "Parakeet runtime bootstrap failed. Use Repair Parakeet Runtime in Settings → Provider."
            )
        }
    }

    private static func microphoneCheck(environment: Environment) -> ProviderHealthCheck {
        let micStatus = environment.microphoneStatus()
        return ProviderHealthCheck(
            id: "permissions.microphone",
            title: "Microphone Permission",
            isPassing: micStatus.isUsable,
            detail: "Status: \(micStatus.rawValue)"
        )
    }

    private static func appleSpeechReadinessChecks(prefix: String?, environment: Environment) -> [ProviderHealthCheck] {
        let namePrefix = prefix.map { "\($0) " } ?? ""
        let idPrefix = prefix.map { "\($0.lowercased())." } ?? ""

        var checks: [ProviderHealthCheck] = []

        let speechStatus = environment.speechRecognitionStatus()
        checks.append(
            ProviderHealthCheck(
                id: "\(idPrefix)apple.permission",
                title: "\(namePrefix)Speech Recognition Permission",
                isPassing: speechStatus.isUsable,
                detail: "Status: \(speechStatus.rawValue)"
            )
        )

        let recognizer = environment.speechRecognizerFactory()
        let recognizerCreated = (recognizer != nil)
        checks.append(
            ProviderHealthCheck(
                id: "\(idPrefix)apple.recognizer_created",
                title: "\(namePrefix)Speech Recognizer Availability",
                isPassing: recognizerCreated,
                detail: recognizerCreated
                    ? "Recognizer initialized for locale \(Locale.current.identifier)."
                    : "Speech recognizer unavailable for locale \(Locale.current.identifier)."
            )
        )

        let recognizerLive = recognizer?.isAvailable ?? false
        checks.append(
            ProviderHealthCheck(
                id: "\(idPrefix)apple.recognizer_live",
                title: "\(namePrefix)Speech Service Reachability",
                isPassing: recognizerLive,
                detail: recognizerLive
                    ? "Recognizer service is currently available."
                    : "Recognizer service is currently unavailable."
            )
        )

        return checks
    }
}
