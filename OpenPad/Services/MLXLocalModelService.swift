import Foundation

#if canImport(MLXLLM)
import MLXLLM
#if canImport(MLXLMCommon)
import MLXLMCommon
#endif
#endif

enum MLXServiceError: LocalizedError {
    case backendUnavailable
    case emptyResponse
    case invalidModelId

    var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "MLX is not integrated in this build. Verify MLXLLM is added to the target."
        case .emptyResponse:
            return "MLX returned an empty response"
        case .invalidModelId:
            return "Invalid MLX model ID"
        }
    }
}

@MainActor
final class MLXLocalModelService {
    private let config = LocalRuntimeConfig.shared

    #if canImport(MLXLLM)
    private var loadedModelId: String?
    private var session: ChatSession?
    #endif

    func runLocal(prompt: String, modelIdOverride: String? = nil) async throws -> String {
        #if canImport(MLXLLM)
        let configured = modelIdOverride ?? config.loadMLXModelName()
        let modelId = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        let useModelId = modelId.isEmpty ? "mlx-community/Qwen2.5-1.5B-Instruct-4bit" : modelId

        let session = try await getOrCreateSession(modelId: useModelId)
        let text = try await session.respond(to: prompt).trimmingCharacters(in: .whitespacesAndNewlines)

        // Stability mode: release session/model between turns to avoid memory growth (OOM on iPad).
        self.session = nil
        self.loadedModelId = nil

        guard !text.isEmpty else { throw MLXServiceError.emptyResponse }
        return text
        #else
        _ = prompt
        throw MLXServiceError.backendUnavailable
        #endif
    }

    func prewarmModel(modelId: String) async throws {
        #if canImport(MLXLLM)
        let clean = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw MLXServiceError.invalidModelId }
        _ = try await getOrCreateSession(modelId: clean)
        #else
        _ = modelId
        throw MLXServiceError.backendUnavailable
        #endif
    }

    #if canImport(MLXLLM)
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
