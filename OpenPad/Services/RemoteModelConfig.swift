import Foundation

enum RemoteProvider: String, CaseIterable, Identifiable {
    case openAI = "OPENAI"
    case anthropic = "ANTHROPIC"
    case google = "GOOGLE"
    case openRouter = "OPENROUTER"
    case nvidia = "NVIDIA"
    case ollama = "OLLAMA"
    case customOpenAICompatible = "CUSTOM_OPENAI"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google"
        case .openRouter: return "OpenRouter"
        case .nvidia: return "NVIDIA NIM"
        case .ollama: return "Ollama"
        case .customOpenAICompatible: return "Custom (OpenAI-compatible)"
        }
    }
}

struct RemoteModelConfig {
    static let shared = RemoteModelConfig()

    struct Runtime {
        let provider: RemoteProvider
        let baseURL: String
        let token: String
        let model: String
        let organization: String
        let project: String
    }

    private enum Keys {
        static let provider = "remote.provider"
        static let baseURL = "remote.baseURL"
        static let token = "remote.token"
        static let model = "remote.model"
        static let organization = "remote.organization"
        static let project = "remote.project"
    }

    let defaultProvider: RemoteProvider = .customOpenAICompatible
    let defaultBaseURL = "http://127.0.0.1:18789/v1/chat/completions"
    let defaultModel = "openai-codex/gpt-5.3-codex"

    func load() -> Runtime {
        let d = UserDefaults.standard
        let providerRaw = d.string(forKey: Keys.provider) ?? defaultProvider.rawValue
        let provider = RemoteProvider(rawValue: providerRaw) ?? defaultProvider

        return .init(
            provider: provider,
            baseURL: d.string(forKey: Keys.baseURL) ?? defaultBaseURL,
            token: d.string(forKey: Keys.token) ?? "",
            model: d.string(forKey: Keys.model) ?? defaultModel,
            organization: d.string(forKey: Keys.organization) ?? "",
            project: d.string(forKey: Keys.project) ?? ""
        )
    }

    func save(provider: RemoteProvider, baseURL: String, token: String, model: String, organization: String = "", project: String = "") {
        let d = UserDefaults.standard
        d.set(provider.rawValue, forKey: Keys.provider)
        d.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.baseURL)
        d.set(token.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.token)
        d.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.model)
        d.set(organization.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.organization)
        d.set(project.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.project)
    }
}
