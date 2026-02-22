import Foundation

#if canImport(MLXLLM) && canImport(MLXLMCommon)
import MLXLLM
import MLXLMCommon
#endif

enum MLXServiceError: LocalizedError {
    case backendUnavailable
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "MLX no está integrado en este build. Verifica que MLXLLM y MLXLMCommon estén en el target."
        case .emptyResponse:
            return "MLX respondió vacío"
        }
    }
}

@MainActor
final class MLXLocalModelService {
    private let config = LocalRuntimeConfig.shared

    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    private var loadedModelId: String?
    private var session: ChatSession?
    #endif

    func runLocal(prompt: String) async throws -> String {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        let modelId = config.loadMLXModelName().trimmingCharacters(in: .whitespacesAndNewlines)
        let useModelId = modelId.isEmpty ? "mlx-community/Qwen2.5-1.5B-Instruct-4bit" : modelId

        let session = try await getOrCreateSession(modelId: useModelId)
        let text = try await session.respond(to: prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MLXServiceError.emptyResponse }
        return text
        #else
        _ = prompt
        throw MLXServiceError.backendUnavailable
        #endif
    }

    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    private func getOrCreateSession(modelId: String) async throws -> ChatSession {
        if let session, loadedModelId == modelId {
            return session
        }

        let model = try await loadModel(id: modelId)
        let newSession = ChatSession(model)
        self.session = newSession
        self.loadedModelId = modelId
        return newSession
    }
    #endif
}
