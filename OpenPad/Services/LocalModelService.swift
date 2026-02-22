import Foundation

final class LocalModelService {
    private let llama = LlamaLocalModelService()

    // Mantiene compatibilidad con el flujo actual del ChatViewModel.
    // Si no existe modelo configurado, cae a stub para que la app no se rompa.
    func runLocal(prompt: String) async throws -> String {
        do {
            try autoConfigureModelIfPresent()
            return try await llama.runLocal(prompt: prompt)
        } catch LlamaServiceError.modelNotConfigured {
            try await Task.sleep(nanoseconds: 400_000_000)
            return "Respuesta local (stub): \(prompt.prefix(120))\n\nTip: agrega un .gguf en Files > On My iPad > OpenClawPad > Models"
        } catch {
            throw error
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
