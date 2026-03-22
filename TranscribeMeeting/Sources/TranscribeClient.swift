import Foundation

struct TranscribeClient {
    private let baseURL = URL(string: "http://127.0.0.1:8765")!

    // MARK: - Transcribe

    /// POST /transcribe — send WAV file, get transcript back
    func transcribe(wavURL: URL, model: String) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("transcribe")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        var body = Data()
        // — file field —
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: wavURL))
        body.append("\r\n")
        // — model field —
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append(model)
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown error"
            throw ClientError.serverError(msg)
        }

        let decoded = try JSONDecoder().decode(TranscribeResponse.self, from: data)
        return decoded.transcript
    }

    // MARK: - Summarise

    /// POST /summarise — send transcript, get cleaned text + summary
    func summarise(transcript: String, apiKey: String,
                   provider: String = "anthropic") async throws -> SummariseResponse {
        let endpoint = baseURL.appendingPathComponent("summarise")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = SummariseRequest(transcript: transcript, api_key: apiKey, provider: provider)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown error"
            throw ClientError.serverError(msg)
        }

        return try JSONDecoder().decode(SummariseResponse.self, from: data)
    }
}

// MARK: - Codable types

private struct TranscribeResponse: Decodable { let transcript: String }

private struct SummariseRequest: Encodable {
    let transcript: String
    let api_key: String
    let provider: String
}

struct SummariseResponse: Decodable {
    let cleaned_transcript: String
    let summary: String
}

// MARK: - Errors

enum ClientError: LocalizedError {
    case serverError(String)
    var errorDescription: String? {
        if case .serverError(let msg) = self { return "Server error: \(msg)" }
        return nil
    }
}

// MARK: - Data helper

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
