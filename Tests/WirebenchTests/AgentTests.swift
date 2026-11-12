#if WIREBENCH_AI
import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WirebenchModel

/// A stand-in for the network: records the request and answers with whatever the test set.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = self.request
        // The body of a request arrives as a stream by the time it reaches a protocol.
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            request.httpBody = data
        }
        Self.seen.append(request)
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
    static func answer(_ text: String) -> (Int, Data) {
        (200, try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": text]]]]))
    }
}

@Suite("Agent panel", .serialized)
struct AgentTests {
    static func defaults() -> UserDefaults {
        let suite = "agent-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("The endpoint is the base address plus /chat/completions, whatever slashes the user typed")
    func endpoints() {
        #expect(AgentClient.endpoint(baseURL: "https://api.openai.com/v1")?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(AgentClient.endpoint(baseURL: "  https://api.openai.com/v1//  ")?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(AgentClient.endpoint(baseURL: "not a url") == nil)
        #expect(AgentClient.endpoint(baseURL: "") == nil)
    }

    @Test("A key goes only over https, or to this computer")
    func safety() {
        #expect(AgentClient.isSafe(URL(string: "https://api.openai.com/v1")!))
        #expect(AgentClient.isSafe(URL(string: "http://localhost:11434/v1")!))
        #expect(AgentClient.isSafe(URL(string: "http://127.0.0.1:1234/v1")!))
        #expect(!AgentClient.isSafe(URL(string: "http://example.com/v1")!))
        #expect(!AgentClient.isSafe(URL(string: "http://localhost.evil.com/v1")!), "the host is compared whole, not by its start")
        #expect(!AgentClient.isSafe(URL(string: "ftp://example.com")!))
    }

    @Test("A question is posted with the key as a bearer token, the model and the conversation, and the answer comes back")
    func requestAndReply() async throws {
        StubProtocol.seen = []
        StubProtocol.handler = { _ in StubProtocol.answer("  42  ") }
        let client = AgentClient(session: StubProtocol.session())
        let answer = try await client.reply(baseURL: "https://api.example.com/v1", model: "m1", key: "sk-secret-123456",
                                            messages: [AgentMessage(.system, "be brief"), AgentMessage(.user, "what is 6x7?")])
        #expect(answer == "42", "the answer is trimmed")
        let request = try #require(StubProtocol.seen.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret-123456")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "m1")
        let sent = try #require(body["messages"] as? [[String: String]])
        #expect(sent == [["role": "system", "content": "be brief"], ["role": "user", "content": "what is 6x7?"]])
    }

    @Test("A key is never sent over plain http to another machine, and no request is made")
    func refusesUnsafeAddress() async {
        StubProtocol.seen = []
        StubProtocol.handler = { _ in StubProtocol.answer("x") }
        let client = AgentClient(session: StubProtocol.session())
        await #expect(throws: AgentError.notSafe("example.com")) {
            try await client.reply(baseURL: "http://example.com/v1", model: "m", key: "sk-secret-123456", messages: [AgentMessage(.user, "hi")])
        }
        #expect(StubProtocol.seen.isEmpty)
    }

