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

private func runParakeetSidecarMetadataSmoke() throws {
    let source = ModelVariant.parakeetCTC06B.configuredSource
    try expect(source?.modelDataURL != nil, "Parakeet source should include an ONNX sidecar URL.")

    let expectedBytes = source?.modelDataExpectedSizeBytes ?? 0
    try expect(expectedBytes > 2_000_000_000, "Parakeet sidecar expected size should be set to a multi-GB value.")

    print("✓ Parakeet sidecar metadata smoke passed")
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
        tokenizerFilename: "vocab.txt",
        modelExpectedSizeBytes: nil,
        modelDataExpectedSizeBytes: nil,
        tokenizerExpectedSizeBytes: 100_000,
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

@main
struct QASmokeMain {
    static func main() {
        do {
            try runStateMachineSmoke()
            try runResolverSmoke()
            try runDownloadCompletionTransitionSmoke()
            try runLegacyCanarySourceMigrationSmoke()
            try runParakeetSidecarMetadataSmoke()
            try runTokenizerValidationSmoke()
            print("\nAll QA smoke checks passed.")
        } catch {
            fputs("Smoke test failure: \(error)\n", stderr)
            exit(1)
        }
    }
}
