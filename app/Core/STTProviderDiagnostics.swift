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
        switch requestedKind {
        case .appleSpeech:
            return appleSpeechDiagnostics(requestedKind: requestedKind)
        case .parakeet:
            return parakeetDiagnostics(requestedKind: requestedKind)
        case .whisper:
            return unavailableProviderDiagnostics(
                requestedKind: requestedKind,
                implementationTitle: "Whisper Runtime",
                implementationReason: "Whisper local runtime is not implemented in this build.",
                fallbackReason: "Whisper local runtime is not available yet."
            )
        case .openaiAPI:
            return unavailableProviderDiagnostics(
                requestedKind: requestedKind,
                implementationTitle: "OpenAI API Runtime",
                implementationReason: "OpenAI Whisper API integration is not implemented in this build.",
                fallbackReason: "OpenAI Whisper API integration is not available yet."
            )
        case .stub:
            return stubDiagnostics(
                requestedKind: requestedKind
            )
        }
    }

    // MARK: - Provider-specific diagnostics

    private static func appleSpeechDiagnostics(requestedKind: STTProviderKind) -> ProviderRuntimeDiagnostics {
        var checks = [microphoneCheck()]
        let speechChecks = appleSpeechReadinessChecks(prefix: nil)
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

    private static func parakeetDiagnostics(requestedKind: STTProviderKind) -> ProviderRuntimeDiagnostics {
        var checks = [microphoneCheck()]
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
                fallbackReason: fallbackReason
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

        let bootstrapAssessment = parakeetRuntimeBootstrapCheck()
        checks.append(bootstrapAssessment.check)
        if bootstrapAssessment.blocksParakeet, fallbackReason == nil {
            canUseParakeet = false
            fallbackReason = bootstrapAssessment.failureReason
        }

        return finalizeParakeetDiagnostics(
            requestedKind: requestedKind,
            checks: checks,
            canUseParakeet: canUseParakeet,
            fallbackReason: fallbackReason
        )
    }

    private static func finalizeParakeetDiagnostics(
        requestedKind: STTProviderKind,
        checks: [ProviderHealthCheck],
        canUseParakeet: Bool,
        fallbackReason: String?
    ) -> ProviderRuntimeDiagnostics {
        var finalChecks = checks

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

        let fallbackChecks = appleSpeechReadinessChecks(prefix: "Fallback")
        finalChecks.append(contentsOf: fallbackChecks)
        let fallbackHealthy = fallbackChecks.allSatisfy(\.isPassing)
        let level: ProviderHealthLevel = fallbackHealthy ? .degraded : .unavailable

        return ProviderRuntimeDiagnostics(
            timestamp: Date(),
            requestedKind: requestedKind,
            effectiveKind: .appleSpeech,
            healthLevel: level,
            checks: finalChecks,
            fallbackReason: fallbackReason
        )
    }

    private static func unavailableProviderDiagnostics(
        requestedKind: STTProviderKind,
        implementationTitle: String,
        implementationReason: String,
        fallbackReason: String
    ) -> ProviderRuntimeDiagnostics {
        var checks = [microphoneCheck()]
        checks.append(
            ProviderHealthCheck(
                id: "\(requestedKind.rawValue).implementation",
                title: implementationTitle,
                isPassing: false,
                detail: implementationReason
            )
        )

        let fallbackChecks = appleSpeechReadinessChecks(prefix: "Fallback")
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

    private static func stubDiagnostics(requestedKind: STTProviderKind) -> ProviderRuntimeDiagnostics {
        var checks = [microphoneCheck()]
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
        case .whisper, .openaiAPI:
            // These kinds currently resolve to Apple Speech via diagnostics.
            return AppleSpeechSTTProvider()
        case .stub:
            return StubSTTProvider()
        }
    }

    // MARK: - Shared checks

    private static func parakeetRuntimeBootstrapCheck() -> (
        check: ProviderHealthCheck,
        blocksParakeet: Bool,
        failureReason: String?
    ) {
        let status = ParakeetRuntimeBootstrapManager.shared.statusSnapshot()
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

    private static func microphoneCheck() -> ProviderHealthCheck {
        let micStatus = PermissionDiagnostics.microphoneStatus()
        return ProviderHealthCheck(
            id: "permissions.microphone",
            title: "Microphone Permission",
            isPassing: micStatus.isUsable,
            detail: "Status: \(micStatus.rawValue)"
        )
    }

    private static func appleSpeechReadinessChecks(prefix: String?) -> [ProviderHealthCheck] {
        let namePrefix = prefix.map { "\($0) " } ?? ""
        let idPrefix = prefix.map { "\($0.lowercased())." } ?? ""

        var checks: [ProviderHealthCheck] = []

        let speechStatus = PermissionDiagnostics.speechRecognitionStatus()
        checks.append(
            ProviderHealthCheck(
                id: "\(idPrefix)apple.permission",
                title: "\(namePrefix)Speech Recognition Permission",
                isPassing: speechStatus.isUsable,
                detail: "Status: \(speechStatus.rawValue)"
            )
        )

        let recognizer = SFSpeechRecognizer(locale: .current)
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
