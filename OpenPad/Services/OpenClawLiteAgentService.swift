import Foundation
#if canImport(Speech)
import Speech
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

struct OpenClawAgentOutput {
    let text: String
    let trace: [String]
}

@MainActor
final class OpenClawLiteAgentService {
    private let localModelService = LocalModelService()
    private let tools = OpenClawLiteTools()
    private let runtimeConfig = LocalRuntimeConfig.shared
    private var lastAttachmentFileName: String?
    private let liteConfig = OpenClawLiteConfig.shared
    private let contextManager = OpenClawLiteContextManager.shared

    func respond(to userPrompt: String, recentMessages: [ChatMessage] = []) async throws -> OpenClawAgentOutput {
        var trace: [String] = []
        ensureAppMemoryFilesIfNeeded()
        trace.append("model_used=provider:\(runtimeConfig.loadProvider().rawValue.lowercased()) chat:\(runtimeConfig.loadMLXModelName()) tools:\(runtimeConfig.isSeparateMLXToolsModelEnabled() ? runtimeConfig.loadMLXToolsModelName() : runtimeConfig.loadMLXModelName())")

        if let routed = try await runDeterministicIntentRoute(userPrompt: userPrompt, recentMessages: recentMessages, trace: trace) {
            return routed
        }

        if shouldBypassPlannerForCurrentModel() {
            trace.append("Planner bypass: thinking model compatibility mode")

            var attachmentContext = buildAttachmentContext(from: userPrompt, recentMessages: recentMessages)
            let audioContext = await buildAudioContext(from: userPrompt)
            if !audioContext.isEmpty {
                attachmentContext += "\n\n[audio transcript]\n\(audioContext)"
                trace.append("Compat audio mode: attached transcription context")
            }

            if !attachmentContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               attachmentContext != "(no attachments)" {
                trace.append("Compat attachment mode: using injected attachment context")
                let prompt = """
                You are OpenClaw Lite in compatibility mode.
                Use ONLY the attachment context below. Do not invent facts.
                If evidence is missing, say: "No encuentro evidencia suficiente en el adjunto para afirmarlo." and ask for a clearer page/section.
                Include 1-2 short evidence quotes copied verbatim from the attachment context.
                Do not output JSON schemas.
                Do not include <think> blocks.

                Attachment context:
                \(attachmentContext)

                User question:
                \(userPrompt)
                """
                let override = multimodalOverrideModel(for: userPrompt)
                if let override { trace.append("Compat override model: \(override)") }
                let reply = try await localModelService.runLocal(prompt: prompt, purpose: .chat, modelOverride: override)
                let grounded = enforceGrounding(reply: reply, attachmentContext: attachmentContext)
                if grounded != reply {
                    trace.append("Grounding guard: replaced low-evidence answer")
                }
                return .init(text: grounded, trace: trace)
            }

            let directPrompt = buildDirectCompatPrompt(userPrompt: userPrompt, recentMessages: recentMessages)
            let override = multimodalOverrideModel(for: userPrompt)
            if let override { trace.append("Compat override model: \(override)") }
            let directReply = try await localModelService.runLocal(prompt: directPrompt, purpose: .chat, modelOverride: override)
            return .init(text: directReply, trace: trace)
        }

        let reasoningDraft = try await buildReasoningDraftIfNeeded(userPrompt: userPrompt, recentMessages: recentMessages)
        let firstPrompt = buildPlannerPrompt(userPrompt: userPrompt, recentMessages: recentMessages, reasoningDraft: reasoningDraft)
        let modelReply = try await localModelService.runLocal(prompt: firstPrompt, purpose: .tools)

        guard let decision = parseDecision(from: modelReply) else {
            if shouldForceAttachmentTool(userPrompt: userPrompt, recentMessages: recentMessages) {
                trace.append("Planner fallback: force attachment tool")
                let candidates = attachmentCandidates(from: userPrompt, recentMessages: recentMessages)
                if let file = candidates.first {
                    lastAttachmentFileName = file
                    let toolResult = await tools.execute(name: "analyze_attachment", arguments: ["fileName": file, "maxChars": "8000"])
                    trace.append("Tool result: \(toolResult.ok ? "ok" : "error")")
                    let secondPrompt = buildFinalizePrompt(userPrompt: userPrompt, toolName: "analyze_attachment", toolResult: toolResult)
                    let finalReply = try await localModelService.runLocal(prompt: secondPrompt, purpose: .chat)
                    return .init(text: extractContentFromJsonLike(finalReply) ?? finalReply, trace: trace)
                }
            }
            if shouldForceTimeTool(userPrompt) {
                trace.append("Planner fallback: force get_time tool")
                let toolResult = await tools.execute(name: "get_time", arguments: [:])
                let secondPrompt = buildFinalizePrompt(userPrompt: userPrompt, toolName: "get_time", toolResult: toolResult)
                let finalReply = try await localModelService.runLocal(prompt: secondPrompt, purpose: .chat)
                return .init(text: extractContentFromJsonLike(finalReply) ?? finalReply, trace: trace)
            }
            trace.append("Planner: no valid JSON, direct answer")
            return try await applyQualityGate(userPrompt: userPrompt, recentMessages: recentMessages, candidate: modelReply, trace: trace)
        }

        if decision.type == "final" {
            if shouldForceTimeTool(userPrompt) {
                trace.append("Planner override: force get_time tool")
                let toolResult = await tools.execute(name: "get_time", arguments: [:])
                let secondPrompt = buildFinalizePrompt(userPrompt: userPrompt, toolName: "get_time", toolResult: toolResult)
                let finalReply = try await localModelService.runLocal(prompt: secondPrompt, purpose: .chat)
                return .init(text: extractContentFromJsonLike(finalReply) ?? finalReply, trace: trace)
            }
            if shouldForceAttachmentTool(userPrompt: userPrompt, recentMessages: recentMessages) {
                trace.append("Planner override: force attachment tool for follow-up question")
                let candidates = attachmentCandidates(from: userPrompt, recentMessages: recentMessages)
                if let file = candidates.first {
                    lastAttachmentFileName = file
                    let toolResult = await tools.execute(name: "analyze_attachment", arguments: ["fileName": file, "maxChars": "8000"])
                    trace.append("Tool result: \(toolResult.ok ? "ok" : "error")")
                    let secondPrompt = buildFinalizePrompt(userPrompt: userPrompt, toolName: "analyze_attachment", toolResult: toolResult)
                    let finalReply = try await localModelService.runLocal(prompt: secondPrompt, purpose: .chat)
                    return .init(text: extractContentFromJsonLike(finalReply) ?? finalReply, trace: trace)
                }
            }
            trace.append("Planner: final without tools")
            return try await applyQualityGate(userPrompt: userPrompt, recentMessages: recentMessages, candidate: decision.content ?? modelReply, trace: trace)
        }

        guard decision.type == "tool_call", let name = decision.name else {
            trace.append("Planner: unknown output, direct answer")
            return try await applyQualityGate(userPrompt: userPrompt, recentMessages: recentMessages, candidate: modelReply, trace: trace)
        }

        trace.append("Tool call: \(name)")

        var toolName = name
        var toolArgs = decision.arguments ?? [:]

        let attachmentCandidatesAll = attachmentCandidates(from: userPrompt, recentMessages: recentMessages)
        let hasLocalAttachmentHint = !attachmentCandidatesAll.isEmpty || hasAttachmentHint(in: userPrompt)
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
            toolName = "analyze_attachment"
            if let f = attachmentCandidatesAll.first {
                lastAttachmentFileName = f
                toolArgs = ["fileName": f, "maxChars": "8000"]
                trace.append("Tool guard: web tool replaced with analyze_attachment (\(f))")
            } else {
                toolName = "keyword_extract"
                toolArgs = ["text": userPrompt, "top": "12"]
                trace.append("Tool guard: web tool blocked due to local attachment context")
            }
        }

