import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A function the model asked to have run: its id (the answer must quote it), the tool's name, and the arguments as JSON text.
public struct AgentToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: String
    public init(id: String, name: String, arguments: String) { self.id = id; self.name = name; self.arguments = arguments }
}

/// One turn of the conversation.
///
/// `.tool` is either the answer to a tool call (on the wire, with `toolCallID`) or, in what the panel shows, a one-line note of what the
/// agent did. An assistant turn may carry `toolCalls` instead of, or as well as, text.
public struct AgentMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public var role: Role
    public var text: String
    public var toolCalls: [AgentToolCall] = []
    public var toolCallID: String?
    /// For a `.tool` line the panel shows: the action did not work.
    public var failed = false
    public init(_ role: Role, _ text: String) { self.role = role; self.text = text }
    public init(toolResult text: String, for id: String) { role = .tool; self.text = text; toolCallID = id }
    public init(assistant text: String, toolCalls: [AgentToolCall]) { role = .assistant; self.text = text; self.toolCalls = toolCalls }
}

/// What the service answered: text, calls to run, or both.
public struct AgentCompletion: Equatable, Sendable {
    public var text: String
    public var toolCalls: [AgentToolCall]
    /// The service would not take tools, so this answer was asked for without them; `refusal` is what it said.
    public var toolsRefused = false
    public var refusal = ""
    /// Set when the service wanted reasoning turned off to take tools; later requests to this model send it from the start.
    public var reasoningEffort: String?
}

public enum AgentError: Error, LocalizedError, Equatable {
    case notSafe(String)
    case noKey(String)
    case badURL(String)
    case server(Int, String)
    case network(String)
    case badReply

    public var errorDescription: String? {
        switch self {
        case .notSafe(let host): return "Won't send a key to \(host) over an unencrypted connection. Use an https address (http is only allowed for this computer)."
        case .noKey(let name): return "Enter your \(name) API key first."
        case .badURL(let text): return "\"\(text)\" is not a web address."
        case .server(let status, let message): return message.isEmpty ? "The service answered with an error (\(status))." : "\(message) (\(status))"
        case .network(let message): return "Could not reach the service: \(message)"
        case .badReply: return "The service sent an answer this app does not understand."
        }
    }
}

