import Foundation

enum MLXServiceError: LocalizedError {
    case backendUnavailable

    var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "MLX no está integrado en este build. Agrega el package mlx-swift en Xcode para habilitarlo."
        }
    }
}

final class MLXLocalModelService {
    private let config = LocalRuntimeConfig.shared

    func runLocal(prompt: String) async throws -> String {
        let modelName = config.loadMLXModelName()

        #if canImport(MLX)
        // TODO: Integración real con MLX/MLXLLM.
        // Este scaffold confirma wiring y configuración guardada.
        try await Task.sleep(nanoseconds: 350_000_000)
        return "[MLX scaffold \(modelName)] \(prompt.prefix(200))"
        #else
        _ = modelName
        throw MLXServiceError.backendUnavailable
        #endif
    }
}
