import Foundation

@MainActor
final class OpenClawLiteAgentService {
    private let localModelService = LocalModelService()
    private let tools = OpenClawLiteTools()

    func respond(to userPrompt: String) async throws -> String {
        let firstPrompt = buildPlannerPrompt(userPrompt: userPrompt)
        let modelReply = try await localModelService.runLocal(prompt: firstPrompt)

        guard let decision = parseDecision(from: modelReply) else {
            return modelReply
        }

        if decision.type == "final" {
            return decision.content ?? modelReply
        }

        guard decision.type == "tool_call", let name = decision.name else {
            return modelReply
        }

        let toolResult = tools.execute(name: name, arguments: decision.arguments ?? [:])
        let secondPrompt = buildFinalizePrompt(userPrompt: userPrompt, toolName: name, toolResult: toolResult)
        let finalReply = try await localModelService.runLocal(prompt: secondPrompt)

        if let finalDecision = parseDecision(from: finalReply), let content = finalDecision.content, !content.isEmpty {
            return content
        }
        return finalReply
    }

    private func buildPlannerPrompt(userPrompt: String) -> String {
        """
        You are OpenClaw Lite on iPad.
        Decide your next action and reply with JSON only.

        Available tools:
        1) get_time(arguments: {})
        2) save_memory(arguments: {"text":"..."})
        3) list_memories(arguments: {"limit":"10"})

        Output schema:
        - final answer:
          {"type":"final","content":"..."}
        - tool call:
          {"type":"tool_call","name":"get_time|save_memory|list_memories","arguments":{"key":"value"}}

        User message:
        \(userPrompt)
        """
    }

    private func buildFinalizePrompt(userPrompt: String, toolName: String, toolResult: OpenClawToolResult) -> String {
        """
        You are OpenClaw Lite on iPad.
        You already called one tool. Provide final user-facing answer in JSON only.

        Output schema:
        {"type":"final","content":"..."}

        Original user message:
        \(userPrompt)

        Tool called:
        \(toolName)

        Tool success:
        \(toolResult.ok)

        Tool output:
        \(toolResult.output)
        """
    }

    private func parseDecision(from text: String) -> AgentDecision? {
        guard let data = extractFirstJSONObject(from: text)?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentDecision.self, from: data)
    }

    private func extractFirstJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var end: String.Index?

        for idx in text[start...].indices {
            let ch = text[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    end = idx
                    break
                }
            }
        }

        guard let end else { return nil }
        return String(text[start...end])
    }
}

private struct AgentDecision: Codable {
    let type: String
    let content: String?
    let name: String?
    let arguments: [String: String]?
}
