import Foundation

struct OpenClawAgentOutput {
    let text: String
    let trace: [String]
}

@MainActor
final class OpenClawLiteAgentService {
    private let localModelService = LocalModelService()
    private let tools = OpenClawLiteTools()

    func respond(to userPrompt: String) async throws -> OpenClawAgentOutput {
        var trace: [String] = []
        let firstPrompt = buildPlannerPrompt(userPrompt: userPrompt)
        let modelReply = try await localModelService.runLocal(prompt: firstPrompt)

        guard let decision = parseDecision(from: modelReply) else {
            trace.append("Planner: sin JSON válido, respuesta directa")
            return .init(text: modelReply, trace: trace)
        }

        if decision.type == "final" {
            trace.append("Planner: final sin herramientas")
            return .init(text: decision.content ?? modelReply, trace: trace)
        }

        guard decision.type == "tool_call", let name = decision.name else {
            trace.append("Planner: salida desconocida, respuesta directa")
            return .init(text: modelReply, trace: trace)
        }

        trace.append("Tool call: \(name)")

        var toolName = name
        var toolArgs = decision.arguments ?? [:]

        if let directURL = extractFirstURL(from: userPrompt)?.absoluteString {
            if name == "brave_search" {
                toolName = "http_get"
                toolArgs = ["url": directURL, "allow_host": "true"]
                trace.append("Tool rewrite: brave_search -> http_get (URL directa)")
            } else if name == "http_get" {
                toolArgs["url"] = toolArgs["url"] ?? directURL
                toolArgs["allow_host"] = "true"
                trace.append("Tool override: allow_host=true por solicitud explícita con URL directa")
            }
        }

        if toolName == "save_memory" && !userExplicitlyAskedMemorySave(in: userPrompt) {
            trace.append("Tool blocked: save_memory no solicitado explícitamente")
            return .init(text: "Entendido. No lo guardaré en memoria a menos que me lo pidas explícitamente.", trace: trace)
        }

        let toolResult = await tools.execute(name: toolName, arguments: toolArgs)
        trace.append("Tool result: \(toolResult.ok ? "ok" : "error")")

        let secondPrompt = buildFinalizePrompt(userPrompt: userPrompt, toolName: toolName, toolResult: toolResult)
        let finalReply = try await localModelService.runLocal(prompt: secondPrompt)

        if let finalDecision = parseDecision(from: finalReply), let content = finalDecision.content, !content.isEmpty {
            return .init(text: content, trace: trace)
        }

        if let extracted = extractContentFromJsonLike(finalReply), !extracted.isEmpty {
            trace.append("Finalize fallback: contenido extraído de JSON malformado")
            return .init(text: extracted, trace: trace)
        }

        return .init(text: finalReply, trace: trace)
    }

    private func buildPlannerPrompt(userPrompt: String) -> String {
        let memoryContext = tools.recentMemories(limit: 8)
        let attachmentContext = buildAttachmentContext(from: userPrompt)
        let languageInstruction = preferredLanguageInstruction()
        return """
        Eres OpenClaw Lite en iPad.
        \(languageInstruction)
        Decide tu siguiente acción y responde SOLO en JSON válido.
        Puedes usar internet cuando sea útil para responder mejor.
        Si el usuario comparte una URL completa, prioriza `http_get` para leerla/resumirla directamente.
        Regla de memoria: SOLO usa `save_memory` cuando el usuario lo pida explícitamente (ej: "guarda en memoria", "recuerda esto", "memoriza").

        Memoria reciente persistida (sobrevive reinicios):
        \(memoryContext)

        Contexto de adjuntos detectados en este mensaje:
        \(attachmentContext)

        Herramientas disponibles:
        1) get_time(arguments: {})
        2) save_memory(arguments: {"text":"..."})
        3) list_memories(arguments: {"limit":"10"})
        4) search_memories(arguments: {"query":"...","limit":"5"})
        5) clear_memories(arguments: {})
        6) read_file(arguments: {"path":"archivo.txt"}) [solo Documents/OpenClawFiles]
        7) write_file(arguments: {"path":"archivo.txt","text":"..."}) [solo Documents/OpenClawFiles]
        8) list_files(arguments: {"path":"subcarpeta/opcional"}) [solo Documents/OpenClawFiles]
        9) http_get(arguments: {"url":"https://..."}) [solo hosts permitidos]
        10) brave_search(arguments: {"query":"...","count":"5"}) [requiere API key]

        Esquema de salida:
        - respuesta final:
          {"type":"final","content":"..."}
        - llamada de herramienta:
          {"type":"tool_call","name":"get_time|save_memory|list_memories|search_memories|clear_memories|read_file|write_file|list_files|http_get|brave_search","arguments":{"key":"value"}}

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
        s = s.replacingOccurrences(of: "\"name\":\"get_time:\"", with: "\"name\":\"get_time\"")
        s = s.replacingOccurrences(of: "\"name\":\"save_memory:\"", with: "\"name\":\"save_memory\"")
        s = s.replacingOccurrences(of: "\"name\":\"list_memories:\"", with: "\"name\":\"list_memories\"")
        return s
    }

    private func heuristicDecision(from text: String) -> AgentDecision? {
        let lower = text.lowercased()
        if lower.contains("tool_call") {
            for name in ["get_time", "save_memory", "list_memories", "search_memories", "clear_memories", "read_file", "write_file", "list_files", "http_get", "brave_search"] {
                if lower.contains(name) {
                    return AgentDecision(type: "tool_call", content: nil, name: name, arguments: [:])
                }
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

    private func extractFirstURL(from text: String) -> URL? {
        let pattern = #"https?://[^\s\)\]\>\"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return URL(string: String(text[matchRange]))
    }

    private func extractContentFromJsonLike(_ text: String) -> String? {
        // Intenta extraer el campo content de JSON/JSON-like mal formado.
        let patterns = [
            #"\"content\"\s*:\s*\"((?:\\.|[^\"])*)\""#,
            #"content\s*[:=]\s*\"([^\"]+)\""#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsrange = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: nsrange),
                  let range = Range(match.range(at: 1), in: text) else { continue }

            let raw = String(text[range])
            return raw
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private func userExplicitlyAskedMemorySave(in prompt: String) -> Bool {
        let p = prompt.lowercased()
        let triggers = [
            "guarda en memoria", "guardar en memoria", "recuerda esto", "memoriza", "acuérdate", "acuerdate",
            "remember this", "save this"
        ]
        return triggers.contains { p.contains($0) }
    }

    private func preferredLanguageInstruction() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let parts = Locale.components(fromIdentifier: preferred)
        let languageCode = (parts[NSLocale.Key.languageCode.rawValue] ?? "en").lowercased()

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
