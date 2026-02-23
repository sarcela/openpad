import Foundation

struct OpenClawHealthCheck {
    let level: String // ok|warn
    let message: String
}

@MainActor
final class OpenClawLiteHealthService {
    static let shared = OpenClawLiteHealthService()

    private let runtime = LocalRuntimeConfig.shared
    private let lite = OpenClawLiteConfig.shared

    func runChecks(lastLatencyMs: Int, lastError: String, successCount: Int, errorCount: Int) -> [OpenClawHealthCheck] {
        var out: [OpenClawHealthCheck] = []

        if runtime.loadProvider() == .mlx {
            if !lite.isLowPowerModeEnabled() {
                out.append(.init(level: "warn", message: "MLX sin modo ahorro puede calentar iPad."))
            }
            if runtime.isSeparateMLXToolsModelEnabled() {
                out.append(.init(level: "warn", message: "Modelo separado para tools aumenta riesgo de OOM."))
            }
        }

        if errorCount > successCount && errorCount >= 3 {
            out.append(.init(level: "warn", message: "Tasa de error alta; revisa modelo o red."))
        }

        if lastLatencyMs > 12000 {
            out.append(.init(level: "warn", message: "Latencia alta (>12s). Considera perfil Estable/Balanceado."))
        }

        if !lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(.init(level: "warn", message: "Último error: \(String(lastError.prefix(80)))"))
        }

        if out.isEmpty {
            out.append(.init(level: "ok", message: "Sistema saludable ✅"))
        }
        return out
    }
}
