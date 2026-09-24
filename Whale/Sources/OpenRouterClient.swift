import Foundation

struct AIActionImage: Sendable, Equatable {
    let data: Data
    let mediaType: String
}

enum AIActionError: LocalizedError {
    case missingAPIKey
    case notReady(String)
    case malformedResponse
    case requestFailed(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add an OpenRouter API key in Settings > AI Actions"
        case .notReady(let reason): return reason
        case .malformedResponse: return "OpenRouter returned an invalid response"
        case .requestFailed(let reason): return reason
        case .emptyResult: return "The AI Action returned no text"
        }
    }
}

/// Runs an AI Action as a single OpenRouter chat completion. One request per
/// run, no retries — the coordinator owns the timeout and cancellation.
@MainActor
final class OpenRouterClient {
    static let model = "openai/gpt-5.6-luna"
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    private let session: URLSession
    private var activeRuns: [UUID: Task<String, Error>] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    var hasAPIKey: Bool {
        (try? KeychainStore.string(for: .openRouterAPIKey))?.isEmpty == false
    }

    func perform(runID: UUID, request: AIActionRequest) async throws -> String {
        guard let apiKey = try KeychainStore.string(for: .openRouterAPIKey), !apiKey.isEmpty else {
            throw AIActionError.missingAPIKey
        }
        guard activeRuns[runID] == nil else {
            throw AIActionError.notReady("This AI Action is already running")
        }

        let urlRequest = try Self.urlRequest(for: request, apiKey: apiKey)
        let session = session
        let task = Task { try await Self.send(urlRequest, session: session) }
        activeRuns[runID] = task
        defer { activeRuns.removeValue(forKey: runID) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func abort(runID: UUID) async {
        activeRuns.removeValue(forKey: runID)?.cancel()
    }

    static func requestBody(for request: AIActionRequest) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": request.prompt]]
        content += request.images.map {
            [
                "type": "image_url",
                "image_url": ["url": "data:\($0.mediaType);base64,\($0.data.base64EncodedString())"],
            ]
        }
        return [
            "model": model,
            "messages": [["role": "user", "content": content]],
            // Matches the "thinking off" setting AI Actions ran with under Pi.
            "reasoning": ["effort": "none"],
            "stream": false,
        ]
    }

    /// Pulls the reply text out of a chat completion, or the provider's own
    /// error message so `OpenRouterFailure` can classify it.
    static func resultText(from data: Data, statusCode: Int) throws -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let error = object?["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "The provider request failed"
            let code = (error["code"] as? Int).map(String.init) ?? String(statusCode)
            throw AIActionError.requestFailed("OpenRouter error \(code): \(message)")
        }
        guard (200..<300).contains(statusCode) else {
            throw AIActionError.requestFailed("OpenRouter error \(statusCode)")
        }
        guard let choices = object?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AIActionError.malformedResponse
        }
        let text = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIActionError.emptyResult }
        return text
    }

    private static func urlRequest(for request: AIActionRequest, apiKey: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("https://github.com/sumitrk/whale-app", forHTTPHeaderField: "HTTP-Referer")
        urlRequest.setValue("Whale", forHTTPHeaderField: "X-Title")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody(for: request))
        return urlRequest
    }

    private static func send(_ request: URLRequest, session: URLSession) async throws -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try resultText(from: data, statusCode: statusCode)
    }
}
