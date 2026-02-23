import Foundation

enum LocalRuntimeProvider: String, CaseIterable, Identifiable {
    case llamaCpp = "LLAMA_CPP"
    case ollama = "OLLAMA"
    case mlx = "MLX"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .llamaCpp: return "llama.cpp"
        case .ollama: return "Ollama"
        case .mlx: return "MLX"
        }
    }
}

struct LocalRuntimeConfig {
    static let shared = LocalRuntimeConfig()

    private enum Keys {
        static let provider = "local.runtime.provider"
        static let ollamaBaseURL = "local.ollama.baseURL"
        static let ollamaModel = "local.ollama.model"
        static let mlxModel = "local.mlx.model"
        static let mlxToolsModel = "local.mlx.tools.model"
        static let mlxSeparateToolsModelEnabled = "local.mlx.tools.separate.enabled"
        static let recentContextWindow = "agent.recent.context.window"
    }

    func loadProvider() -> LocalRuntimeProvider {
        let raw = UserDefaults.standard.string(forKey: Keys.provider) ?? LocalRuntimeProvider.mlx.rawValue
        return LocalRuntimeProvider(rawValue: raw) ?? .mlx
    }

    func saveProvider(_ provider: LocalRuntimeProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: Keys.provider)
    }

    func loadOllama() -> (baseURL: String, model: String) {
        let d = UserDefaults.standard
        return (
            baseURL: d.string(forKey: Keys.ollamaBaseURL) ?? "http://127.0.0.1:11434",
            model: d.string(forKey: Keys.ollamaModel) ?? "qwen2.5:3b"
        )
    }

    func saveOllama(baseURL: String, model: String) {
        let d = UserDefaults.standard
        d.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.ollamaBaseURL)
        d.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.ollamaModel)
    }

    func loadMLXModelName() -> String {
        UserDefaults.standard.string(forKey: Keys.mlxModel) ?? "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    }

    func saveMLXModelName(_ name: String) {
        UserDefaults.standard.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.mlxModel)
    }

    func loadMLXToolsModelName() -> String {
        UserDefaults.standard.string(forKey: Keys.mlxToolsModel) ?? "mlx-community/Phi-3.5-mini-instruct-4bit"
    }

    func saveMLXToolsModelName(_ name: String) {
        UserDefaults.standard.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.mlxToolsModel)
    }

    func isSeparateMLXToolsModelEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Keys.mlxSeparateToolsModelEnabled)
    }

    func setSeparateMLXToolsModelEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.mlxSeparateToolsModelEnabled)
    }

    func loadRecentContextWindow() -> Int {
        let value = UserDefaults.standard.integer(forKey: Keys.recentContextWindow)
        return value == 0 ? 10 : max(2, min(30, value))
    }

    func saveRecentContextWindow(_ value: Int) {
        UserDefaults.standard.set(max(2, min(30, value)), forKey: Keys.recentContextWindow)
    }
}
