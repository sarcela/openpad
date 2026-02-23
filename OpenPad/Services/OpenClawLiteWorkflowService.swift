import Foundation

@MainActor
final class OpenClawLiteWorkflowService {
    static let shared = OpenClawLiteWorkflowService()

    private let model = LocalModelService()

    func run(goal: String, recentMessages: [ChatMessage]) async -> (text: String, trace: [String]) {
        var trace: [String] = ["Workflow: analyze", "Workflow: plan", "Workflow: execute", "Workflow: verify"]

        let context = recentMessages.suffix(6).map { "\($0.role): \($0.text)" }.joined(separator: "
")
        let prompt = """
        Eres un ejecutor de workflows. Objetivo: \(goal)

        Contexto:
        \(context)

        Responde en español con:
        1) Plan corto (3 pasos)
        2) Ejecución propuesta
        3) Verificación final
        """

        do {
            let out = try await model.runLocal(prompt: prompt, purpose: .tools)
            return (out, trace)
        } catch {
            trace.append("Workflow error: \(error.localizedDescription)")
            return ("No pude ejecutar workflow: \(error.localizedDescription)", trace)
        }
    }
}
