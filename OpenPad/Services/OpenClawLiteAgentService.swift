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
    private let contextManager = OpenClawLiteContextManager.shared

    func respond(to userPrompt: String, recentMessages: [ChatMessage] = []) async throws -> OpenClawAgentOutput {
        var trace: [String] = []
        ensureAppMemoryFilesIfNeeded()

        if shouldBypassPlannerForCurrentModel() {
            trace.append("Planner bypass: thinking model compatibility mode")
            let directPrompt = buildDirectCompatPrompt(userPrompt: userPrompt, recentMessages: recentMessages)
            let directReply = try await localModelService.runLocal(prompt: directPrompt, purpose: .chat)
            return .init(text: directReply, trace: trace)
        }

        let firstPrompt = buildPlannerPrompt(userPrompt: userPrompt, recentMessages: recentMessages)
        let modelReply = try await localModelService.runLocal(prompt: firstPrompt, purpose: .tools)

        guard let decision = parseDecision(from: modelReply) else {
            trace.append("Planner: no valid JSON, direct answer")
            return .init(text: modelReply, trace: trace)
        }

        if decision.type == "final" {
            trace.append("Planner: final without tools")
            return .init(text: decision.content ?? modelReply, trace: trace)
        }

        guard decision.type == "tool_call", let name = decision.name else {
            trace.append("Planner: unknown output, direct answer")
            return .init(text: modelReply, trace: trace)
        }

        trace.append("Tool call: \(name)")

        var toolName = name
        var toolArgs = decision.arguments ?? [:]

        let hasLocalAttachmentHint = hasAttachmentHint(in: userPrompt)
        if let directURL = extractFirstURL(from: userPrompt)?.absoluteString {
            if name == "brave_search" {
                toolName = "http_get"
                toolArgs = ["url": directURL, "allow_host": "true"]
                trace.append("Tool rewrite: brave_search -> http_get (URL directa)")
            } else if name == "http_get" {
                toolArgs["url"] = toolArgs["url"] ?? directURL
                toolArgs["allow_host"] = "true"
                trace.append("Tool override: allow_host=true due to explicit direct URL request")
            }
        } else if hasLocalAttachmentHint, ["http_get", "summarize_url", "brave_search"].contains(name) {
            toolName = "keyword_extract"
            toolArgs = ["text": userPrompt, "top": "12"]
            trace.append("Tool guard: web tool blocked due to local attachment context")
        }

        if toolName == "analyze_attachement" {
            toolName = "analyze_attachment"
            trace.append("Tool alias fix: analyze_attachement -> analyze_attachment")
        }

        if ["read_attachment", "analyze_attachment"].contains(toolName) {
            if (toolArgs["fileName"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let candidates = extractAttachmentNames(from: userPrompt)
                if let first = candidates.first {
                    toolArgs["fileName"] = first
                    trace.append("Tool arg autofill: fileName=\(first)")
                }
            }
        }

        if toolName == "save_memory" && !userExplicitlyAskedMemorySave(in: userPrompt) {
            trace.append("Tool blocked: save_memory not explicitly requested")
            return .init(text: "Understood. I will not save it to memory unless you ask explicitly.", trace: trace)
        }

        var toolResult = await tools.execute(name: toolName, arguments: toolArgs)
        trace.append("Tool result: \(toolResult.ok ? "ok" : "error")")

        // Persistencia: un intento adicional antes de rendirse.
        if !toolResult.ok {
            trace.append("Retry policy: second tool attempt")
            toolResult = await tools.execute(name: toolName, arguments: toolArgs)
            trace.append("Retry result: \(toolResult.ok ? "ok" : "error")")
        }

        let secondPrompt = buildFinalizePrompt(userPrompt: userPrompt, toolName: toolName, toolResult: toolResult)
        let finalReply = try await localModelService.runLocal(prompt: secondPrompt, purpose: .chat)

        if let finalDecision = parseDecision(from: finalReply), let content = finalDecision.content, !content.isEmpty {
            return .init(text: content, trace: trace)
        }

        if let extracted = extractContentFromJsonLike(finalReply), !extracted.isEmpty {
            trace.append("Finalize fallback: extracted content from malformed JSON")
            return .init(text: extracted, trace: trace)
        }

        return .init(text: finalReply, trace: trace)
    }

    private func shouldBypassPlannerForCurrentModel() -> Bool {
        guard runtimeConfig.loadProvider() == .mlx else { return false }
        let model = runtimeConfig.loadMLXModelName().lowercased()
        if model.contains("thinking") || model.contains("lfm2.5") {
            return true
        }
        return false
    }

    private func buildDirectCompatPrompt(userPrompt: String, recentMessages: [ChatMessage]) -> String {
        let recent = buildRecentContext(from: recentMessages)
        let attachmentContext = buildAttachmentContext(from: userPrompt)
        let languageInstruction = preferredLanguageInstruction()
        return """
        You are OpenClaw Lite running in compatibility mode for reasoning-heavy models.
        \(languageInstruction)
        Do not output JSON schemas or planning structures.
        Do not include <think> blocks.
        If attachments are present, prioritize them.

        Attachment context:
        \(attachmentContext)

        Recent context:
        \(recent)

        User message:
        \(userPrompt)
        """
    }

    private func buildPlannerPrompt(userPrompt: String, recentMessages: [ChatMessage]) -> String {
        let profile = runtimeConfig.loadRunProfile()
        let lowPower = OpenClawLiteConfig.shared.isLowPowerModeEnabled()
        let budget = contextManager.budget(profile: profile, lowPower: lowPower)
        let memoryLimit = lowPower ? 4 : (profile == .turbo ? 10 : 6)
        let memoryContext = String(tools.recentMemories(limit: memoryLimit).prefix(budget.memoryChars))
        let appIdentityContext = String(appMemoryContext(maxChars: lowPower ? 1200 : 2600).prefix(budget.memoryChars))
        let attachmentContext = buildAttachmentContext(from: userPrompt)
        let recentContext = buildRecentContext(from: recentMessages)
        let languageInstruction = preferredLanguageInstruction()
        return """
        Eres OpenClaw Lite en iPad.
        \(languageInstruction)
        Decide your next action and respond ONLY in valid JSON.
        Execution policy: be persistent. Before concluding something failed, attempt at least one alternative approach or a reasonable retry.
        Safety policy: for destructive tools (`delete_file`, `clear_memories`) require `confirm=YES`.
        \(liteConfig.isAutodevEnabled() ? "AutoDev: al final sugiere una micro-mejora concreta, reversible y de bajo riesgo." : "AutoDev desactivado.")
        You may use the internet when it helps provide a better answer.
        Si el usuario comparte una URL completa, prioriza `http_get` para leerla/resumirla directamente.
        If the user mentions local attachments (e.g. [attachment: ...], [photo: ...], or filename), ALWAYS prioritize injected attachment context and avoid `http_get/summarize_url` unless an explicit URL is also present.
        Memory rule: ONLY use `save_memory` when the user explicitly asks (e.g., "save to memory", "remember this").

        Persistent recent memory (survives restarts):
        \(memoryContext)

        Identity/role context (SOUL/IDENTITY/USER/TOOLS/HEARTBEAT):
        \(appIdentityContext)

        Attachment context detected in this message:
        \(attachmentContext)

        Recent conversation context:
        \(recentContext)

        Tools available (examples):
        - get_time(arguments: {})
        - save_memory/list_memories/search_memories/clear_memories
        - read_file/write_file/list_files/file_exists/append_file/delete_file
        - list_attachments/read_attachment/analyze_attachment
        - calendar_today/summarize_url/http_get/brave_search
        - calculate/make_uuid/json_parse/csv_preview/markdown_toc/diff_text
        - regex_extract/base64_encode/base64_decode/url_encode/url_decode
        - json_path/csv_filter/html_to_text/keyword_extract/chunk_text
        - extract_code_blocks/lint_markdown/table_to_bullets/normalize_whitespace
        - word_count/text_stats/extract_emails/extract_urls

        Output schema:
        - respuesta final:
          {"type":"final","content":"..."}
        - llamada de herramienta:
          {"type":"tool_call","name":"get_time|save_memory|list_memories|search_memories|clear_memories|read_file|write_file|list_files|file_exists|append_file|delete_file|list_attachments|read_attachment|analyze_attachment|calendar_today|summarize_url|http_get|brave_search|calculate|make_uuid|json_parse|csv_preview|markdown_toc|diff_text|regex_extract|base64_encode|base64_decode|url_encode|url_decode|json_path|csv_filter|html_to_text|keyword_extract|chunk_text|extract_code_blocks|lint_markdown|table_to_bullets|normalize_whitespace|word_count|text_stats|extract_emails|extract_urls","arguments":{"key":"value"}}

        Mensaje del usuario:
        \(userPrompt)
        """
    }

    private func buildFinalizePrompt(userPrompt: String, toolName: String, toolResult: OpenClawToolResult) -> String {
        let languageInstruction = preferredLanguageInstruction()
        return """
        Eres OpenClaw Lite en iPad.
        You already called a tool. Provide the final user answer in valid JSON.
        \(languageInstruction)

        Esquema de salida:
        {"type":"final","content":"..."}

        Mensaje original del usuario:
        \(userPrompt)

        Herramienta llamada:
        \(toolName)

        Tool success:
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

        if let generic = decodeGenericFinal(from: raw) {
            return AgentDecision(type: "final", content: generic, name: nil, arguments: nil)
        }

        return heuristicDecision(from: text)
    }

    private func decodeDecision(from json: String) -> AgentDecision? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentDecision.self, from: data)
    }

    private func decodeGenericFinal(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let keys = ["content", "response", "answer", "message", "output", "text"]
        for k in keys {
            if let v = obj[k] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return v.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
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
            for name in ["get_time", "save_memory", "list_memories", "search_memories", "clear_memories", "read_file", "write_file", "list_files", "file_exists", "append_file", "delete_file", "list_attachments", "read_attachment", "analyze_attachment", "calendar_today", "summarize_url", "http_get", "brave_search", "calculate", "make_uuid", "json_parse", "csv_preview", "markdown_toc", "diff_text", "regex_extract", "base64_encode", "base64_decode", "url_encode", "url_decode", "json_path", "csv_filter", "html_to_text", "keyword_extract", "chunk_text", "extract_code_blocks", "lint_markdown", "table_to_bullets", "normalize_whitespace", "word_count", "text_stats", "extract_emails", "extract_urls"] {
                if lower.contains(name) {
                    return AgentDecision(type: "tool_call", content: nil, name: name, arguments: [:])
                }
            }
        }
        return nil
    }

    private func normalize(_ decision: AgentDecision) -> AgentDecision {
        var normalizedName = decision.name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":,;"))

        let aliases: [String: String] = [
            "analyze_attachement": "analyze_attachment",
            "read_attachement": "read_attachment"
        ]
        if let n = normalizedName?.lowercased(), let alias = aliases[n] {
            normalizedName = alias
        }

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
        // Extract common final-text fields from malformed JSON/JSON-like outputs.
        let patterns = [
            #"\"content\"\s*:\s*\"((?:\\.|[^\"])*)\""#,
            #"\"response\"\s*:\s*\"((?:\\.|[^\"])*)\""#,
            #"\"answer\"\s*:\s*\"((?:\\.|[^\"])*)\""#,
            #"\"message\"\s*:\s*\"((?:\\.|[^\"])*)\""#,
            #"content\s*[:=]\s*\"([^\"]+)\""#,
            #"response\s*[:=]\s*\"([^\"]+)\""#
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
        guard !names.isEmpty else { return "(no attachments)" }

        var chunks: [String] = []
        let lowPower = OpenClawLiteConfig.shared.isLowPowerModeEnabled()
        let profile = runtimeConfig.loadRunProfile()
        let budget = contextManager.budget(profile: profile, lowPower: lowPower)
        let attachmentLimit = lowPower ? 1 : (profile == .turbo ? 3 : 2)
        let maxChars = budget.attachmentChars
        for name in names.prefix(attachmentLimit) {
            let snippet = tools.readAttachmentSnippet(fileName: name, maxChars: maxChars)
            if snippet.isEmpty {
                chunks.append("[\(name)] (could not read it automatically)")
            } else {
                chunks.append("[\(name)]\n\(snippet)")
            }
        }
        return chunks.joined(separator: "\n\n")
    }

    private func hasAttachmentHint(in text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("[adjunto:") || lower.contains("[foto:") || lower.contains("[foto-camara:") {
            return true
        }
        let pattern = #"\b[A-Za-z0-9_\-\.]+\.(?:pdf|jpg|jpeg|png|heic|webp|txt|md|csv|log)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private func extractAttachmentNames(from text: String) -> [String] {
        var out: [String] = []

        // Explicit format: [attachment: file.pdf], [photo: x.jpg], etc.
        let bracketPattern = #"\[(?:adjunto|foto|foto-camara)\s*:\s*([^\]]+)\]"#
        if let regex = try? NSRegularExpression(pattern: bracketPattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            out += matches.compactMap { m in
                guard let r = Range(m.range(at: 1), in: text) else { return nil }
                return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Formato libre: menciones tipo "archivo.pdf" en el mensaje.
        let plainPattern = #"\b([A-Za-z0-9_\-\.]+\.(?:pdf|jpg|jpeg|png|heic|webp|txt|md|csv|log))\b"#
        if let regex = try? NSRegularExpression(pattern: plainPattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            out += matches.compactMap { m in
                guard let r = Range(m.range(at: 1), in: text) else { return nil }
                return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Deduplicado preservando orden.
        var seen = Set<String>()
        return out.filter { name in
            let key = name.lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private func buildRecentContext(from messages: [ChatMessage]) -> String {
        guard !messages.isEmpty else { return "(no recent history)" }
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
            "save to memory", "save to memory", "remember this", "memorize this", "remember this", "remember this",
            "remember this", "save this"
        ]
        if directTriggers.contains(where: { p.contains($0) }) { return true }

        // Detect natural variants: "save that to memory", "remember it", etc.
        if p.contains("save") && p.contains("memory") { return true }
        if p.contains("saver") && p.contains("memory") { return true }
        if p.contains("save it") || p.contains("savelo") { return true }

        return false
    }

    private func preferredLanguageInstruction() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let normalized = preferred.replacingOccurrences(of: "_", with: "-")
        let languageCode = normalized.split(separator: "-").first.map { String($0).lowercased() } ?? "en"

        switch languageCode {
        case "es":
            return "Respond in English by default unless the user asks for another language."
        case "en":
            return "Respond in English by default, unless the user asks for another language."
        case "pt":
            return "Respond in Portuguese by default, unless the user asks for another language."
        case "fr":
            return "Respond in French by default, unless the user asks for another language."
        default:
            return "Respond in the iPad preferred language (\(languageCode)) by default, unless the user asks for another language."
        }
    }

    private func ensureAppMemoryFilesIfNeeded() {
        do {
            let dir = try appMemoryDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ensureFile(named: "SOUL.md", in: dir, defaultText: "# SOUL\nBe genuinely helpful, concise when possible, and thorough when needed.\n")
            try ensureFile(named: "IDENTITY.md", in: dir, defaultText: "# IDENTITY\nName: OpenPad\nRole: Local-first iPad assistant\n")
            try ensureFile(named: "USER.md", in: dir, defaultText: "# USER\nName:\nPreferences:\n")
            try ensureFile(named: "TOOLS.md", in: dir, defaultText: "# TOOLS\nLocal notes and environment-specific details.\n")
            try ensureFile(named: "HEARTBEAT.md", in: dir, defaultText: "# HEARTBEAT\nKeep checks lightweight and avoid unnecessary background work.\n")
        } catch {
            // Non-fatal.
        }
    }

    private func appMemoryContext(maxChars: Int) -> String {
        do {
            let dir = try appMemoryDirectory()
            let files = ["SOUL.md", "IDENTITY.md", "USER.md", "TOOLS.md", "HEARTBEAT.md"]
            var chunks: [String] = []
            for f in files {
                let url = dir.appendingPathComponent(f)
                if let text = try? String(contentsOf: url, encoding: .utf8),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chunks.append("[\(f)]\n\(text)")
                }
            }
            if chunks.isEmpty { return "(no app memory files yet)" }
            return String(chunks.joined(separator: "\n\n").prefix(maxChars))
        } catch {
            return "(app memory unavailable)"
        }
    }

    private func appMemoryDirectory() throws -> URL {
        let docs = try LocalModelConfig.shared.documentsDirectory()
        return docs.appendingPathComponent("OpenClawMemory/AppMemory", isDirectory: true)
    }

    private func ensureFile(named file: String, in dir: URL, defaultText: String) throws {
        let url = dir.appendingPathComponent(file)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try defaultText.write(to: url, atomically: true, encoding: .utf8)
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
