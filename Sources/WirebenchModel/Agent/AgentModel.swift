#if WIREBENCH_AI
import Foundation
import Observation

/// The agent panel's state: which service, which model, whether there is a key, and the conversation. Both frontends draw it; neither
/// holds any of it.
@Observable
public final class AgentModel: @unchecked Sendable {
    public static let greeting = "Hi. Pick a service, enter your API key once, and ask me something."
    /// The most rounds of "ask, run the tools it wants, ask again" for one question, so a model that keeps calling tools cannot run on forever.
    static let maxRounds = 40
    /// How many turns go back to the service with each question: enough for a conversation, not an ever-growing bill.
    private static let history = 40

    /// What the panel shows: what was said, and one line for each thing the agent did.
    public private(set) var messages: [AgentMessage] = [AgentMessage(.assistant, AgentModel.greeting)]
    /// What goes back to the service: the same, but with the tool calls and their full results.
    private var wire: [AgentMessage] = []
    public private(set) var isSending = false
    /// What the agent is doing now, while it works through tools ("Reading the page…"). Empty otherwise.
    public private(set) var currentAction = ""
    /// The agent's hands, which act on the open project. Set by `AppModel`; without it the agent only chats.
    public var toolbox: AgentToolbox?
    /// Whether the agent may change the project (and run the simulation, save). Off, it can only read. Kept between runs.
    public var canEdit: Bool { didSet { defaults.set(canEdit, forKey: "agent.canEdit") } }
    /// Set when a service refused the tool list, so the panel says the agent cannot reach the project through it.
    public private(set) var toolsRefused = false
    /// What the service said when it refused them, so the panel can show the real reason.
    public private(set) var toolsRefusal = ""
    /// `"none"` once a model has said it will not take tools with its default reasoning on; sent with each request after that.
    private var reasoningEffort: String?
    /// What went wrong with the last attempt, in words for the user. Empty when nothing did.
    public private(set) var error = ""
    /// Whether a key is held for the chosen service. The key itself is never exposed.
    public private(set) var hasKey = false
    /// Where it lives: "the macOS Keychain", or "this session only" where there is nowhere safe.
    public private(set) var keyLocation = ""
    /// The models the service offers, fetched from it. Empty until fetched, or if it would not say (then the model is typed in).
    public private(set) var availableModels: [String] = []
    public private(set) var isLoadingModels = false
    /// Why the list could not be fetched, in words for the user.
    public private(set) var modelsError = ""
    /// What to tell the user under the model field when there is no list to choose from. Empty when there is one, or nothing went wrong.
    public var modelsHint: String {
        guard availableModels.isEmpty, !isLoadingModels, !modelsError.isEmpty else { return "" }
        return "Could not list the models (\(modelsError)). Type the model name instead."
    }
    /// Which fetch is the current one, so the answer to one the user has since moved on from is ignored.
    private var modelsRequest = 0

    public var providerID: String {
        didSet {
            guard providerID != oldValue else { return }
            defaults.set(providerID, forKey: "agent.provider")
            loadSettings()
        }
    }
    public var model = "" {
        didSet {
            defaults.set(model, forKey: "agent.model.\(providerID)")
            // Whether tools work depends on the model, so a new one is tried with them again.
            if model != oldValue { toolsRefused = false; toolsRefusal = ""; reasoningEffort = nil }
        }
    }
    /// The address, which only the custom service lets you change.
    public var baseURL = "" { didSet { if providerID == AgentPreset.custom.id { defaults.set(baseURL, forKey: "agent.baseURL.custom") } } }

    public var preset: AgentPreset { AgentPreset.preset(id: providerID) }
    public var presets: [AgentPreset] { AgentPreset.all }

    /// The keys read so far, by service: from the secret store the first time a request needs one, then from here. Reading one is what
    /// makes the Keychain ask the user for permission, so it is not done at launch, and only once per service per session.
    private var cachedKeys: [String: String] = [:]
    private let store: SecretStore
    private let client: AgentClient
    private let defaults: UserDefaults
    /// The store used when the system one is not there, so a key typed in is still usable for the session.
    private let fallback = InMemorySecretStore()

