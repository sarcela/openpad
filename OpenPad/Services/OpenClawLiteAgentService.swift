import Foundation

struct OpenClawAgentOutput {
    let text: String
    let trace: [String]
}

@MainActor
final class OpenClawLiteAgentService {
    private let localModelService = LocalModelService()
    private let tools = OpenClawLiteTools()
    private let runtimeConfig = LocalRuntimeConfig.shared
    private let liteConfig = OpenClawLiteConfig.shared

    func respond(to userPrompt: String, recentMessages: [ChatMessage] = []) async throws -> OpenClawAgentOutput {
        var trace: [String] = []
        let firstPrompt = buildPlannerPrompt(userPrompt: userPrompt, recentMessages: recentMessages)
        let modelReply = try await localModelService.runLocal(prompt: firstPrompt, purpose: .tools)

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

        var toolResult = await tools.execute(name: toolName, arguments: toolArgs)
        trace.append("Tool result: \(toolResult.ok ? "ok" : "error")")

        // Persistencia: un intento adicional antes de rendirse.
        if !toolResult.ok {
            trace.append("Retry policy: segundo intento de herramienta")
            toolResult = await tools.execute(name: toolName, arguments: toolArgs)
            trace.append("Retry result: \(toolResult.ok ? "ok" : "error")")
        }

        let secondPrompt = buildFinalizePrompt(userPrompt: userPrompt, toolName: toolName, toolResult: toolResult)
        let finalReply = try await localModelService.runLocal(prompt: secondPrompt, purpose: .chat)

        if let finalDecision = parseDecision(from: finalReply), let content = finalDecision.content, !content.isEmpty {
            return .init(text: content, trace: trace)
        }

        if let extracted = extractContentFromJsonLike(finalReply), !extracted.isEmpty {
            trace.append("Finalize fallback: contenido extraído de JSON malformado")
            return .init(text: extracted, trace: trace)
        }

        return .init(text: finalReply, trace: trace)
    }

    private func buildPlannerPrompt(userPrompt: String, recentMessages: [ChatMessage]) -> String {
        let profile = runtimeConfig.loadRunProfile()
        let memoryLimit = OpenClawLiteConfig.shared.isLowPowerModeEnabled() ? 4 : (profile == .turbo ? 10 : 6)
        let memoryChars = OpenClawLiteConfig.shared.isLowPowerModeEnabled() ? 900 : (profile == .turbo ? 2600 : 1600)
        let memoryContext = String(tools.recentMemories(limit: memoryLimit).prefix(memoryChars))
        let attachmentContext = buildAttachmentContext(from: userPrompt)
        let recentContext = buildRecentContext(from: recentMessages)
        let languageInstruction = preferredLanguageInstruction()
        let autodevInstruction = liteConfig.isAutodevEnabled() ? "AutoDev: al final sugiere una micro-mejora concreta, reversible y de bajo riesgo." : "AutoDev desactivado."
        return """
        Eres OpenClaw Lite en iPad.
        \(languageInstruction)
        Decide tu siguiente acción y responde SOLO en JSON válido.
        Política de ejecución: sé persistente. Antes de concluir que algo falló, intenta al menos un enfoque alterno o un reintento razonable.
        Política de seguridad: para tools destructivas (`delete_file`, `clear_memories`) exige `confirm=YES`.
        \(autodevInstruction)
        Puedes usar internet cuando sea útil para responder mejor.
        Si el usuario comparte una URL completa, prioriza `http_get` para leerla/resumirla directamente.
        Regla de memoria: SOLO usa `save_memory` cuando el usuario lo pida explícitamente (ej: "guarda en memoria", "recuerda esto", "memoriza").

        Memoria reciente persistida (sobrevive reinicios):
        \(memoryContext)

        Contexto de adjuntos detectados en este mensaje:
        \(attachmentContext)

        Contexto reciente de conversación:
        \(recentContext)

        Herramientas disponibles:
        1) get_time(arguments: {})
        2) save_memory(arguments: {"text":"..."})
        3) list_memories(arguments: {"limit":"10"})
        4) search_memories(arguments: {"query":"...","limit":"5"})
        5) clear_memories(arguments: {"confirm":"YES"}) [destructiva]
        6) read_file(arguments: {"path":"archivo.txt"}) [solo Documents/OpenClawFiles]
        7) write_file(arguments: {"path":"archivo.txt","text":"..."}) [solo Documents/OpenClawFiles]
        8) list_files(arguments: {"path":"subcarpeta/opcional"}) [solo Documents/OpenClawFiles]
        9) file_exists(arguments: {"path":"archivo.txt"})
        10) append_file(arguments: {"path":"archivo.txt","text":"..."})
        11) delete_file(arguments: {"path":"archivo.txt","confirm":"YES"}) [destructiva]
        12) calendar_today(arguments: {})
        13) summarize_url(arguments: {"url":"https://..."})
        14) http_get(arguments: {"url":"https://..."})
        15) brave_search(arguments: {"query":"...","count":"5"}) [requiere API key]
        16) calculate(arguments: {"expression":"2+2*10"})
        17) make_uuid(arguments: {})
        18) json_parse(arguments: {"text":"{...}"})
        19) csv_preview(arguments: {"text":"a,b\n1,2","rows":"8"})
        20) markdown_toc(arguments: {"text":"# Titulo"})
        21) diff_text(arguments: {"old":"...","new":"..."})
        22) regex_extract(arguments: {"pattern":"...","text":"..."})
        23) base64_encode(arguments: {"text":"..."})
        24) base64_decode(arguments: {"text":"..."})
        25) url_encode(arguments: {"text":"..."})
        26) url_decode(arguments: {"text":"..."})
        27) json_path(arguments: {"text":"{...}","path":"$.a.b"})
        28) csv_filter(arguments: {"text":"csv...","contains":"foo"})
        29) html_to_text(arguments: {"text":"<html...>"})
        30) keyword_extract(arguments: {"text":"...","top":"12"})
        31) chunk_text(arguments: {"text":"...","size":"1200"})
        32) extract_code_blocks(arguments: {"text":"..."})
        33) lint_markdown(arguments: {"text":"..."})
        34) table_to_bullets(arguments: {"text":"..."})
        35) normalize_whitespace(arguments: {"text":"..."})

        Esquema de salida:
        - respuesta final:
          {"type":"final","content":"..."}
        - llamada de herramienta:
          {"type":"tool_call","name":"get_time|save_memory|list_memories|search_memories|clear_memories|read_file|write_file|list_files|file_exists|append_file|delete_file|calendar_today|summarize_url|http_get|brave_search|calculate|make_uuid|json_parse|csv_preview|markdown_toc|diff_text|regex_extract|base64_encode|base64_decode|url_encode|url_decode|json_path|csv_filter|html_to_text|keyword_extract|chunk_text|extract_code_blocks|lint_markdown|table_to_bullets|normalize_whitespace","arguments":{"key":"value"}}

        Mensaje del usuario:
        \(userPrompt)
        """
    }

