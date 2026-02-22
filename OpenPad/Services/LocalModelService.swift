import Foundation

final class LocalModelService {
    private let llama = LlamaLocalModelService()
    private let ollama = OllamaLocalModelService()
    private let mlx = MLXLocalModelService()

    private let runtimeConfig = LocalRuntimeConfig.shared

    func runLocal(prompt: String) async throws -> String {
        switch runtimeConfig.loadProvider() {
        case .llamaCpp:
            do {
                try autoConfigureModelIfPresent()
                return try await llama.runLocal(prompt: prompt)
            } catch LlamaServiceError.modelNotConfigured {
                try await Task.sleep(nanoseconds: 300_000_000)
                return "Sin modelo llama.cpp seleccionado. Agrega un .gguf en Models y selecciónalo en Configuración."
            }
        case .ollama:
            return try await ollama.runLocal(prompt: prompt)
        case .mlx:
            return try await mlx.runLocal(prompt: prompt)
        }
    }

    private func autoConfigureModelIfPresent() throws {
        let docs = try LocalModelConfig.shared.documentsDirectory()
        if let modelURL = LocalModelConfig.shared.firstExistingModelPath(in: docs),
           FileManager.default.fileExists(atPath: modelURL.path) {
            try llama.configureModel(path: modelURL.path)
        }
    }
}