    public init(store: SecretStore = SystemSecretStore(), client: AgentClient = AgentClient(),
                defaults: UserDefaults = .standard) {
        self.store = store
        self.client = client
        self.defaults = defaults
        self.providerID = AgentPreset.preset(id: defaults.string(forKey: "agent.provider") ?? "openai").id
        self.canEdit = defaults.bool(forKey: "agent.canEdit")
        loadSettings(fetch: false)
    }

    /// The saved key, read from the secret store the first time it is needed. `nil` if there is none, or the user refused access to it.
    private func currentKey() -> String? {
        if let cached = cachedKeys[providerID] { return cached }
        let read = activeStore.read(account: providerID)
        cachedKeys[providerID] = read
        return read
    }

    private var activeStore: SecretStore { store.isAvailable ? store : fallback }

    /// Reads what is remembered for the chosen service.
    /// `fetch` is false at start-up: nothing goes over the network until the panel is opened or the service changed.
    private func loadSettings(fetch: Bool = true) {
        let chosen = preset
        model = defaults.string(forKey: "agent.model.\(chosen.id)") ?? chosen.model
        baseURL = chosen.id == AgentPreset.custom.id ? (defaults.string(forKey: "agent.baseURL.custom") ?? "") : chosen.baseURL
        hasKey = activeStore.exists(account: chosen.id)
        keyLocation = activeStore.name
        error = ""
        toolsRefused = false
        toolsRefusal = ""
        reasoningEffort = nil
        availableModels = []
        modelsError = ""
        modelsRequest += 1                 // anything still on its way for the last service is out of date
        isLoadingModels = false
        if fetch { refreshModels() }
    }

    /// Asks the service which models it has, and shows them in place of a typed name. Does nothing while a service that needs a key has none,
    /// or while there is no address; it is asked again once a key is saved.
    public func refreshModels() {
        guard !preset.needsKey || hasKey, AgentClient.endpoint(baseURL: baseURL) != nil else { return }
        modelsRequest += 1
        let request = modelsRequest
        isLoadingModels = true
        modelsError = ""
        let (url, secret) = (baseURL, preset.needsKey ? currentKey() : nil)
        Task { @MainActor [weak self, client] in
            let result: Result<[String], Error>
            do { result = .success(try await client.models(baseURL: url, key: secret)) }
            catch { result = .failure(error) }
            guard let self, self.modelsRequest == request else { return }
            self.isLoadingModels = false
            switch result {
            case .success(let models):
                self.availableModels = models
                // A model that is no longer offered, or none chosen yet, is replaced by the service's usual one if it is there, else the first.
                // A name the user typed that the list just does not show (a fine-tune, say) is left alone.
                let untouched = self.model.isEmpty || self.model == self.preset.model
                if untouched, !models.contains(self.model), !models.isEmpty {
                    self.model = models.contains(self.preset.model) ? self.preset.model : models[0]
                }
            case .failure(let failure):
                self.availableModels = []
                self.modelsError = (failure as? AgentError)?.errorDescription ?? failure.localizedDescription
            }
        }
    }

    /// Keeps a key the user typed. It goes to the system's secret store, and nowhere else.
    public func setKey(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if store.isAvailable, store.write(trimmed, account: providerID) {
            keyLocation = store.name
            error = ""
        } else {
            // Nowhere safe to keep it (no keyring, or it refused): usable now, gone when the app quits, and said so.
            _ = fallback.write(trimmed, account: providerID)
            keyLocation = fallback.name
            error = "There is no keyring to store the key in, so it is kept until you quit the app. (Linux: install libsecret-tools and a keyring such as GNOME Keyring.)"
        }
        cachedKeys[providerID] = trimmed
        hasKey = true
        refreshModels()
    }

    public func removeKey() {
        store.delete(account: providerID)
        fallback.delete(account: providerID)
        cachedKeys[providerID] = nil
        hasKey = false
        error = ""
        if preset.needsKey { availableModels = []; modelsError = ""; modelsRequest += 1; isLoadingModels = false }
    }

    public func clear() {
        messages = [AgentMessage(.assistant, Self.greeting)]
        wire = []
        error = ""
        toolsRefused = false
        toolsRefusal = ""
        reasoningEffort = nil
    }

