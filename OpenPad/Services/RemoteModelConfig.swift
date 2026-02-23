import Foundation

struct RemoteModelConfig {
    static let shared = RemoteModelConfig()

    private enum Keys {
        static let baseURL = "remote.baseURL"
        static let token = "remote.token"
        static let model = "remote.model"
    }

    let defaultBaseURL = "http://127.0.0.1:18789/v1/chat/completions"
    let defaultModel = "openai-codex/gpt-5.3-codex"

    func load() -> (baseURL: String, token: String, model: String) {
        let d = UserDefaults.standard
        return (
            baseURL: d.string(forKey: Keys.baseURL) ?? defaultBaseURL,
            token: d.string(forKey: Keys.token) ?? "",
            model: d.string(forKey: Keys.model) ?? defaultModel
        )
    }

    func save(baseURL: String, token: String, model: String) {
        let d = UserDefaults.standard
        d.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.baseURL)
        d.set(token.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.token)
        d.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.model)
    }
}
