import AVFoundation
import Foundation

final class OpenAIWhisperAPISTTProvider: STTProvider {
    let displayName = "OpenAI Whisper API"

    var onResult: ((STTResult) -> Void)?
    var onError: ((STTError) -> Void)?

    private let stateLock = NSLock()
    private let samplesLock = NSLock()
    private var sessionActive = false
    private var requestInFlight = false
    /// Captured audio as int16: the WAV body is int16 anyway, so converting
    /// at the tap halves what a recording costs while it is resident.
    private var capturedSamples: [Int16] = []
    /// Set once the buffer has hit the capture cap, so it is logged once.
    private var captureCapped = false
    /// Bumped by `cancelSession()`; responses from an older session are dropped.
    private var generation = 0

    func feedAudio(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard currentSessionActive else { return }
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let chunk = UnsafeBufferPointer(start: channelData[0], count: frameCount)
        let converted = AudioWAVEncoding.int16Samples(from: chunk)
        samplesLock.lock()
        appendCappedLocked(converted)
        samplesLock.unlock()
    }

    func beginSession() throws {
        guard DictationProviderPolicy.cloudFallbackEnabled else {
            throw STTError.providerError(message: "Cloud provider is disabled. Turn on 'Allow cloud fallback' in Settings -> Provider.")
        }

        let key = DictationProviderPolicy.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw STTError.authenticationFailed(underlying: nil)
        }

        let endpoint = DictationProviderPolicy.resolvedOpenAIEndpointConfiguration()
        if let endpointError = DictationProviderPolicy.validateOpenAIEndpoint(
            baseURL: endpoint.baseURL,
            model: endpoint.model
        ) {
            throw STTError.providerError(message: endpointError)
        }

        if currentSessionActive {
            throw STTError.providerError(message: "Cloud session already active.")
        }
        if currentRequestInFlight {
            throw STTError.providerError(message: "Previous cloud transcription request is still running.")
        }

        samplesLock.lock()
        resetCaptureBufferLocked()
        samplesLock.unlock()
        updateSessionActive(true)
    }

    func cancelSession() {
        stateLock.lock()
        sessionActive = false
        requestInFlight = false
        generation += 1
        stateLock.unlock()

        samplesLock.lock()
        resetCaptureBufferLocked()
        samplesLock.unlock()
    }

    func endSession() {
        guard currentSessionActive else { return }
        updateSessionActive(false)
        updateRequestInFlight(true)
        let gen = currentGeneration

        let samples = snapshotAndClearSamples()
        guard !samples.isEmpty else {
            updateRequestInFlight(false)
            onError?(.providerError(message: "No audio captured for cloud transcription."))
            return
        }

        Task {
            let result = await transcribe(samples: samples)
            await MainActor.run {
                guard gen == self.currentGeneration else { return }
                self.updateRequestInFlight(false)
                switch result {
                case .success(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        self.onError?(.providerError(message: "Cloud transcription returned empty text."))
                        return
                    }
                    self.onResult?(STTResult(text: trimmed, isPartial: false, confidence: nil))
                case .failure(let error):
                    self.onError?(error)
                }
            }
        }
    }

    private func transcribe(samples: [Int16]) async -> Result<String, STTError> {
        do {
            let apiKey = DictationProviderPolicy.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else {
                return .failure(.authenticationFailed(underlying: nil))
            }

            let endpoint = DictationProviderPolicy.resolvedOpenAIEndpointConfiguration()
            if let endpointError = DictationProviderPolicy.validateOpenAIEndpoint(
                baseURL: endpoint.baseURL,
                model: endpoint.model
            ) {
                return .failure(.providerError(message: endpointError))
            }
            guard let transcriptionURL = endpoint.transcriptionURL else {
                return .failure(.providerError(message: "Cloud endpoint could not be resolved."))
            }

            let wav = AudioWAVEncoding.make16BitMonoWAV(samples: samples, sampleRate: 16_000)
            let boundary = "Boundary-\(UUID().uuidString)"

            var request = URLRequest(url: transcriptionURL)
            request.httpMethod = "POST"
            // Bound the request so a stalled network never outlives the state
            // machine's transcription timeout and leaks a hung task.
            request.timeoutInterval = 30
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            let customPrompt = DictationWorkflowSettings.customAIInstructions
                .trimmingCharacters(in: .whitespacesAndNewlines)
            request.httpBody = makeMultipartBody(
                boundary: boundary,
                wavData: wav,
                model: endpoint.model,
                prompt: customPrompt.isEmpty ? nil : customPrompt
            )

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                return .failure(.networkError(underlying: error))
            }

            guard let http = response as? HTTPURLResponse else {
                return .failure(.providerError(message: "Invalid response from OpenAI transcription API."))
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                if http.statusCode == 401 || http.statusCode == 403 {
                    return .failure(.authenticationFailed(underlying: NSError(domain: "OpenAI", code: Int(http.statusCode), userInfo: [NSLocalizedDescriptionKey: body])))
                }
                return .failure(.providerError(message: "OpenAI API error \(http.statusCode): \(body)"))
            }

            let decoded = try JSONDecoder().decode(OpenAITranscriptResponse.self, from: data)
            return .success(decoded.text)
        } catch {
            return .failure(.providerError(message: "Failed to decode OpenAI transcription response: \(error.localizedDescription)"))
        }
    }

    private func makeMultipartBody(boundary: String, wavData: Data, model: String, prompt: String?) -> Data {
        var body = Data()

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append(model + "\r\n")

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.append("json\r\n")

        if let prompt, !prompt.isEmpty {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            body.append(prompt + "\r\n")
        }

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        body.append("\r\n")

        body.append("--\(boundary)--\r\n")
        return body
    }

    private var currentSessionActive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return sessionActive
    }

    private var currentRequestInFlight: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return requestInFlight
    }

    private var currentGeneration: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return generation
    }

    private func updateSessionActive(_ value: Bool) {
        stateLock.lock(); sessionActive = value; stateLock.unlock()
    }

    private func updateRequestInFlight(_ value: Bool) {
        stateLock.lock(); requestInFlight = value; stateLock.unlock()
    }

    private func snapshotAndClearSamples() -> [Int16] {
        samplesLock.lock(); defer { samplesLock.unlock() }
        let snapshot = capturedSamples
        // Assigning a fresh array hands sole ownership to `snapshot`;
        // `removeAll(keepingCapacity:)` would copy the whole recording just
        // to empty the copy, then strand that capacity indefinitely.
        capturedSamples = []
        captureCapped = false
        return snapshot
    }

    /// Appends to the session buffer, stopping at the capture cap. Caller
    /// holds `samplesLock`.
    private func appendCappedLocked(_ samples: [Int16]) {
        let room = STTCaptureLimits.maxSessionSamples - capturedSamples.count
        guard room > 0 else {
            if !captureCapped {
                captureCapped = true
                NSLog("Cloud capture hit the session cap; dropping further audio")
            }
            return
        }
        if samples.count <= room {
            capturedSamples.append(contentsOf: samples)
        } else {
            capturedSamples.append(contentsOf: samples[..<room])
        }
    }

    /// Empties the session buffer, releasing storage once a recording has
    /// grown past the reuse ceiling. Caller holds `samplesLock`.
    private func resetCaptureBufferLocked() {
        if capturedSamples.capacity > STTCaptureLimits.bufferReuseCeiling {
            capturedSamples = []
        } else {
            capturedSamples.removeAll(keepingCapacity: true)
        }
        captureCapped = false
    }
}

private struct OpenAITranscriptResponse: Decodable {
    let text: String
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