    @Test("A local service takes no key, and none is sent")
    func localNeedsNoKey() async throws {
        StubProtocol.seen = []
        StubProtocol.handler = { _ in StubProtocol.answer("hello") }
        let client = AgentClient(session: StubProtocol.session())
        _ = try await client.reply(baseURL: "http://localhost:11434/v1", model: "llama3.2", key: nil, messages: [AgentMessage(.user, "hi")])
        #expect(StubProtocol.seen.last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("The service's own reason is shown, and the key is taken out if it was echoed")
    func serverErrors() async {
        StubProtocol.handler = { _ in
            (401, try! JSONSerialization.data(withJSONObject: ["error": ["message": "Incorrect API key provided: sk-secret-123456."]]))
        }
        let client = AgentClient(session: StubProtocol.session())
        do {
            _ = try await client.reply(baseURL: "https://api.example.com/v1", model: "m", key: "sk-secret-123456", messages: [AgentMessage(.user, "hi")])
            Issue.record("a 401 should throw")
        } catch let error as AgentError {
            let text = error.errorDescription ?? ""
            #expect(text.contains("Incorrect API key"))
            #expect(text.contains("401"))
            #expect(!text.contains("sk-secret-123456"), "the key must not come back out in an error")
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test("The panel remembers a key per service, in the secret store and nowhere else")
    func keysPerService() {
        let store = InMemorySecretStore()
        let defaults = Self.defaults()
        let agent = AgentModel(store: store, client: AgentClient(session: StubProtocol.session()), defaults: defaults)
        #expect(agent.providerID == "openai" && !agent.hasKey)
        agent.setKey("  sk-openai-key  ")
        #expect(agent.hasKey)
        #expect(store.read(account: "openai") == "sk-openai-key", "trimmed, and kept in the store")
        for (_, value) in defaults.dictionaryRepresentation() { #expect(!"\(value)".contains("sk-openai-key"), "the key is not in the preferences") }

        agent.providerID = "groq"
        #expect(!agent.hasKey, "another service does not borrow the key")
        agent.setKey("gsk-groq")
        agent.providerID = "openai"
        #expect(agent.hasKey)
        agent.removeKey()
        #expect(!agent.hasKey && store.read(account: "openai") == nil)
        agent.providerID = "groq"
        #expect(agent.hasKey, "removing one key leaves the others")

        // A new panel finds what was saved.
        let again = AgentModel(store: store, client: AgentClient(session: StubProtocol.session()), defaults: defaults)
        #expect(again.providerID == "groq" && again.hasKey)
    }

    @Test("Model names are remembered per service, and presets fill in their own address")
    func settingsPerService() {
        let defaults = Self.defaults()
        let agent = AgentModel(store: InMemorySecretStore(), client: AgentClient(session: StubProtocol.session()), defaults: defaults)
        #expect(agent.baseURL == "https://api.openai.com/v1" && agent.model == "gpt-4o-mini")
        agent.model = "gpt-4.1"
        agent.providerID = "ollama"
        #expect(agent.baseURL == "http://localhost:11434/v1" && agent.model == "llama3.2")
        agent.providerID = "openai"
        #expect(agent.model == "gpt-4.1")
        agent.providerID = "custom"
        agent.baseURL = "https://my.proxy.example/v1"
        agent.providerID = "openai"
        agent.providerID = "custom"
        #expect(agent.baseURL == "https://my.proxy.example/v1", "a custom address is remembered")
    }

    @Test("Asking needs a key, unless the service is local, and says what is missing")
    func blockers() {
        let agent = AgentModel(store: InMemorySecretStore(), client: AgentClient(session: StubProtocol.session()), defaults: Self.defaults())
        #expect(agent.blocker?.contains("API key") == true)
        agent.send("hello")
        #expect(agent.messages.count == 1, "nothing was sent")
        #expect(agent.error.contains("API key"))
        agent.providerID = "ollama"
        #expect(agent.blocker == nil)
    }

    @Test("A question is asked, the answer is added, and the conversation goes back with the next one")
    func conversation() async throws {
        StubProtocol.seen = []
        StubProtocol.handler = { _ in StubProtocol.answer("an answer") }
        let agent = AgentModel(store: InMemorySecretStore(), client: AgentClient(session: StubProtocol.session()), defaults: Self.defaults())
        agent.providerID = "ollama"
        agent.send("first")
        #expect(agent.isSending)
        for _ in 0..<200 where agent.isSending { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(!agent.isSending)
        #expect(agent.messages.map(\.text).suffix(2) == ["first", "an answer"])
        agent.send("second")
        for _ in 0..<200 where agent.isSending { try await Task.sleep(nanoseconds: 20_000_000) }
        let data = try #require(StubProtocol.seen.last?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sent = try #require(body["messages"] as? [[String: String]])
        #expect(sent.first?["role"] == "system")
        #expect(sent.map { $0["content"] ?? "" }.suffix(3) == ["first", "an answer", "second"], "the earlier turns go back too")
        agent.clear()
        #expect(agent.messages.count == 1)
    }

    @Test("A failed request is reported, and the panel is ready for the next one")
    func failureRecovers() async throws {
        StubProtocol.handler = { _ in (500, Data("{\"error\":{\"message\":\"overloaded\"}}".utf8)) }
        let agent = AgentModel(store: InMemorySecretStore(), client: AgentClient(session: StubProtocol.session()), defaults: Self.defaults())
        agent.providerID = "ollama"
        agent.send("hi")
        for _ in 0..<200 where agent.isSending { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(!agent.isSending)
        #expect(agent.error.contains("overloaded"))
    }

    @Test("The system's own store keeps and forgets a key (where there is one)")
    func systemStore() {
        let store = SystemSecretStore()
        guard store.isAvailable else { return }          // a Linux machine without a keyring
        let account = "test-\(UUID().uuidString)"
        defer { store.delete(account: account) }
        // Best effort: a machine that refuses a program the keychain does not know (a locked or headless one) is not a failure of the code.
        guard store.write("sk-test-value", account: account) else { return }
        #expect(store.read(account: account) == "sk-test-value")
        store.delete(account: account)
        #expect(store.read(account: account) == nil)
    }

    // MARK: - Fetching the list of models

    static func modelList(_ ids: [String]) -> (Int, Data) {
        (200, try! JSONSerialization.data(withJSONObject: ["object": "list", "data": ids.map { ["id": $0, "object": "model"] }]))
    }

    /// Waits for the panel's fetch to finish.
    static func settle(_ agent: AgentModel) async throws {
        for _ in 0..<200 where agent.isLoadingModels { try await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test("The models come from GET /models with the key, sorted, without the ones that cannot chat")
    func fetchesModels() async throws {
        StubProtocol.seen = []
        StubProtocol.handler = { _ in Self.modelList(["gpt-4o", "text-embedding-3-small", "whisper-1", "gpt-4o-mini", "dall-e-3", "gpt-4o"]) }
        let client = AgentClient(session: StubProtocol.session())
        let models = try await client.models(baseURL: "https://api.example.com/v1/", key: "sk-secret-123456")
        #expect(models == ["gpt-4o", "gpt-4o-mini"], "sorted, without duplicates, embeddings, speech or images")
        let request = try #require(StubProtocol.seen.last)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.example.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-secret-123456")
    }

    @Test("If every model looks like a non-chat one, the list is kept whole")
    func keepsAListThatWouldBeEmpty() async throws {
        StubProtocol.handler = { _ in Self.modelList(["some-image-model", "another-embed"]) }
        let models = try await AgentClient(session: StubProtocol.session()).models(baseURL: "https://api.example.com/v1", key: "sk-secret-123456")
        #expect(models == ["another-embed", "some-image-model"])
    }

    @Test("Asking for the models is held to the same safety rule as a question")
    func modelsRefuseUnsafeAddress() async {
        StubProtocol.seen = []
        StubProtocol.handler = { _ in Self.modelList(["x"]) }
        await #expect(throws: AgentError.notSafe("example.com")) {
            try await AgentClient(session: StubProtocol.session()).models(baseURL: "http://example.com/v1", key: "sk-secret-123456")
        }
        #expect(StubProtocol.seen.isEmpty)
    }

    @Test("A service that will not list its models gives an error the panel can show")
    func modelsError() async {
        StubProtocol.handler = { _ in (404, Data("{\"error\":{\"message\":\"no such route\"}}".utf8)) }
        do {
            _ = try await AgentClient(session: StubProtocol.session()).models(baseURL: "https://api.example.com/v1", key: "sk-secret-123456")
            Issue.record("a 404 should throw")
        } catch let error as AgentError { #expect(error.errorDescription?.contains("no such route") == true) }
        catch { Issue.record("wrong error \(error)") }
    }

    @Test("Nothing is asked until there is a key; saving it fetches the models, and the usual model is chosen if the service has it")
    func keyFetchesModels() async throws {
        StubProtocol.seen = []
        StubProtocol.handler = { _ in Self.modelList(["gpt-4.1", "gpt-4o-mini", "o3"]) }
        let agent = AgentModel(store: InMemorySecretStore(), client: AgentClient(session: StubProtocol.session()), defaults: Self.defaults())
        agent.refreshModels()
        #expect(agent.availableModels.isEmpty && !agent.isLoadingModels && StubProtocol.seen.isEmpty, "no key, so nothing is asked")
        #expect(agent.modelsHint.isEmpty)

        agent.setKey("sk-openai-key")
        #expect(agent.isLoadingModels)
        try await Self.settle(agent)
        #expect(agent.availableModels == ["gpt-4.1", "gpt-4o-mini", "o3"])
        #expect(agent.model == "gpt-4o-mini", "the preset's own model, as the service has it")
    }

    @Test("A model that is gone is replaced; one the user typed that the list lacks is left alone")
    func modelChoice() async throws {
        StubProtocol.handler = { _ in Self.modelList(["alpha", "beta"]) }
        let agent = AgentModel(store: InMemorySecretStore(), client: AgentClient(session: StubProtocol.session()), defaults: Self.defaults())
        agent.providerID = "ollama"                       // no key needed, so the list is fetched at once
        try await Self.settle(agent)
        #expect(agent.availableModels == ["alpha", "beta"])
        #expect(agent.model == "alpha", "llama3.2 is not offered, so the first is taken")
        agent.model = "my-fine-tune"
        agent.refreshModels()
        try await Self.settle(agent)
        #expect(agent.model == "my-fine-tune")
    }

    @Test("A failed fetch leaves the model to be typed, with the reason")
    func failedFetch() async throws {
        StubProtocol.handler = { _ in (500, Data("{\"error\":{\"message\":\"down\"}}".utf8)) }
        let agent = AgentModel(store: InMemorySecretStore(), client: AgentClient(session: StubProtocol.session()), defaults: Self.defaults())
        agent.providerID = "ollama"
        try await Self.settle(agent)
        #expect(agent.availableModels.isEmpty)
        #expect(agent.modelsError.contains("down"))
        #expect(agent.model == "llama3.2", "the preset's name stays as the starting text")
    }

    @Test("The answer to a fetch for a service the user has left is ignored")
    func staleFetch() async throws {
        StubProtocol.handler = { request in
            // The first service answers slowly in effect: the test switches away before it is read.
            request.url?.host == "localhost" && request.url?.port == 11434 ? Self.modelList(["ollama-model"]) : Self.modelList(["lm-model"])
        }
        let agent = AgentModel(store: InMemorySecretStore(), client: AgentClient(session: StubProtocol.session()), defaults: Self.defaults())
        agent.providerID = "ollama"
        agent.providerID = "lmstudio"                     // before the first answer is applied
        try await Self.settle(agent)
        #expect(agent.availableModels == ["lm-model"], "only the current service's list is shown")
    }

    @Test("Nothing goes over the network when the model is created")
    func startsQuietly() {
        StubProtocol.seen = []
        StubProtocol.handler = { _ in Self.modelList(["x"]) }
        let defaults = Self.defaults()
        defaults.set("ollama", forKey: "agent.provider")
        let agent = AgentModel(store: InMemorySecretStore(), client: AgentClient(session: StubProtocol.session()), defaults: defaults)
        #expect(!agent.isLoadingModels && StubProtocol.seen.isEmpty)
    }

    /// A store that counts how often the secret itself is read, which is what makes the Keychain ask the user for permission.
    private final class CountingStore: SecretStore, @unchecked Sendable {
        let name = "a counting store"
        var isAvailable: Bool { true }
        private(set) var reads = 0
        private(set) var checks = 0
        func read(account: String) -> String? { reads += 1; return "sk-saved-key-123" }
        func exists(account: String) -> Bool { checks += 1; return true }
        func write(_ secret: String, account: String) -> Bool { true }
        func delete(account: String) {}
    }

    @Test("A saved key is only checked for at start-up, and read the first time a question needs it — once")
    @MainActor
    func keyIsReadLazily() async throws {
        StubProtocol.seen = []
        StubProtocol.handler = { _ in StubProtocol.answer("hi") }
        let store = CountingStore()
        let agent = AgentModel(store: store, client: AgentClient(session: StubProtocol.session()), defaults: Self.defaults())
        #expect(agent.hasKey, "known from the check")
        #expect(store.reads == 0, "creating the model must not read the secret: that is what raises the Keychain prompt at every launch")

        agent.send("one")
        for _ in 0..<300 where agent.isSending { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(store.reads == 1)
        #expect(StubProtocol.seen.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-saved-key-123")
        agent.send("two")
        for _ in 0..<300 where agent.isSending { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(store.reads == 1, "kept for the session, not asked for again")

        // Another service is read once, and going back to the first asks for nothing.
        agent.providerID = "groq"
        agent.refreshModels()
        agent.providerID = "openai"
        agent.refreshModels()
        #expect(store.reads == 2)
    }
}
#endif