        if toolName == "analyze_attachement" {
            toolName = "analyze_attachment"
            trace.append("Tool alias fix: analyze_attachement -> analyze_attachment")
        }

        if ["read_attachment", "analyze_attachment"].contains(toolName) {
            if (toolArgs["fileName"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let first = attachmentCandidatesAll.first {
                    lastAttachmentFileName = first
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
            return try await applyQualityGate(userPrompt: userPrompt, recentMessages: recentMessages, candidate: content, trace: trace)
        }

        if let extracted = extractContentFromJsonLike(finalReply), !extracted.isEmpty {
            trace.append("Finalize fallback: extracted content from malformed JSON")
            return try await applyQualityGate(userPrompt: userPrompt, recentMessages: recentMessages, candidate: extracted, trace: trace)
        }

        return try await applyQualityGate(userPrompt: userPrompt, recentMessages: recentMessages, candidate: finalReply, trace: trace)
    }

    private func applyQualityGate(userPrompt: String, recentMessages: [ChatMessage], candidate: String, trace: [String]) async throws -> OpenClawAgentOutput {
        var traceOut = trace
        let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        var score = 100
        var reasons: [String] = []

        let strictness = runtimeConfig.loadQualityGateStrictness()
        let threshold: Int = {
            switch strictness {
            case "relaxed": return 45
            case "strict": return 75
            default: return 60
            }
        }()

        if clean.count < 8 {
            score -= 25
            reasons.append("too_short")
        }

        if let lastAssistant = recentMessages.reversed().first(where: { $0.role.lowercased() == "assistant" })?.text,
           !lastAssistant.isEmpty,
           normalizedForCompare(lastAssistant) == normalizedForCompare(clean) {
            score -= 45
            reasons.append("repeated_answer")
        }

        if shouldForceAttachmentTool(userPrompt: userPrompt, recentMessages: recentMessages) {
            let attachmentContext = buildAttachmentContext(from: userPrompt, recentMessages: recentMessages)
            let overlap = sharedLongTokenCount(a: clean, b: attachmentContext)
            if overlap < 2 {
                score -= 50
                reasons.append("low_attachment_grounding")
            }
        }

        traceOut.append("quality_gate: strictness=\(strictness) score=\(score) threshold=\(threshold) reasons=\(reasons.isEmpty ? "ok" : reasons.joined(separator: ","))")

        guard score < threshold else {
            return .init(text: clean, trace: traceOut)
        }

        // One corrective pass only.
        if reasons.contains("low_attachment_grounding") {
            let candidates = attachmentCandidates(from: userPrompt, recentMessages: recentMessages)
            if let file = candidates.first {
                lastAttachmentFileName = file
                traceOut.append("corrective_pass: analyze_attachment(\(file))")
                let toolResult = await tools.execute(name: "analyze_attachment", arguments: ["fileName": file, "maxChars": "8000"])
                let secondPrompt = buildFinalizePrompt(userPrompt: userPrompt, toolName: "analyze_attachment", toolResult: toolResult)
                let reply = try await localModelService.runLocal(prompt: secondPrompt, purpose: .chat)
                let fixed = extractContentFromJsonLike(reply) ?? reply
                return .init(text: fixed.trimmingCharacters(in: .whitespacesAndNewlines), trace: traceOut)
            }
        }

        if reasons.contains("repeated_answer") && shouldForceTimeTool(userPrompt) {
            traceOut.append("corrective_pass: get_time")
            let toolResult = await tools.execute(name: "get_time", arguments: [:])
            let secondPrompt = buildFinalizePrompt(userPrompt: userPrompt, toolName: "get_time", toolResult: toolResult)
            let reply = try await localModelService.runLocal(prompt: secondPrompt, purpose: .chat)
            let fixed = extractContentFromJsonLike(reply) ?? reply
            return .init(text: fixed.trimmingCharacters(in: .whitespacesAndNewlines), trace: traceOut)
        }

        return .init(text: clean, trace: traceOut)
    }

    private func normalizedForCompare(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runDeterministicIntentRoute(userPrompt: String, recentMessages: [ChatMessage], trace: [String]) async throws -> OpenClawAgentOutput? {
        guard runtimeConfig.isIntentRouterEnabled() else { return nil }

        let lower = userPrompt.lowercased()
        let attachmentFiles = attachmentCandidates(from: userPrompt, recentMessages: recentMessages)
        let directURL = extractFirstURL(from: userPrompt)?.absoluteString

        // Intent: current time/date style queries should be deterministic.
        if runtimeConfig.isIntentRouteTimeEnabled(), shouldForceTimeTool(userPrompt) {
            var t = trace
            t.append("intent_router: intent=time_query confidence=high tool=get_time")
            runtimeConfig.incrementIntentRouteMetric("time_query")
            let toolResult = await tools.execute(name: "get_time", arguments: [:])
            let secondPrompt = buildFinalizePrompt(userPrompt: userPrompt, toolName: "get_time", toolResult: toolResult)
            let finalReply = try await localModelService.runLocal(prompt: secondPrompt, purpose: .chat)
            return .init(text: extractContentFromJsonLike(finalReply) ?? finalReply, trace: t)
        }

        // Intent: explicit local attachment questions should prioritize attachment tools.
        let asksAttachmentContent = lower.contains("pdf") || lower.contains("adjunto") || lower.contains("attachment") || lower.contains("archivo") || lower.contains("factura") || lower.contains("recibo") || lower.contains("invoice") || lower.contains("de que trata") || lower.contains("what does it say") || lower.contains("resumen") || lower.contains("summary")
        if runtimeConfig.isIntentRouteAttachmentEnabled(), asksAttachmentContent, let file = attachmentFiles.first {
            lastAttachmentFileName = file
            var t = trace
            t.append("intent_router: intent=attachment_query confidence=high tool=analyze_attachment file=\(file)")
            runtimeConfig.incrementIntentRouteMetric("attachment_query")
            var toolResult = await tools.execute(name: "analyze_attachment", arguments: ["fileName": file, "maxChars": "9000"])
            if !toolResult.ok {
                t.append("intent_router: corrective_pass=read_attachment")
                toolResult = await tools.execute(name: "read_attachment", arguments: ["fileName": file, "maxChars": "9000"])
            }
            let secondPrompt = buildFinalizePrompt(userPrompt: userPrompt, toolName: "analyze_attachment", toolResult: toolResult)
            let finalReply = try await localModelService.runLocal(prompt: secondPrompt, purpose: .chat)
            return .init(text: extractContentFromJsonLike(finalReply) ?? finalReply, trace: t)
        }

        // Intent: direct URL in prompt should use URL summarization without planner drift.
        if let directURL {
            var t = trace
            t.append("intent_router: intent=url_query confidence=high tool=summarize_url")
            let toolResult = await tools.execute(name: "summarize_url", arguments: ["url": directURL])
            let secondPrompt = buildFinalizePrompt(userPrompt: userPrompt, toolName: "summarize_url", toolResult: toolResult)
            let finalReply = try await localModelService.runLocal(prompt: secondPrompt, purpose: .chat)
            return .init(text: extractContentFromJsonLike(finalReply) ?? finalReply, trace: t)
        }

        // Intent: explicit request to list attachments.
        if lower.contains("lista adj") || lower.contains("list attachments") {
            var t = trace
            t.append("intent_router: intent=attachment_list confidence=high tool=list_attachments")
            let toolResult = await tools.execute(name: "list_attachments", arguments: [:])
            let secondPrompt = buildFinalizePrompt(userPrompt: userPrompt, toolName: "list_attachments", toolResult: toolResult)
            let finalReply = try await localModelService.runLocal(prompt: secondPrompt, purpose: .chat)
            return .init(text: extractContentFromJsonLike(finalReply) ?? finalReply, trace: t)
        }

        return nil
    }

    private func shouldBypassPlannerForCurrentModel() -> Bool {
        guard runtimeConfig.loadProvider() == .mlx else { return false }
        let model = runtimeConfig.loadMLXModelName().lowercased()
        if model.contains("thinking") || model.contains("lfm2.5") {
            return true
        }
        return false
    }

    private func multimodalOverrideModel(for userPrompt: String) -> String? {
        guard runtimeConfig.loadProvider() == .mlx,
              runtimeConfig.isMultimodalRoutingEnabled() else { return nil }

        let lower = userPrompt.lowercased()
        let vision = runtimeConfig.loadMLXVisionModelName().trimmingCharacters(in: .whitespacesAndNewlines)
        let audio = runtimeConfig.loadMLXAudioModelName().trimmingCharacters(in: .whitespacesAndNewlines)

        let hasImageHint = lower.contains("[foto:") || lower.contains("[foto-camara:") || lower.contains(".png") || lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains("imagen") || lower.contains("image")
        if hasImageHint, !vision.isEmpty { return vision }

        let hasAudioHint = lower.contains("[audio:") || lower.contains("audio") || lower.contains("voice") || lower.contains("speech")
        if hasAudioHint, !audio.isEmpty { return audio }

        return nil
    }

    private func buildDirectCompatPrompt(userPrompt: String, recentMessages: [ChatMessage]) -> String {
        let recent = buildRecentContext(from: recentMessages)
        let attachmentContext = buildAttachmentContext(from: userPrompt, recentMessages: recentMessages)
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

    private func buildReasoningDraftIfNeeded(userPrompt: String, recentMessages: [ChatMessage]) async throws -> String {
        guard runtimeConfig.loadProvider() == .mlx,
              runtimeConfig.isDualPassReasoningEnabled() else { return "" }

        let reasoningModel = runtimeConfig.loadMLXReasoningModelName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reasoningModel.isEmpty else { return "" }

        let recent = buildRecentContext(from: recentMessages)
        let attachmentContext = buildAttachmentContext(from: userPrompt, recentMessages: recentMessages)
        let prompt = """
        Create a concise reasoning draft for another assistant that will execute tools.
        Return ONLY short bullets with concrete facts, constraints, unknowns, and recommended next action.
        No JSON.
        No <think> blocks.

        Attachment context:
        \(attachmentContext)

        Recent context:
        \(recent)

        User request:
        \(userPrompt)
        """

        let draft = try await localModelService.runLocal(prompt: prompt, purpose: .chat, modelOverride: reasoningModel)
        return String(draft.prefix(1400))
    }

    private func buildPlannerPrompt(userPrompt: String, recentMessages: [ChatMessage], reasoningDraft: String) -> String {
        let profile = runtimeConfig.loadRunProfile()
        let lowPower = OpenClawLiteConfig.shared.isLowPowerModeEnabled()
        let budget = contextManager.budget(profile: profile, lowPower: lowPower)
        let memoryLimit = lowPower ? 4 : (profile == .turbo ? 10 : 6)
        let memoryContext = String(tools.recentMemories(limit: memoryLimit).prefix(budget.memoryChars))
        let appIdentityContext = String(appMemoryContext(maxChars: lowPower ? 1200 : 2600).prefix(budget.memoryChars))
        let attachmentContext = buildAttachmentContext(from: userPrompt, recentMessages: recentMessages)
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

        Reasoning draft (if available):
        \(reasoningDraft.isEmpty ? "(none)" : reasoningDraft)

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
        let keys = ["content", "response", "answer", "message", "output", "text", "respuesta", "respuesta final", "respuesta_final", "final_answer"]
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
            #"\"respuesta\"\s*:\s*\"((?:\\.|[^\"])*)\""#,
            #"\"respuesta final\"\s*:\s*\"((?:\\.|[^\"])*)\""#,
            #"\"respuesta_final\"\s*:\s*\"((?:\\.|[^\"])*)\""#,
            #"content\s*[:=]\s*\"([^\"]+)\""#,
            #"response\s*[:=]\s*\"([^\"]+)\""#,
            #"respuesta\s*[:=]\s*\"([^\"]+)\""#
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

    private func buildAttachmentContext(from prompt: String, recentMessages: [ChatMessage]) -> String {
        var names = extractAttachmentNames(from: prompt)

        if names.isEmpty {
            let lower = prompt.lowercased()
            let genericAttachmentAsk = lower.contains("pdf") || lower.contains("adjunto") || lower.contains("archivo") || lower.contains("attachment")
            if genericAttachmentAsk {
                names = recentAttachmentNames(from: recentMessages)
            }
        }

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

    private func enforceGrounding(reply: String, attachmentContext: String) -> String {
        let evidenceScore = sharedLongTokenCount(a: reply, b: attachmentContext)
        if evidenceScore >= 2 { return reply }
        return "No encuentro evidencia suficiente en el adjunto para afirmarlo. Compárteme el nombre exacto del archivo o una página/sección específica y lo verifico textual."
    }

    private func sharedLongTokenCount(a: String, b: String) -> Int {
        func tokens(_ s: String) -> Set<String> {
            let raw = s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            return Set(raw.filter { $0.count >= 6 })
        }
        return tokens(a).intersection(tokens(b)).count
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

    private func recentAttachmentNames(from messages: [ChatMessage]) -> [String] {
        for msg in messages.reversed() {
            if msg.role.lowercased() != "user" { continue }
            let names = extractAttachmentNames(from: msg.text)
            if !names.isEmpty { return names }
        }
        return []
    }

    private func attachmentCandidates(from prompt: String, recentMessages: [ChatMessage]) -> [String] {
        let direct = extractAttachmentNames(from: prompt)
        if !direct.isEmpty { return direct }

        let recent = recentAttachmentNames(from: recentMessages)
        if !recent.isEmpty { return recent }

        if let remembered = lastAttachmentFileName, !remembered.isEmpty {
            return [remembered]
        }
        return []
    }

    private func shouldForceAttachmentTool(userPrompt: String, recentMessages: [ChatMessage]) -> Bool {
        let candidates = attachmentCandidates(from: userPrompt, recentMessages: recentMessages)
        guard !candidates.isEmpty else { return false }
        let lower = userPrompt.lowercased()
        if lower.contains("pdf") || lower.contains("adjunto") || lower.contains("attachment") || lower.contains("archivo") {
            return true
        }
        // Follow-up questions like "what does it say?" should still use the latest attachment.
        return lower.contains("de que") || lower.contains("qué") || lower.contains("what") || lower.contains("resume") || lower.contains("summary")
    }

    private func shouldForceTimeTool(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return lower.contains("hora") || lower.contains("qué hora") || lower.contains("que hora") || lower.contains("time") || lower.contains("current time") || lower.contains("fecha") || lower.contains("date today")
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

    private func buildAudioContext(from prompt: String) async -> String {
        let names = extractAttachmentNames(from: prompt)
        guard !names.isEmpty else { return "" }

        let audioNames = names.filter { n in
            let l = n.lowercased()
            return l.hasSuffix(".m4a") || l.hasSuffix(".mp3") || l.hasSuffix(".wav") || l.hasSuffix(".aac") || l.hasSuffix(".caf")
        }
        guard !audioNames.isEmpty else { return "" }

        var rows: [String] = []
        for name in audioNames.prefix(1) {
            if let url = resolveAttachmentURL(fileName: name),
               let transcript = await transcribeAudio(url: url),
               !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows.append("[\(name)]\n\(String(transcript.prefix(2400)))")
            }
        }
        return rows.joined(separator: "\n\n")
    }

    private func resolveAttachmentURL(fileName: String) -> URL? {
        do {
            let docs = try LocalModelConfig.shared.documentsDirectory()
            let dir = docs.appendingPathComponent("OpenClawFiles/Attachments", isDirectory: true)
            let exact = dir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: exact.path) { return exact }

            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let lower = fileName.lowercased()
            if let ci = items.first(where: { $0.lastPathComponent.lowercased() == lower }) {
                return ci
            }
            let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.lowercased()
            if let partial = items.first(where: { $0.lastPathComponent.lowercased().contains(stem) }) {
                return partial
            }
            return nil
        } catch {
            return nil
        }
    }

    private func transcribeAudio(url: URL) async -> String? {
        #if canImport(Speech)
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else { return nil }

        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else { return nil }

        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                    let req = SFSpeechURLRecognitionRequest(url: url)
                    req.shouldReportPartialResults = false
                    var resumed = false
                    recognizer.recognitionTask(with: req) { result, error in
                        if resumed { return }
                        if error != nil {
                            resumed = true
                            cont.resume(returning: nil)
                            return
                        }
                        if let result, result.isFinal {
                            resumed = true
                            cont.resume(returning: result.bestTranscription.formattedString)
                        }
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                        if !resumed {
                            resumed = true
                            cont.resume(returning: nil)
                        }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 13_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #else
        _ = url
        return nil
        #endif
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

        return "Respond in the user's language when obvious. Otherwise default to the iPad preferred language (\(languageCode))."
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
            try ensureFile(named: "POLICY.md", in: dir, defaultText: "# POLICY\n- Prefer grounded answers with evidence from attachments/files.\n- If evidence is weak, say so explicitly.\n- Keep replies concise unless user asks for depth.\n")
            try ensureFile(named: "ROUTING.md", in: dir, defaultText: "# ROUTING\n- Default: local model.\n- Use tools only when needed.\n- In compatibility mode, prioritize attachment context over web fetches.\n")
            try ensureFile(named: "TOOL_RULES.md", in: dir, defaultText: "# TOOL_RULES\n- Destructive actions require explicit confirmation.\n- Prefer read/inspect before write/delete.\n- For attachment questions, use attachment tools/context first.\n")
        } catch {
            // Non-fatal.
        }
    }

    private func appMemoryContext(maxChars: Int) -> String {
        do {
            let dir = try appMemoryDirectory()
            let files = ["SOUL.md", "IDENTITY.md", "USER.md", "TOOLS.md", "HEARTBEAT.md", "POLICY.md", "ROUTING.md", "TOOL_RULES.md"]
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

