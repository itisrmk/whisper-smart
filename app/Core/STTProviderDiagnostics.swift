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

    /// Canonical user-facing status for this resolution, or nil when there is
    /// nothing to surface. All UI (menu bar, overlay, settings banners) must
    /// render this shared wording rather than the raw `fallbackReason`.
    var userFacingStatus: AppStatus? {
        guard usesFallback, let fallbackReason, !fallbackReason.isEmpty else { return nil }
        return AppStatusCatalog.providerFallback(reason: fallbackReason)
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
        var mlxBootstrapStatus: () -> MLXRuntimeBootstrapStatus

        static let live = Environment(
            microphoneStatus: { PermissionDiagnostics.microphoneStatus() },
            speechRecognitionStatus: { PermissionDiagnostics.speechRecognitionStatus() },
            speechRecognizerFactory: { SFSpeechRecognizer(locale: .current) },
            cloudFallbackEnabled: { DictationProviderPolicy.cloudFallbackEnabled },
            openAIAPIKey: { DictationProviderPolicy.openAIAPIKey },
            mlxBootstrapStatus: { MLXRuntimeBootstrapManager.shared.statusSnapshot() }
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
        case .parakeet, .whisper:
            return mlxLocalDiagnostics(requestedKind: requestedKind, environment: environment)
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

    /// Diagnostics for the MLX-backed local providers (Parakeet + Whisper).
    /// No silent fallback: the effective kind always stays the requested one,
    /// with health level and checks explaining anything that is not ready.
    private static func mlxLocalDiagnostics(requestedKind: STTProviderKind, environment: Environment) -> ProviderRuntimeDiagnostics {
        var checks = [microphoneCheck(environment: environment)]
        var ready = true
        var unavailableReason: String?

        if let model = MLXModelCatalog.selectedModel(for: requestedKind) {
            let installed = MLXModelInstaller.shared.isInstalled(model)
            checks.append(
                ProviderHealthCheck(
                    id: "mlx.model",
                    title: "\(model.displayName) Model",
                    isPassing: installed,
                    detail: installed
                        ? "Installed (\(model.approxSizeLabel))."
                        : "Not installed. Download it from Settings -> Provider."
                )
            )
            if !installed {
                ready = false
                unavailableReason = "\(model.displayName) is not installed. Download it from Settings -> Provider."
            }
        } else {
            checks.append(
                ProviderHealthCheck(
                    id: "mlx.model",
                    title: "MLX Model Selection",
                    isPassing: false,
                    detail: "No MLX model is configured for this provider."
                )
            )
            ready = false
            unavailableReason = "No MLX model is configured for this provider."
        }

        let bootstrapAssessment = mlxRuntimeBootstrapCheck(environment: environment)
        checks.append(bootstrapAssessment.check)
        if bootstrapAssessment.blocksMLX {
            ready = false
            if unavailableReason == nil {
                unavailableReason = bootstrapAssessment.failureReason
            }
        }

        let level: ProviderHealthLevel
        if ready {
            level = checks.allSatisfy(\.isPassing) ? .healthy : .degraded
        } else {
            level = checks.allSatisfy(\.isPassing) ? .degraded : .unavailable
            if let unavailableReason {
                logger.warning("MLX diagnostics unavailable for \(requestedKind.rawValue, privacy: .public): \(unavailableReason, privacy: .public)")
            }
        }

        return ProviderRuntimeDiagnostics(
            timestamp: Date(),
            requestedKind: requestedKind,
            effectiveKind: requestedKind,
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
                    : "Cloud fallback is off. Turn on 'Allow cloud fallback' in Settings -> Provider to use OpenAI Whisper API."
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

        let endpoint = DictationProviderPolicy.resolvedOpenAIEndpointConfiguration()
        let endpointError = DictationProviderPolicy.validateOpenAIEndpoint(
            baseURL: endpoint.baseURL,
            model: endpoint.model
        )
        checks.append(
            ProviderHealthCheck(
                id: "openai.endpoint",
                title: "Cloud Endpoint",
                isPassing: endpointError == nil,
                detail: endpointError ?? "\(endpoint.profile.displayName): \(endpoint.baseURL)"
            )
        )

        guard environment.cloudFallbackEnabled(), hasAPIKey, endpointError == nil else {
            let reason = !environment.cloudFallbackEnabled()
                ? "OpenAI Whisper API is disabled until 'Allow cloud fallback' is turned on."
                : (!hasAPIKey
                    ? "OpenAI Whisper API requires an API key."
                    : "OpenAI Whisper API endpoint is not configured correctly."
                )
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
            return MLXSTTProvider(model: MLXModelCatalog.selectedParakeetModel)
        case .whisper:
            return MLXSTTProvider(model: MLXModelCatalog.selectedWhisperModel)
        case .openaiAPI:
            return OpenAIWhisperAPISTTProvider()
        case .stub:
            return StubSTTProvider()
        }
    }

    // MARK: - Shared checks

    private static func mlxRuntimeBootstrapCheck(environment: Environment) -> (
        check: ProviderHealthCheck,
        blocksMLX: Bool,
        failureReason: String?
    ) {
        let status = environment.mlxBootstrapStatus()
        let detail = status.detail

        switch status.phase {
        case .idle:
            return (
                ProviderHealthCheck(
                    id: "mlx.runtime_bootstrap",
                    title: "MLX Runtime",
                    isPassing: true,
                    detail: detail
                ),
                false,
                nil
            )
        case .bootstrapping:
            return (
                ProviderHealthCheck(
                    id: "mlx.runtime_bootstrap",
                    title: "MLX Runtime",
                    isPassing: false,
                    detail: detail
                ),
                false,
                nil
            )
        case .ready:
            return (
                ProviderHealthCheck(
                    id: "mlx.runtime_bootstrap",
                    title: "MLX Runtime",
                    isPassing: true,
                    detail: detail
                ),
                false,
                nil
            )
        case .failed:
            return (
                ProviderHealthCheck(
                    id: "mlx.runtime_bootstrap",
                    title: "MLX Runtime",
                    isPassing: false,
                    detail: detail
                ),
                true,
                AppStatusCatalog.mlxRuntimeSetupFailed.message
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