/// Talks to an OpenAI-style chat-completions endpoint.
///
/// The key is sent only as a bearer token, only over https (or to this computer), and the connection refuses to follow a redirect, so a
/// key cannot be handed on to another host. Nothing is cached and no cookies are kept (an ephemeral session).
public struct AgentClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = AgentClient.makeSession()) { self.session = session }

    /// A session that follows no redirects and keeps nothing.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// Whether a key may be sent to `url`: https anywhere, or http to this computer alone.
    public static func isSafe(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
        default: return false
        }
    }

    /// `{base}/chat/completions`, or nil if `base` is not a web address.
    public static func endpoint(baseURL: String) -> URL? { endpoint(baseURL: baseURL, path: "chat/completions") }

    /// `{base}/{path}`, or nil if `base` is not a web address.
    static func endpoint(baseURL: String, path: String) -> URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text + "/" + path), url.host != nil, url.scheme != nil else { return nil }
        return url
    }

    /// A request to `path` under `baseURL`, with the key as a bearer token: refused if that would send a key somewhere unsafe.
    private func request(baseURL: String, path: String, method: String, key: String?, body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = Self.endpoint(baseURL: baseURL, path: path) else { throw AgentError.badURL(baseURL) }
        // The key is only ever sent somewhere safe; a service with no key (a local model) is not held to it.
        if key != nil, !Self.isSafe(url) { throw AgentError.notSafe(url.host ?? baseURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }

    /// Sends it and returns the JSON object that came back, or the service's own reason it did not.
    private func send(_ request: URLRequest, key: String?) async throws -> [String: Any]? {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw AgentError.network(Self.redact(error.localizedDescription, key: key)) }

        guard let http = response as? HTTPURLResponse else { throw AgentError.badReply }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            // Services put the reason in `error.message` (OpenAI and most of the rest) or `error` as a string.
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? (json?["error"] as? String) ?? ""
            throw AgentError.server(http.statusCode, Self.redact(message, key: key))
        }
        return json
    }

    /// The models the service offers, from `GET {base}/models` (OpenAI and the services that copy it answer `{"data": [{"id": …}]}`).
    ///
    /// What is not a chat model (embeddings, speech, images, moderation) is left out, unless that would leave nothing.
    public func models(baseURL: String, key: String?) async throws -> [String] {
        let json = try await send(try request(baseURL: baseURL, path: "models", method: "GET", key: key), key: key)
        let entries = (json?["data"] as? [[String: Any]]) ?? (json?["models"] as? [[String: Any]])
        guard let entries else { throw AgentError.badReply }
        let ids = Set(entries.compactMap { $0["id"] as? String ?? $0["name"] as? String }).sorted()
        let notChat = ["embed", "whisper", "tts", "dall-e", "moderation", "transcribe", "realtime", "audio", "image", "rerank"]
        let chat = ids.filter { id in !notChat.contains { id.lowercased().contains($0) } }
        return chat.isEmpty ? ids : chat
    }

    /// The service's answer to `messages`.
    public func reply(baseURL: String, model: String, key: String?, messages: [AgentMessage]) async throws -> String {
        try await complete(baseURL: baseURL, model: model, key: key, messages: messages, tools: []).text
    }

    /// The service's answer to `messages`, which may ask for `tools` to be run.
    ///
    /// Two things a service may object to, each tried once: a model that will not take tools together with its default reasoning
    /// (OpenAI's newer ones on chat completions) is asked again with `reasoning_effort: "none"`, which the answer reports; and a service
    /// that rejects the tool list outright (some local models) is asked again without it, which the answer says too.
    public func complete(baseURL: String, model: String, key: String?, messages: [AgentMessage], tools: [AgentTool],
                         reasoningEffort: String? = nil) async throws -> AgentCompletion {
        guard !tools.isEmpty else {
            return try await complete(baseURL: baseURL, model: model, key: key, messages: messages, tools: [], offering: false, effort: nil)
        }
        var effort = reasoningEffort
        var refusal = ""
        for attempt in 0..<2 {
            do {
                var completion = try await complete(baseURL: baseURL, model: model, key: key, messages: messages, tools: tools, offering: true, effort: effort)
                completion.reasoningEffort = effort
                return completion
            } catch AgentError.server(let status, let message) where [400, 404, 422].contains(status) {
                let lower = message.lowercased()
                if attempt == 0, effort == nil, lower.contains("reasoning_effort") { effort = "none"; continue }
                guard lower.contains("tool") || lower.contains("function") else { throw AgentError.server(status, message) }
                refusal = message
                break
            }
        }
        var plain = try await complete(baseURL: baseURL, model: model, key: key, messages: messages.filter { $0.role != .tool && $0.toolCalls.isEmpty },
                                       tools: [], offering: false, effort: nil)
        plain.toolsRefused = true
        plain.refusal = refusal
        return plain
    }

    private func complete(baseURL: String, model: String, key: String?, messages: [AgentMessage], tools: [AgentTool], offering: Bool,
                          effort: String?) async throws -> AgentCompletion {
        var body: [String: Any] = ["model": model, "messages": messages.map(Self.wire)]
        if offering { body["tools"] = tools.map(\.apiObject) }
        if offering, let effort { body["reasoning_effort"] = effort }
        let json = try await send(try request(baseURL: baseURL, path: "chat/completions", method: "POST", key: key, body: body), key: key)
        guard let choices = json?["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any] else { throw AgentError.badReply }
        let text = (message["content"] as? String) ?? ""
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).enumerated().compactMap { index, call -> AgentToolCall? in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            // `arguments` is JSON text, but a few services send the object itself.
            let arguments: String
            if let text = function["arguments"] as? String { arguments = text }
            else if let object = function["arguments"], JSONSerialization.isValidJSONObject(object),
                    let data = try? JSONSerialization.data(withJSONObject: object) { arguments = String(decoding: data, as: UTF8.self) }
            else { arguments = "{}" }
            return AgentToolCall(id: (call["id"] as? String) ?? "call_\(index)", name: name, arguments: arguments)
        }
        guard !text.isEmpty || !calls.isEmpty || message["content"] != nil else { throw AgentError.badReply }
        return AgentCompletion(text: text.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: calls)
    }

    /// One message as the API wants it.
    private static func wire(_ message: AgentMessage) -> [String: Any] {
        switch message.role {
        case .tool:
            return ["role": "tool", "tool_call_id": message.toolCallID ?? "", "content": message.text]
        case .assistant where !message.toolCalls.isEmpty:
            return ["role": "assistant", "content": message.text,
                    "tool_calls": message.toolCalls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }]
        default:
            return ["role": message.role.rawValue, "content": message.text]
        }
    }

    /// Text that came back from outside, with the key taken out should the service have echoed it.
    static func redact(_ text: String, key: String?) -> String {
        guard let key, key.count >= 8 else { return text }
        return text.replacingOccurrences(of: key, with: "•••")
    }
}
