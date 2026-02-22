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
        let memoryContext = tools.recentMemories(limit: 8)
        let languageInstruction = preferredLanguageInstruction()
        return """
        Eres OpenClaw Lite en iPad.
        \(languageInstruction)
        Decide tu siguiente acción y responde SOLO en JSON válido.

        Memoria reciente persistida (sobrevive reinicios):
        \(memoryContext)

        Herramientas disponibles:
        1) get_time(arguments: {})
        2) save_memory(arguments: {"text":"..."})
        3) list_memories(arguments: {"limit":"10"})

        Esquema de salida:
        - respuesta final:
          {"type":"final","content":"..."}
        - llamada de herramienta:
          {"type":"tool_call","name":"get_time|save_memory|list_memories","arguments":{"key":"value"}}

        Mensaje del usuario:
        \(userPrompt)
        """
    }

    private func buildFinalizePrompt(userPrompt: String, toolName: String, toolResult: OpenClawToolResult) -> String {
        let languageInstruction = preferredLanguageInstruction()
        return """
        Eres OpenClaw Lite en iPad.
        Ya llamaste una herramienta. Da respuesta final al usuario en JSON válido.
        \(languageInstruction)

        Esquema de salida:
        {"type":"final","content":"..."}

        Mensaje original del usuario:
        \(userPrompt)

        Herramienta llamada:
        \(toolName)

        Éxito de herramienta:
        \(toolResult.ok)

        Resultado de herramienta:
        \(toolResult.output)
        """
    }

    private func parseDecision(from text: String) -> AgentDecision? {
        guard let raw = extractFirstJSONObject(from: text) else {
            return heuristicDecision(from: text)
        }

        if let decoded = decodeDecision(from: raw) {
            return normalize(decoded)
        }

        let repaired = repairLooselyFormattedJSON(raw)
        if let decoded = decodeDecision(from: repaired) {
            return normalize(decoded)
        }

        return heuristicDecision(from: text)
    }

    private func decodeDecision(from json: String) -> AgentDecision? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentDecision.self, from: data)
    }

    private func repairLooselyFormattedJSON(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\"tyoe\"", with: "\"type\"")
        s = s.replacingOccurrences(of: "'", with: "\"")
        s = s.replacingOccurrences(of: ",\"", with: ",\"")
        s = s.replacingOccurrences(of: "\"name\":\"get_time:\"", with: "\"name\":\"get_time\"")
        s = s.replacingOccurrences(of: "\"name\":\"save_memory:\"", with: "\"name\":\"save_memory\"")
        s = s.replacingOccurrences(of: "\"name\":\"list_memories:\"", with: "\"name\":\"list_memories\"")
        s = s.replacingOccurrences(of: "\"arguments\":{}", with: "\"arguments\":{}")
        return s
    }

    private func heuristicDecision(from text: String) -> AgentDecision? {
        let lower = text.lowercased()
        if lower.contains("tool_call") {
            if lower.contains("get_time") {
                return AgentDecision(type: "tool_call", content: nil, name: "get_time", arguments: [:])
            }
            if lower.contains("save_memory") {
                return AgentDecision(type: "tool_call", content: nil, name: "save_memory", arguments: [:])
            }
            if lower.contains("list_memories") {
                return AgentDecision(type: "tool_call", content: nil, name: "list_memories", arguments: [:])
            }
        }
        return nil
    }

    private func normalize(_ decision: AgentDecision) -> AgentDecision {
        let normalizedName = decision.name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":,;"))
        let normalizedType = decision.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return AgentDecision(type: normalizedType, content: decision.content, name: normalizedName, arguments: decision.arguments)
    }

    private func preferredLanguageInstruction() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let languageCode = Locale(identifier: preferred).language.languageCode?.identifier ?? "en"

        switch languageCode {
        case "es":
            return "Responde por defecto en español, salvo que el usuario pida otro idioma."
        case "en":
            return "Respond in English by default, unless the user asks for another language."
        case "pt":
            return "Responda em português por padrão, a menos que o usuário peça outro idioma."
        case "fr":
            return "Réponds en français par défaut, sauf si l'utilisateur demande une autre langue."
        default:
            return "Respond in the iPad preferred language (\(languageCode)) by default, unless the user asks for another language."
        }
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
