import Foundation

@MainActor
final class OpenClawLiteWorkflowService {
    static let shared = OpenClawLiteWorkflowService()

    private let model = LocalModelService()
    private let tools = OpenClawLiteTools()

    func run(goal: String, recentMessages: [ChatMessage]) async -> (text: String, trace: [String]) {
        var trace: [String] = ["Workflow: analyze", "Workflow: plan", "Workflow: execute", "Workflow: verify"]

        let plan = buildDeterministicPlan(goal: goal)
        trace.append("Plan steps: \(plan.joined(separator: " | "))")

        var toolOutputs: [String] = []
        for step in plan {
            let result = await executeStep(step, goal: goal)
            trace.append("Step \(step): \(result.ok ? "ok" : "error")")
            toolOutputs.append("[\(step)] \(result.output)")
        }

        let verification = verify(outputs: toolOutputs)
        trace.append("Verify: \(verification ? "ok" : "warn")")

        let context = recentMessages.suffix(6).map { "\($0.role): \($0.text)" }.joined(separator: "\n")
        let synthesisPrompt = """
        Eres un ejecutor de workflows. Objetivo: \(goal)

        Contexto reciente:
        \(context)

        Execution outputs:
        \(toolOutputs.joined(separator: "\n\n"))

        Verification status: \(verification ? "OK" : "WARN")

        Respond in English with:
        1) Resultado final breve
        2) Evidence (max 3 bullets)
        3) Recommended next action
        """

        do {
            let out = try await model.runLocal(prompt: synthesisPrompt, purpose: .chat)
            return (out, trace)
        } catch {
            trace.append("Workflow synthesis error: \(error.localizedDescription)")
            let fallback = "Resultado parcial del workflow:\n\n" + toolOutputs.joined(separator: "\n\n")
            return (fallback, trace)
        }
    }

    private func buildDeterministicPlan(goal: String) -> [String] {
        let g = goal.lowercased()
        if containsURL(in: g) {
            return ["summarize_url"]
        }
        if g.contains("hora") || g.contains("fecha") || g.contains("today") {
            return ["calendar_today"]
        }
        if g.contains("uuid") {
            return ["make_uuid"]
        }
        if g.contains("regex") {
            return ["regex_extract"]
        }
        if g.contains("csv") {
            return ["csv_preview"]
        }
        return ["keyword_extract"]
    }

    private func executeStep(_ step: String, goal: String) async -> OpenClawToolResult {
        switch step {
        case "summarize_url":
            let url = firstURL(in: goal) ?? ""
            return await tools.execute(name: "summarize_url", arguments: ["url": url])
        case "calendar_today":
            return await tools.execute(name: "calendar_today", arguments: [:])
        case "make_uuid":
            return await tools.execute(name: "make_uuid", arguments: [:])
        case "regex_extract":
            return await tools.execute(name: "regex_extract", arguments: ["pattern": "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", "text": goal])
        case "csv_preview":
            return await tools.execute(name: "csv_preview", arguments: ["text": goal, "rows": "6"])
        default:
            return await tools.execute(name: "keyword_extract", arguments: ["text": goal, "top": "10"])
        }
    }

    private func verify(outputs: [String]) -> Bool {
        !outputs.contains { $0.lowercased().contains("error") || $0.lowercased().contains("invalid") }
    }

    private func containsURL(in text: String) -> Bool {
        firstURL(in: text) != nil
    }

    private func firstURL(in text: String) -> String? {
        let pattern = #"https?://[^\s\)\]\>\"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
    }
}
