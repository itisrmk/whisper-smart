import Foundation
import AVFoundation
import Speech

private final class MockHotkeyMonitor: HotkeyMonitoring {
    var onHoldStarted: (() -> Void)?
    var onHoldEnded: (() -> Void)?
    var onStartFailed: ((HotkeyMonitorError) -> Void)?

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() { startCallCount += 1 }
    func stop() { stopCallCount += 1 }

    func triggerHoldStart() { onHoldStarted?() }
    func triggerHoldEnd() { onHoldEnded?() }
}

private final class MockAudioCapture: AudioCapturing {
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var onError: ((Error) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onInterruption: ((AudioCaptureService.InterruptionReason) -> Void)?
    var inputDeviceUID: String?

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() throws { startCallCount += 1 }
    func stop() { stopCallCount += 1 }
}

private final class MockInjector: TextInjecting {
    private(set) var injectedTexts: [String] = []
    func inject(text: String) { injectedTexts.append(text) }
}

private final class MockSTTProvider: STTProvider {
    let displayName: String
    var onResult: ((STTResult) -> Void)?
    var onError: ((STTError) -> Void)?
    private(set) var beginSessionCallCount = 0
    private(set) var endSessionCallCount = 0

    init(displayName: String = "Mock") {
        self.displayName = displayName
    }

    func feedAudio(buffer: AVAudioPCMBuffer, time: AVAudioTime) {}
    func beginSession() throws { beginSessionCallCount += 1 }
    func endSession() { endSessionCallCount += 1 }

