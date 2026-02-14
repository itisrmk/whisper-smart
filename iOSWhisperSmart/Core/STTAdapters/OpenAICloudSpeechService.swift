import Foundation
import AVFoundation

final class OpenAICloudSpeechService: NSObject, SpeechToTextService {
    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private let client: OpenAITranscriptionClient
    private let apiKeyProvider: () -> String?

    init(client: OpenAITranscriptionClient = OpenAITranscriptionClient(), apiKeyProvider: @escaping () -> String?) {
        self.client = client
        self.apiKeyProvider = apiKeyProvider
        super.init()
    }

    func requestPermissions() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func startRecognition() throws {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw NSError(domain: "OpenAICloudSpeechService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing OpenAI API key in Settings."])
        }

        stopRecordingOnly()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-recording-\(UUID().uuidString).m4a")
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.prepareToRecord()
        recorder.record()
        self.recorder = recorder

        onPartialResult?("Recording for cloud transcription…")
    }

    func stopRecognition() {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            onError?("Missing OpenAI API key in Settings.")
            stopRecordingOnly()
            return
        }

        recorder?.stop()
        let fileURL = recordingURL
        stopRecordingOnly()

        guard let fileURL else {
            onError?("No recording was captured.")
            return
        }

        onPartialResult?("Uploading audio securely to OpenAI…")

        Task {
            do {
                let text = try await client.transcribe(audioFileURL: fileURL, apiKey: apiKey)
                await MainActor.run {
                    self.onFinalResult?(text)
                }
            } catch {
                await MainActor.run {
                    self.onError?(error.localizedDescription)
                }
            }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func stopRecordingOnly() {
        recorder?.stop()
        recorder = nil
        recordingURL = nil
    }
}