    /// Whether a question can be asked now, and if not why.
    public var blocker: String? {
        if isSending { return "Waiting for an answer." }
        if preset.needsKey && !hasKey { return AgentError.noKey(preset.name).errorDescription }
        if model.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a model name." }
        return nil
    }

    /// What goes to the service for the next request: the system prompt, then the conversation.
    ///
    /// The question being worked on goes whole, however many steps it has taken: every step adds a call and its answer, so a long task can pass the
    /// `history` cap by itself, and cutting at the cap used to drop the question — and, with no user turn left in the window, everything, so the
    /// model was sent no conversation at all and asked what to do. Earlier questions fill what room is left, cut at a user turn so a tool's answer
    /// is never left without the call it answers; and what tools returned in earlier questions is dropped, since the project has moved on.
    func requestMessages(offering: Bool) -> [AgentMessage] {
        let system = AgentMessage(.system, AgentKnowledge.prompt(canEdit: canEdit, toolsOffered: offering))
        guard let current = wire.lastIndex(where: { $0.role == .user }) else { return [system] }
        var earlier = Array(wire[..<current].suffix(max(0, Self.history - (wire.count - current))))
        if let start = earlier.firstIndex(where: { $0.role == .user }) { earlier.removeFirst(start) } else { earlier = [] }
        for i in earlier.indices where earlier[i].role == .tool { earlier[i].text = "(result from an earlier question, left out)" }
        return [system] + earlier + wire[current...]
    }

    /// Asks the service and adds its answer to the conversation, running the project tools it asks for on the way. Returns at once; the
    /// answer arrives later.
    public func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }
        if let why = blocker { error = why; return }
        let (url, name, secret) = (baseURL, model, preset.needsKey ? currentKey() : nil)   // a local service is sent no key
        if preset.needsKey && secret == nil {
            // The key is saved but could not be read: access to it was refused. Say so rather than send the question keyless.
            error = "Could not read the saved \(preset.name) key from \(keyLocation) (access may have been refused). Remove it and enter it again, or allow access."
            return
        }
        messages.append(AgentMessage(.user, question))
        wire.append(AgentMessage(.user, question))
        isSending = true
        error = ""

        Task { @MainActor [weak self] in
            await self?.converse(url: url, model: name, key: secret)
        }
    }

    /// One question's worth of rounds: ask; if the answer calls tools, run them, add their results, and ask again; stop at text.
    @MainActor
    private func converse(url: String, model name: String, key secret: String?) async {
        defer { isSending = false; currentAction = "" }
        var offering = toolbox != nil && !toolsRefused
        for round in 0..<Self.maxRounds {
            let tools = offering ? AgentToolbox.offered(canEdit: canEdit) : []
            let completion: AgentCompletion
            do {
                completion = try await client.complete(baseURL: url, model: name, key: secret, messages: requestMessages(offering: offering), tools: tools,
                                                 reasoningEffort: reasoningEffort)
            } catch {
                self.error = (error as? AgentError)?.errorDescription ?? error.localizedDescription
                return
            }
            if let effort = completion.reasoningEffort { reasoningEffort = effort }
            if completion.toolsRefused {
                toolsRefused = true
                toolsRefusal = completion.refusal
                offering = false
            }
            wire.append(AgentMessage(assistant: completion.text, toolCalls: completion.toolCalls))
            if !completion.text.isEmpty { messages.append(AgentMessage(.assistant, completion.text)) }

            guard !completion.toolCalls.isEmpty, let toolbox else {
                if completion.text.isEmpty { messages.append(AgentMessage(.assistant, "(an empty answer)")) }
                return
            }
            for call in completion.toolCalls {
                currentAction = AgentToolbox.activity(for: call.name)
                let outcome = toolbox.run(name: call.name, arguments: call.arguments, canEdit: canEdit)
                wire.append(AgentMessage(toolResult: outcome.result, for: call.id))
                var line = AgentMessage(.tool, outcome.summary)
                line.failed = outcome.failed
                messages.append(line)
                await Task.yield()           // let the panel draw each step as it happens
            }
            if round == Self.maxRounds - 1 {
                messages.append(AgentMessage(.assistant, "I stopped after \(Self.maxRounds) steps. Say \"continue\" if there is more to do."))
            }
        }
    }
}
#endif