    func emitFinal(_ text: String) {
        onResult?(STTResult(text: text, isPartial: false, confidence: nil))
    }
}

private enum SmokeFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String {
        switch self {
        case .assertion(let msg): return msg
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeFailure.assertion(message) }
}

private func runStateMachineSmoke() throws {
    let hotkey = MockHotkeyMonitor()
    let audio = MockAudioCapture()
    let stt = MockSTTProvider(displayName: "Primary")
    let injector = MockInjector()

    let machine = DictationStateMachine(
        hotkeyMonitor: hotkey,
        audioCapture: audio,
        sttProvider: stt,
        injector: injector,
        postProcessingPipeline: TranscriptPostProcessingPipeline(
            processors: [BaselineFillerWordTrimmer(), BaselineSpacingAndPunctuationNormalizer()]
        ),
        commandModeRouter: FeatureFlaggedCommandModeRouter(isEnabled: { false }),
        microphoneAuthorizationStatus: { .authorized },
        requestMicrophoneAccess: { completion in completion(true) }
    )

    var observedStates: [DictationStateMachine.State] = []
    machine.onStateChange = { observedStates.append($0) }

    machine.activate()
    try expect(hotkey.startCallCount == 1, "activate() should start hotkey monitor")

    hotkey.triggerHoldStart()
    try expect(machine.state == .recording, "hold start should enter recording")

    hotkey.triggerHoldEnd()
    try expect(machine.state == .transcribing, "hold end should enter transcribing")

    stt.emitFinal("um   Hello,world")
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    try expect(machine.state == .success, "final result should enter success")
    try expect(injector.injectedTexts == ["Hello, world"], "final text should be post-processed + injected")

    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    try expect(machine.state == .idle, "success state should auto-reset to idle")

    let secondProvider = MockSTTProvider(displayName: "Secondary")
    machine.replaceProvider(secondProvider)
    stt.emitFinal("stale result")
    try expect(injector.injectedTexts.count == 1, "stale provider callbacks must be ignored after replaceProvider")

    print("✓ DictationStateMachine smoke passed")
    print("  states: \(observedStates)")
}

private func runResolverSmoke() throws {
    let noCloudEnv = STTProviderResolver.Environment(
        microphoneStatus: { .granted },
        speechRecognitionStatus: { .granted },
        speechRecognizerFactory: { nil },
        cloudFallbackEnabled: { false },
        openAIAPIKey: { "" },
        parakeetBootstrapStatus: {
            ParakeetRuntimeBootstrapStatus(
                phase: .ready,
                detail: "ready",
                runtimeDirectory: nil,
                pythonCommand: nil,
                timestamp: Date()
            )
        }
    )

    let fallback = STTProviderResolver.diagnostics(for: .openaiAPI, environment: noCloudEnv)
    try expect(fallback.requestedKind == .openaiAPI, "requested kind must be openaiAPI")
    try expect(fallback.effectiveKind == .appleSpeech, "openai should fallback to Apple when cloud fallback is disabled")
    try expect(fallback.fallbackReason?.isEmpty == false, "fallback should provide reason")

    let cloudEnv = STTProviderResolver.Environment(
        microphoneStatus: { .granted },
        speechRecognitionStatus: { .granted },
        speechRecognizerFactory: { nil },
        cloudFallbackEnabled: { true },
        openAIAPIKey: { "sk-test-key" },
        parakeetBootstrapStatus: noCloudEnv.parakeetBootstrapStatus
    )

    let ready = STTProviderResolver.diagnostics(for: .openaiAPI, environment: cloudEnv)
    try expect(ready.effectiveKind == .openaiAPI, "openai should remain selected when opt-in + key are present")
    try expect(ready.fallbackReason == nil, "non-fallback diagnostics should not carry fallbackReason")

    print("✓ STTProviderResolver diagnostics smoke passed")
    print("  fallback health=\(fallback.healthLevel.rawValue), ready health=\(ready.healthLevel.rawValue)")
}

private func runParakeetNoSilentFallbackSmoke() throws {
    let env = STTProviderResolver.Environment(
        microphoneStatus: { .granted },
        speechRecognitionStatus: { .granted },
        speechRecognizerFactory: { SFSpeechRecognizer(locale: Locale(identifier: "en-US")) },
        cloudFallbackEnabled: { false },
        openAIAPIKey: { "" },
        parakeetBootstrapStatus: {
            ParakeetRuntimeBootstrapStatus(
                phase: .bootstrapping,
                detail: "bootstrapping",
                runtimeDirectory: nil,
                pythonCommand: nil,
                timestamp: Date()
            )
        }
    )

    let diagnostics = STTProviderResolver.diagnostics(for: .parakeet, environment: env)
    try expect(
        diagnostics.effectiveKind == .parakeet,
        "Parakeet should remain selected even while setup is in progress (no silent Apple fallback)."
    )
    try expect(
        diagnostics.fallbackReason == nil,
        "Parakeet diagnostics should not expose fallbackReason when effective kind remains Parakeet."
    )

    print("✓ Parakeet no-silent-fallback smoke passed")
}


private func runDownloadCompletionTransitionSmoke() throws {
    let state = ModelDownloadState(variant: .parakeetCTC06B)
    state.transitionToDownloading()
    state.updateProgress(1)
    state.transitionToFailed(message: "Synthetic finalization failure")

    if case .downloading = state.phase {
        throw SmokeFailure.assertion("Download state should leave downloading once completion resolves (ready/failed).")
    }

    print("✓ Download completion transition smoke passed")
}

private func runLegacyCanarySourceMigrationSmoke() throws {
    let store = ParakeetModelSourceConfigurationStore.shared
    let defaults = UserDefaults.standard
    let variantID = ParakeetModelCatalog.ctc06BVariantID
    let selectedSourceKey = "parakeet.modelSource.\(variantID).selected"

    let previousValue = defaults.string(forKey: selectedSourceKey)
    defaults.set("hf_canary_qwen_2_5b_safetensors", forKey: selectedSourceKey)

    defer {
        if let previousValue {
            defaults.set(previousValue, forKey: selectedSourceKey)
        } else {
            defaults.removeObject(forKey: selectedSourceKey)
        }
        _ = store.selectSource(id: "hf_parakeet_tdt06b_v3_onnx", for: variantID)
    }

    let variant = ModelVariant.parakeetCTC06B
    try expect(variant.configuredSource?.selectedSourceID == "hf_parakeet_tdt06b_v3_onnx", "Legacy Canary source id should auto-fallback to the recommended Parakeet source")
    try expect(variant.hasDownloadSource == true, "Parakeet should remain downloadable when legacy Canary source id is persisted")
    try expect(
        variant.downloadUnavailableReason == nil,
        "Legacy Canary source selection should not block download"
    )

    print("✓ Legacy Canary source migration smoke passed")
}

private func runParakeetArtifactMetadataSmoke() throws {
    let source = ModelVariant.parakeetCTC06B.configuredSource
    try expect(source?.modelDataURL == nil, "Parakeet source should use int8 encoder artifact without external .data sidecar.")
    try expect(source?.decoderJointURL != nil, "Parakeet source should include decoder_joint artifact URL.")
    try expect(source?.configURL != nil, "Parakeet source should include config.json artifact URL.")
    try expect(source?.nemoNormalizerURL != nil, "Parakeet source should include nemo128 artifact URL.")

    let expectedEncoderBytes = source?.modelExpectedSizeBytes ?? 0
    let expectedDecoderBytes = source?.decoderJointExpectedSizeBytes ?? 0
    try expect(expectedEncoderBytes > 500_000_000, "Parakeet int8 encoder expected size should be set.")
    try expect(expectedDecoderBytes > 10_000_000, "Parakeet int8 decoder expected size should be set.")

    print("✓ Parakeet artifact metadata smoke passed")
}

private func runTokenizerValidationSmoke() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("qa-smoke-tokenizer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let tokenizerURL = tempDir.appendingPathComponent("vocab.txt")
    var payload = "<blank>\n"
    payload += String(repeating: "token\n", count: 9)

    let targetSize = Int(TokenizerArtifactValidator.knownParakeetVocabSizeBytes)
    if payload.utf8.count < targetSize {
        payload += String(repeating: "a", count: targetSize - payload.utf8.count)
    }
    try payload.write(to: tokenizerURL, atomically: true, encoding: .utf8)

    let source = ParakeetResolvedModelSource(
        selectedSourceID: "hf_parakeet_tdt06b_v3_onnx",
        selectedSourceName: "Hugging Face",
        isBuiltInSource: true,
        modelURL: nil,
        modelDataURL: nil,
        tokenizerURL: URL(string: "https://example.com/vocab.txt"),
        decoderJointURL: nil,
        configURL: nil,
        nemoNormalizerURL: nil,
        tokenizerFilename: "vocab.txt",
        decoderJointFilename: nil,
        configFilename: nil,
        nemoNormalizerFilename: nil,
        modelExpectedSizeBytes: nil,
        modelDataExpectedSizeBytes: nil,
        tokenizerExpectedSizeBytes: 100_000,
        decoderJointExpectedSizeBytes: nil,
        configExpectedSizeBytes: nil,
        nemoNormalizerExpectedSizeBytes: nil,
        modelSHA256: nil,
        tokenizerSHA256: nil,
        error: nil,
        runtimeCompatibility: .runnable,
        availableSources: []
    )

    let validationError = TokenizerArtifactValidator.validate(at: tokenizerURL, source: source)
    try expect(validationError == nil, "Tokenizer validator should accept current known Parakeet vocab size (~93,939 bytes)")

    print("✓ Tokenizer validator smoke passed")
}

private func runOpenAIAPIKeyNormalizationSmoke() throws {
    let normalized = DictationProviderPolicy.normalizedOpenAIAPIKey(
        "  Bearer  \"sk-test-abc\n123\" \u{200B}"
    )
    try expect(
        normalized == "sk-test-abc123",
        "OpenAI API key normalization should strip paste artifacts, quotes, and bearer prefix."
    )

    let defaults = UserDefaults.standard
    let legacyKey = "provider.openAI.apiKey"
    let previousLegacyRaw = defaults.string(forKey: legacyKey)
    let environmentKey = DictationProviderPolicy.normalizedOpenAIAPIKey(
        ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    )
    let previousEffective = DictationProviderPolicy.openAIAPIKey
    defer {
        if let previousLegacyRaw {
            defaults.set(previousLegacyRaw, forKey: legacyKey)
        } else {
            defaults.removeObject(forKey: legacyKey)
        }

        if !previousEffective.isEmpty, previousEffective != environmentKey {
            DictationProviderPolicy.openAIAPIKey = previousEffective
        } else {
            DictationProviderPolicy.openAIAPIKey = ""
        }
    }

    DictationProviderPolicy.openAIAPIKey = " Bearer sk-live-\nxyz "
    try expect(
        DictationProviderPolicy.openAIAPIKey == "sk-live-xyz",
        "OpenAI API key should persist in normalized form."
    )

    DictationProviderPolicy.openAIAPIKey = " \n "
    let effectiveAfterClear = DictationProviderPolicy.openAIAPIKey
    if environmentKey.isEmpty {
        try expect(
            effectiveAfterClear.isEmpty,
            "Empty OpenAI API key should clear persisted storage."
        )
    } else {
        try expect(
            effectiveAfterClear == environmentKey,
            "When env key is present, empty persisted key should fall back to environment value."
        )
    }

    try expect(
        DictationProviderPolicy.validateOpenAIAPIKey("sk-proj-abcdefghijklmnopqrstuvwxyz123456") == .valid,
        "Expected modern sk-proj key format to validate."
    )
    try expect(
        DictationProviderPolicy.validateOpenAIAPIKey("sk-short") == .suspiciousPrefix,
        "Expected short sk- key to be flagged as suspicious."
    )
    switch DictationProviderPolicy.validateOpenAIAPIKey("abc!!") {
    case .malformed:
        break
    default:
        throw SmokeFailure.assertion("Expected invalid character key to be malformed.")
    }

    print("✓ OpenAI API key normalization smoke passed")
}

private func runGlobalWritingStyleFallbackSmoke() throws {
    let defaults = UserDefaults.standard
    let key = "workflow.defaultWritingStyle"
    let previousRaw = defaults.string(forKey: key)
    defer {
        if let previousRaw {
            defaults.set(previousRaw, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    DictationWorkflowSettings.defaultWritingStyle = .concise

    let input = "Please note that this is kind of a sample"
    let output = AppStyleProfileProcessor().process(
        input,
        context: TranscriptPostProcessingContext(isFinal: true, timestamp: Date())
    )

    try expect(
        output.lowercased() == "this is a sample",
        "Global writing style fallback should apply concise cleanup when no per-app override exists."
    )

    print("✓ Global writing style fallback smoke passed")
}

private func runDomainPresetFallbackSmoke() throws {
    let defaults = UserDefaults.standard
    let writingStyleKey = "workflow.defaultWritingStyle"
    let domainPresetKey = "workflow.defaultDomainPreset"
    let previousWritingStyle = defaults.string(forKey: writingStyleKey)
    let previousDomainPreset = defaults.string(forKey: domainPresetKey)
    defer {
        if let previousWritingStyle {
            defaults.set(previousWritingStyle, forKey: writingStyleKey)
        } else {
            defaults.removeObject(forKey: writingStyleKey)
        }
        if let previousDomainPreset {
            defaults.set(previousDomainPreset, forKey: domainPresetKey)
        } else {
            defaults.removeObject(forKey: domainPresetKey)
        }
    }

    DictationWorkflowSettings.defaultWritingStyle = .neutral
    DictationWorkflowSettings.defaultDomainPreset = .notes

    let conciseInput = "Please note that this is kind of a summary"
    let conciseOutput = AppStyleProfileProcessor().process(
        conciseInput,
        context: TranscriptPostProcessingContext(isFinal: true, timestamp: Date())
    )
    try expect(
        conciseOutput.lowercased() == "this is a summary",
        "Notes domain preset should map to concise fallback style."
    )

    DictationWorkflowSettings.defaultDomainPreset = .coding
    let codingInput = "open paren close paren"
    let codingOutput = AppStyleProfileProcessor().process(
        codingInput,
        context: TranscriptPostProcessingContext(isFinal: true, timestamp: Date())
    )
    let codingCompacted = codingOutput.replacingOccurrences(of: " ", with: "")
    try expect(
        codingCompacted.contains("()"),
        "Coding domain preset should apply developer symbol transforms."
    )

    print("✓ Domain preset fallback smoke passed")
}

@main
struct QASmokeMain {
    static func main() {
        do {
            try runStateMachineSmoke()
            try runResolverSmoke()
            try runParakeetNoSilentFallbackSmoke()
            try runDownloadCompletionTransitionSmoke()
            try runLegacyCanarySourceMigrationSmoke()
            try runParakeetArtifactMetadataSmoke()
            try runTokenizerValidationSmoke()
            try runOpenAIAPIKeyNormalizationSmoke()
            try runGlobalWritingStyleFallbackSmoke()
            try runDomainPresetFallbackSmoke()
            print("\nAll QA smoke checks passed.")
        } catch {
            fputs("Smoke test failure: \(error)\n", stderr)
            exit(1)
        }
    }
}
