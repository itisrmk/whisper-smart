import Foundation

struct OpenAITranscriptionClient {
    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func transcribe(audioFileURL: URL, apiKey: String, timeout: TimeInterval = 20) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioFileURL)
        let body = try makeBody(boundary: boundary, audioData: audioData, filename: audioFileURL.lastPathComponent)
        request.httpBody = body

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "Invalid response from transcription service.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "No details"
            throw APIError(message: "Cloud transcription failed (\(http.statusCode)): \(bodyText)")
        }

        let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        return decoded.text
    }

    private func makeBody(boundary: String, audioData: Data, filename: String) throws -> Data {
        var data = Data()

        func append(_ string: String) {
            data.append(string.data(using: .utf8)!)
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("gpt-4o-mini-transcribe\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("json\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: audio/m4a\r\n\r\n")
        data.append(audioData)
        append("\r\n")

        append("--\(boundary)--\r\n")

        return data
    }
}

private struct OpenAITranscriptionResponse: Decodable {
    let text: String
}
