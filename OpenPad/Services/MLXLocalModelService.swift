import Foundation

enum MLXServiceError: LocalizedError {
    case backendUnavailable
    case notImplementedYet

    var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "MLX no está integrado en este build. Agrega el package mlx-swift en Xcode para habilitarlo."
        case .notImplementedYet:
            return "MLX está seleccionado, pero falta implementar la inferencia real (carga de modelo + generación)."
        }
    }
}

final class MLXLocalModelService {
    private let config = LocalRuntimeConfig.shared

    func runLocal(prompt: String) async throws -> String {
        _ = prompt
        _ = config.loadMLXModelName()

        #if canImport(MLX)
        // TODO: implementación real con MLXLMCommon/MLXLLM según la versión instalada.
        // Importante: no devolver echo del prompt (confunde al usuario).
        throw MLXServiceError.notImplementedYet
        #else
        throw MLXServiceError.backendUnavailable
        #endif
    }
}