    private func buildFinalizePrompt(userPrompt: String, toolName: String, toolResult: OpenClawToolResult) -> String {
        let languageInstruction = preferredLanguageInstruction()
        let autodevInstruction = liteConfig.isAutodevEnabled() ? "AutoDev: al final sugiere una micro-mejora concreta, reversible y de bajo riesgo." : "AutoDev desactivado."
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
            for name in ["get_time", "save_memory", "list_memories", "search_memories", "clear_memories", "read_file", "write_file", "list_files", "file_exists", "append_file", "delete_file", "calendar_today", "summarize_url", "http_get", "brave_search", "calculate", "make_uuid", "json_parse", "csv_preview", "markdown_toc", "diff_text", "regex_extract", "base64_encode", "base64_decode", "url_encode", "url_decode", "json_path", "csv_filter", "html_to_text", "keyword_extract", "chunk_text", "extract_code_blocks", "lint_markdown", "table_to_bullets", "normalize_whitespace"] {
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

    private func buildAttachmentContext(from prompt: String) -> String {
        let names = extractAttachmentNames(from: prompt)
        guard !names.isEmpty else { return "(sin adjuntos)" }

        var chunks: [String] = []
        let lowPower = OpenClawLiteConfig.shared.isLowPowerModeEnabled()
        let attachmentLimit = lowPower ? 1 : 2
        let maxChars = lowPower ? 600 : 1200
        for name in names.prefix(attachmentLimit) {
            let snippet = tools.readAttachmentSnippet(fileName: name, maxChars: maxChars)
            if snippet.isEmpty {
                chunks.append("[\(name)] (no pude leerlo automáticamente)")
            } else {
                chunks.append("[\(name)]\n\(snippet)")
            }
        }
        return chunks.joined(separator: "\n\n")
    }

    private func extractAttachmentNames(from text: String) -> [String] {
        let pattern = #"\[(?:adjunto|foto|foto-camara)\s*:\s*([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        return matches.compactMap { m in
            guard let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func buildRecentContext(from messages: [ChatMessage]) -> String {
        guard !messages.isEmpty else { return "(sin historial reciente)" }
        let baseWindow = runtimeConfig.loadRecentContextWindow()
        let lowPower = LocalRuntimeConfig.shared.loadProvider() == .mlx && OpenClawLiteConfig.shared.isLowPowerModeEnabled()
        let window = lowPower ? min(baseWindow, 6) : baseWindow
        let perMsg = lowPower ? 220 : 380
        let total = lowPower ? 1800 : 3500

        let rows = messages.suffix(window).map { msg in
            let clipped = String(msg.text.prefix(perMsg))
            return "\(msg.role.uppercased()): \(clipped)"
        }
        return String(rows.joined(separator: "\n").prefix(total))
    }

    private func userExplicitlyAskedMemorySave(in prompt: String) -> Bool {
        let p = prompt.lowercased()

        let directTriggers = [
            "guardar en memoria", "guarda en memoria", "recuerda esto", "memoriza", "acuérdate", "acuerdate",
            "remember this", "save this"
        ]
        if directTriggers.contains(where: { p.contains($0) }) { return true }

        // Detecta variantes naturales: "guarda eso en memoria", "guárdalo", etc.
        if p.contains("guarda") && p.contains("memoria") { return true }
        if p.contains("guardar") && p.contains("memoria") { return true }
        if p.contains("guárdalo") || p.contains("guardalo") { return true }

        return false
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
