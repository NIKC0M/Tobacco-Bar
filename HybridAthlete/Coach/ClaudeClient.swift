import Foundation

/// Thin, dependency-free client for the Anthropic Messages API.
///
/// There is no official Swift SDK, so this speaks raw HTTPS. Two request shapes
/// are supported: a structured one that returns schema-validated JSON (used for
/// the daily coaching pass) and a streaming one that yields text as it arrives
/// (used for the chat tab).
struct ClaudeClient {

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    /// Model choice is deliberate: the daily pass reasons over two weeks of
    /// noisy physiological data against a plan, which is exactly the kind of
    /// judgement the frontier model is worth paying for once a day.
    static let model = "claude-opus-5"

    /// One shared session for the whole app. A coaching pass can legitimately
    /// take a minute on a hard day, hence the generous timeouts.
    static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    var apiKey: String
    var session: URLSession = ClaudeClient.sharedSession

    // MARK: - Structured request

    /// Sends a request constrained by a JSON schema and decodes the reply.
    /// `output_config.format` guarantees the response is a single text block of
    /// schema-valid JSON, so there is no brittle prose-parsing step.
    func structured<T: Decodable>(system: String,
                                  userMessage: String,
                                  schema: [String: Any],
                                  as type: T.Type,
                                  effort: String = "high") async throws -> T {
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "thinking": ["type": "adaptive"],
            "output_config": [
                "effort": effort,
                "format": ["type": "json_schema", "schema": schema]
            ],
            // The system prompt is long and byte-stable across days, so it is
            // worth a cache breakpoint: repeat calls read it instead of
            // re-billing it as fresh input.
            "system": [
                ["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]
            ],
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]

        let data = try await send(body: body)
        let envelope = try JSONDecoder().decode(MessageResponse.self, from: data)

        if envelope.stop_reason == "refusal" {
            throw ClaudeError.refused(envelope.stop_details?.explanation)
        }
        guard let text = envelope.content.first(where: { $0.type == "text" })?.text,
              let payload = text.data(using: .utf8) else {
            throw ClaudeError.emptyResponse
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(T.self, from: payload)
        } catch {
            throw ClaudeError.decoding(error.localizedDescription, raw: String(text.prefix(800)))
        }
    }

    // MARK: - Streaming chat

    /// Streams a plain-text reply. Used for follow-up questions where the
    /// athlete wants a conversation, not a plan mutation.
    func streamChat(system: String,
                    messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body: [String: Any] = [
                        "model": Self.model,
                        "max_tokens": 8000,
                        "stream": true,
                        "thinking": ["type": "adaptive"],
                        "output_config": ["effort": "medium"],
                        "system": [
                            ["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]
                        ],
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] }
                    ]

                    var request = try makeRequest(body: body)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw ClaudeError.http(status: http.statusCode, body: "")
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { continue }
                        guard let event = try? JSONDecoder().decode(StreamEvent.self, from: data) else { continue }

                        if event.type == "content_block_delta",
                           event.delta?.type == "text_delta",
                           let chunk = event.delta?.text {
                            continuation.yield(chunk)
                        }
                        if event.type == "message_stop" { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Plumbing

    private func makeRequest(body: [String: Any]) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ClaudeError.missingAPIKey }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    private func send(body: [String: Any]) async throws -> Data {
        let request = try makeRequest(body: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }

        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw ClaudeError.missingAPIKey
        case 429:
            throw ClaudeError.rateLimited
        default:
            let detail = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error.message
                ?? String(data: data.prefix(400), encoding: .utf8)
                ?? ""
            throw ClaudeError.http(status: http.statusCode, body: detail)
        }
    }

    // MARK: - Wire types

    struct ChatTurn: Codable, Hashable, Identifiable {
        enum Role: String, Codable { case user, assistant }
        var id: UUID = UUID()
        var role: Role
        var text: String
    }

    private struct MessageResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct StopDetails: Decodable {
            let type: String?
            let category: String?
            let explanation: String?
        }
        let content: [Block]
        let stop_reason: String?
        let stop_details: StopDetails?
    }

    private struct StreamEvent: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
        }
        let type: String
        let delta: Delta?
    }

    private struct APIErrorEnvelope: Decodable {
        struct Body: Decodable { let message: String }
        let error: Body
    }
}

enum ClaudeError: LocalizedError {
    case missingAPIKey
    case rateLimited
    case refused(String?)
    case emptyResponse
    case decoding(String, raw: String)
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No valid Anthropic API key. Add one in Settings — the app keeps working on its own rules without it."
        case .rateLimited:
            return "Anthropic rate limit hit. Try the coaching pass again in a minute."
        case .refused(let explanation):
            return "Claude declined this request. \(explanation ?? "")"
        case .emptyResponse:
            return "Claude returned an empty response."
        case .decoding(let detail, _):
            return "Couldn't read Claude's reply: \(detail)"
        case .http(let status, let body):
            return "Anthropic API error \(status). \(body)"
        }
    }
}
