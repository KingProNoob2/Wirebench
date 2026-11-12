#if WIREBENCH_AI
import Foundation

/// A chatbot service the agent panel can talk to. All of them are reached through the OpenAI chat-completions API
/// (`POST {baseURL}/chat/completions`), which these services either are or imitate, so one client serves every preset.
public struct AgentPreset: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// The API's root, without `/chat/completions`.
    public var baseURL: String
    /// A model to start with. Services rename theirs often, so it is a text field in the panel, never fixed.
    public var model: String
    /// False for a model running on this machine, which takes no key.
    public var needsKey: Bool
    /// Where to get a key.
    public var keyHelp: String

    public static let custom = AgentPreset(id: "custom", name: "Custom URL", baseURL: "", model: "",
                                           needsKey: true, keyHelp: "your service's own website (any service with an OpenAI-style API will do)")

    public static let all: [AgentPreset] = [
        AgentPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini",
                    needsKey: true, keyHelp: "platform.openai.com/api-keys"),
        AgentPreset(id: "anthropic", name: "Anthropic (Claude)", baseURL: "https://api.anthropic.com/v1", model: "claude-sonnet-5-5",
                    needsKey: true, keyHelp: "console.anthropic.com/settings/keys"),
        AgentPreset(id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                    model: "gemini-2.0-flash", needsKey: true, keyHelp: "aistudio.google.com/apikey"),
        AgentPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", model: "openai/gpt-4o-mini",
                    needsKey: true, keyHelp: "openrouter.ai/keys"),
        AgentPreset(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile",
                    needsKey: true, keyHelp: "console.groq.com/keys"),
        AgentPreset(id: "mistral", name: "Mistral", baseURL: "https://api.mistral.ai/v1", model: "mistral-small-latest",
                    needsKey: true, keyHelp: "console.mistral.ai/api-keys"),
        AgentPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
                    needsKey: true, keyHelp: "platform.deepseek.com/api_keys"),
        AgentPreset(id: "xai", name: "xAI (Grok)", baseURL: "https://api.x.ai/v1", model: "grok-3",
                    needsKey: true, keyHelp: "console.x.ai"),
        AgentPreset(id: "ollama", name: "Ollama (on this computer)", baseURL: "http://localhost:11434/v1", model: "llama3.2",
                    needsKey: false, keyHelp: "ollama.com: runs on this machine, no key"),
        AgentPreset(id: "lmstudio", name: "LM Studio (on this computer)", baseURL: "http://localhost:1234/v1", model: "local-model",
                    needsKey: false, keyHelp: "lmstudio.ai: runs on this machine, no key"),
        custom,
    ]

    public static func preset(id: String) -> AgentPreset { all.first { $0.id == id } ?? all[0] }
}
#endif
