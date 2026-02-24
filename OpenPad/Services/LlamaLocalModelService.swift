import Foundation

#if canImport(LlamaCpp)
import LlamaCpp
#endif

#if canImport(LlamaSwift)
import LlamaSwift
#endif

#if canImport(llama)
import llama
#endif

enum LlamaServiceError: LocalizedError {
    case modelNotConfigured
    case modelFileNotFound(String)
    case backendUnavailable
    case invalidBaseURL
    case badStatus(Int, String)
    case emptyResponse
    case nonLocalEndpointBlocked
    case nativeBackendRequired
    case nativeBackendUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelNotConfigured:
            return "No model configured. Set a .gguf path first."
        case .modelFileNotFound(let path):
            return "Model not found at: \(path)"
        case .backendUnavailable:
            return "Backend llama.cpp no disponible. Levanta llama-server o integra el paquete nativo."
        case .invalidBaseURL:
            return "Invalid llama.cpp URL"
        case .badStatus(let code, let body):
            return "llama.cpp HTTP \(code): \(body.prefix(180))"
        case .emptyResponse:
            return "llama.cpp returned an empty response"
        case .nonLocalEndpointBlocked:
            return "llama.cpp endpoint must be local (127.0.0.1/localhost) in offline strict mode"
        case .nativeBackendRequired:
            return "Offline strict mode requires native llama.cpp backend or local llama-server on loopback"
        case .nativeBackendUnavailable(let reason):
            return "Native llama.cpp unavailable: \(reason)"
        }
    }
}

final class LlamaLocalModelService {
    static var hasNativeModule: Bool { LlamaNativeAdapter.shared.hasAnyNativeModule }
    static var isNativeBackendReady: Bool { LlamaNativeAdapter.shared.isGenerationAvailable }

    private var modelPath: String?
    private let runtimeConfig = LocalRuntimeConfig.shared
    private let native = LlamaNativeAdapter.shared

    func configureModel(path: String) throws {
        let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LlamaServiceError.modelNotConfigured }
        guard FileManager.default.fileExists(atPath: clean) else {
            throw LlamaServiceError.modelFileNotFound(clean)
        }
        modelPath = clean
    }

    func runLocal(prompt: String) async throws -> String {
        guard let modelPath else {
            throw LlamaServiceError.modelNotConfigured
        }

        let strictOffline = runtimeConfig.isOfflineStrictModeEnabled()

        // Native-first path (GGUF on-device) when module is present and adapter is wired.
        do {
            if let nativeOut = try await native.generate(prompt: prompt, modelPath: modelPath) {
                let clean = nativeOut.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    if !isLikelyLowQuality(clean) {
                        return clean
                    }
                    if strictOffline {
                        throw LlamaServiceError.nativeBackendUnavailable("native backend returned low-quality output")
                    }
                } else if strictOffline {
                    throw LlamaServiceError.nativeBackendUnavailable("native backend returned empty output")
                }
            }
        } catch {
            if strictOffline {
                // In strict mode, do not fallback to any non-local path.
                let cfg = runtimeConfig.loadLlama()
                if let base = URL(string: cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), isLocalEndpoint(base) {
                    // Local loopback llama-server is allowed in strict mode.
                } else {
                    throw (error as? LlamaServiceError) ?? LlamaServiceError.nativeBackendUnavailable(error.localizedDescription)
                }
            }
        }

        // If strict mode is enabled, only loopback llama-server is allowed as fallback.
        if strictOffline {
            let cfg = runtimeConfig.loadLlama()
            guard let base = URL(string: cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  isLocalEndpoint(base) else {
                throw LlamaServiceError.nonLocalEndpointBlocked
            }
        }

        let out = try await runViaLlamaServer(prompt: prompt, modelPath: modelPath)
        if strictOffline, out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LlamaServiceError.nativeBackendRequired
        }
        return out
    }

    private func runViaLlamaServer(prompt: String, modelPath: String) async throws -> String {
        let cfg = runtimeConfig.loadLlama()
        guard let rawBase = URL(string: cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LlamaServiceError.invalidBaseURL
        }

        let base = completionsURL(from: rawBase)

        let explicitModel = cfg.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = explicitModel.isEmpty
            ? URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
            : explicitModel

        let profile = runtimeConfig.loadRunProfile()
        let decodingParams: (temperature: Double, maxTokens: Int, topP: Double?)
        switch profile {
        case .stable:
            decodingParams = (temperature: 0.12, maxTokens: 220, topP: 0.9)
        case .balanced:
            decodingParams = (temperature: 0.2, maxTokens: 256, topP: 0.92)
        case .turbo:
            decodingParams = (temperature: 0.3, maxTokens: 320, topP: 0.95)
        }

        let payload = LlamaChatRequest(
            model: modelName,
            messages: [
                .init(role: "system", content: "You are OpenPad, a helpful and concise assistant."),
                .init(role: "user", content: prompt)
            ],
            temperature: decodingParams.temperature,
            topP: decodingParams.topP,
            stream: false,
            maxTokens: decodingParams.maxTokens,
            stop: ["\nUser:", "\nUSER:", "\nAssistant:", "\nSYSTEM:", "<|eot_id|>"],
            repetitionPenalty: 1.08
        )

        var req = URLRequest(url: base)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw LlamaServiceError.emptyResponse
            }
            guard (200...299).contains(http.statusCode) else {
                throw LlamaServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }

            if let decoded = try? JSONDecoder().decode(LlamaChatResponse.self, from: data),
               let text = decoded.choices.first?.message.content {
                let sanitized = sanitizeGeneratedText(text)
                if !sanitized.isEmpty {
                    return sanitized
                }
            }

            if let asText = String(data: data, encoding: .utf8),
               let raw = extractContentField(from: asText) {
                let sanitized = sanitizeGeneratedText(raw)
                if !sanitized.isEmpty {
                    return sanitized
                }
            }

            throw LlamaServiceError.emptyResponse
        } catch let e as LlamaServiceError {
            throw e
        } catch {
            throw LlamaServiceError.backendUnavailable
        }
    }

    private func isLocalEndpoint(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" { return true }
        return false
    }

    private func completionsURL(from base: URL) -> URL {
        let normalizedPath = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.hasSuffix("v1/chat/completions") {
            return base
        }
        if normalizedPath.hasSuffix("chat/completions") {
            return base
        }

        var resolved = base
        if normalizedPath.hasSuffix("v1") {
            resolved.append(path: "chat/completions")
        } else {
            resolved.append(path: "v1/chat/completions")
        }
        return resolved
    }

    private func isLikelyLowQuality(_ text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return true }

        let lower = clean.lowercased()
        if lower.contains("siri:1") || lower.contains("tiempo:1") || lower.contains("paga:1") {
            return true
        }

        // Prompt-echo junk sometimes leaks from native decode loops.
        if (lower.contains("system:") && lower.contains("user:")) ||
            lower.hasPrefix("assistant:") ||
            lower.contains("<|start_header_id|>") ||
            lower.contains("<|end_header_id|>") {
            return true
        }

        if let regex = try? NSRegularExpression(pattern: #"\b[\p{L}_-]{2,}:\d+\b"#, options: []) {
            let ns = NSRange(clean.startIndex..., in: clean)
            let matches = regex.matches(in: clean, options: [], range: ns)
            if matches.count >= 3 {
                return true
            }
        }

        let words = clean.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        if words.count < 2 && clean.count > 24 {
            return true
        }

        // Repetition detector: long outputs with very low unique-word ratio are usually loops.
        if words.count >= 24 {
            let normalizedWords = words.map { $0.lowercased() }
            let uniqueRatio = Double(Set(normalizedWords).count) / Double(normalizedWords.count)
            if uniqueRatio < 0.28 {
                return true
            }
        }

        return false
    }

    private func extractContentField(from text: String) -> String? {
        let patterns = [
            #"\"content\"\s*:\s*\"((?:\\.|[^\"])*)\""#,
            #"\"text\"\s*:\s*\"((?:\\.|[^\"])*)\""#
        ]
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p) else { continue }
            let ns = NSRange(text.startIndex..., in: text)
            guard let m = regex.firstMatch(in: text, options: [], range: ns),
                  let r = Range(m.range(at: 1), in: text) else { continue }
            return String(text[r])
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

private struct LlamaNativeAdapter {
    static let shared = LlamaNativeAdapter()

    private let runtimeConfig = LocalRuntimeConfig.shared

    private init() {}

    var hasAnyNativeModule: Bool {
        #if canImport(LlamaCpp) || canImport(llama) || canImport(LlamaSwift)
        true
        #else
        false
        #endif
    }

    var isGenerationAvailable: Bool {
        #if canImport(llama) || canImport(LlamaSwift)
        true
        #else
        false
        #endif
    }

    func generate(prompt: String, modelPath: String) async throws -> String? {
        #if canImport(LlamaCpp)
        // Compile-safe hook for Swift wrappers exposing module `LlamaCpp`.
        // Keep this shim API-agnostic; concrete package wiring can be done here
        // without touching call sites. Until bound, prefer graceful fallback.
        _ = prompt
        _ = modelPath
        return nil
        #elseif canImport(LlamaSwift) || canImport(llama)
        // Important: run native decode off the main actor/thread.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let out = try generateWithLlamaModuleSync(prompt: prompt, modelPath: modelPath)
                    continuation.resume(returning: out)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        #else
        return nil
        #endif
    }

    #if canImport(LlamaSwift) || canImport(llama)
    private func generateWithLlamaModuleSync(prompt: String, modelPath: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw LlamaServiceError.modelFileNotFound(modelPath)
        }

        llama_backend_init()
        defer { llama_backend_free() }

        var modelParams = llama_model_default_params()
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaServiceError.nativeBackendUnavailable("failed to load GGUF model")
        }
        defer { llama_model_free(model) }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 2048
        ctxParams.n_batch = 512
        guard let ctx = llama_init_from_model(model, ctxParams) else {
            throw LlamaServiceError.nativeBackendUnavailable("failed to create llama context")
        }
        defer { llama_free(ctx) }

        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else { return nil }

        let vocab = llama_model_get_vocab(model)
        let formattedPrompt = buildAssistantPrompt(from: normalizedPrompt)

        var tokens = try tokenize(prompt: formattedPrompt, vocab: vocab)
        if tokens.isEmpty { return nil }

        let profile = runtimeConfig.loadRunProfile()
        let maxNewTokens: Int
        let temperature: Float
        let topP: Float
        let repetitionPenalty: Float
        switch profile {
        case .stable:
            maxNewTokens = 192
            temperature = 0.22
            topP = 0.9
            repetitionPenalty = 1.10
        case .balanced:
            maxNewTokens = 256
            temperature = 0.32
            topP = 0.92
            repetitionPenalty = 1.08
        case .turbo:
            maxNewTokens = 320
            temperature = 0.42
            topP = 0.95
            repetitionPenalty = 1.06
        }

        // Stability guard: keep prompt length below context window to avoid ggml aborts.
        let maxPromptTokens = max(64, Int(ctxParams.n_ctx) - maxNewTokens - 16)
        if tokens.count > maxPromptTokens {
            tokens = Array(tokens.suffix(maxPromptTokens))
        }

        try decode(tokens: tokens, atPosition: 0, context: ctx)

        var generated = ""
        var lastToken: llama_token?
        var repeatRun = 0
        var recentTokens: [llama_token] = []

        for step in 0..<maxNewTokens {
            guard let logits = llama_get_logits_ith(ctx, -1) else { break }
            let vocabSize = Int(llama_vocab_n_tokens(vocab))
            if vocabSize <= 0 { break }

            let sampledToken = sampleToken(
                logits: logits,
                vocabSize: vocabSize,
                recentTokens: recentTokens,
                temperature: temperature,
                topP: topP,
                repetitionPenalty: repetitionPenalty
            )

            if sampledToken == llama_vocab_eos(vocab) {
                break
            }

            if let lastToken, sampledToken == lastToken {
                repeatRun += 1
            } else {
                repeatRun = 0
            }
            lastToken = sampledToken

            if repeatRun >= 8 {
                break
            }

            if let piece = tokenPiece(sampledToken, vocab: vocab), !piece.isEmpty {
                generated += piece

                let lower = generated.lowercased()
                if lower.hasSuffix("\nuser:") || lower.hasSuffix("\nassistant:") || lower.hasSuffix("\nsystem:") || lower.hasSuffix("siri:1") || looksLikeJunkMarker(piece) {
                    break
                }
            }

            recentTokens.append(sampledToken)
            if recentTokens.count > 96 {
                recentTokens.removeFirst(recentTokens.count - 96)
            }

            try decode(tokens: [sampledToken], atPosition: tokens.count + step, context: ctx)
        }

        let output = sanitizeGeneratedText(generated)
        return output.isEmpty ? nil : output
    }

    private func buildAssistantPrompt(from userPrompt: String) -> String {
        """
        System: You are OpenPad, a concise and practical assistant. Answer directly and avoid hidden reasoning.
        User: \(userPrompt)
        Assistant:
        """
    }

    private func sampleToken(
        logits: UnsafePointer<Float>,
        vocabSize: Int,
        recentTokens: [llama_token],
        temperature: Float,
        topP: Float,
        repetitionPenalty: Float
    ) -> llama_token {
        let candidateCount = max(8, min(96, vocabSize))
        var top: [(token: llama_token, logit: Float)] = []
        top.reserveCapacity(candidateCount)

        let recentSet = Set(recentTokens.suffix(96))

        for i in 0..<vocabSize {
            let token = llama_token(i)
            var adjusted = logits[i]
            if repetitionPenalty > 1.0, recentSet.contains(token) {
                adjusted -= logf(repetitionPenalty)
            }

            if top.count < candidateCount {
                top.append((token: token, logit: adjusted))
                if top.count == candidateCount {
                    top.sort { $0.logit > $1.logit }
                }
                continue
            }

            guard let worst = top.last, adjusted > worst.logit else { continue }
            top[top.count - 1] = (token: token, logit: adjusted)

            var j = top.count - 1
            while j > 0 && top[j].logit > top[j - 1].logit {
                top.swapAt(j, j - 1)
                j -= 1
            }
        }

        guard !top.isEmpty else { return 0 }

        if temperature <= 0.01 {
            return top[0].token
        }

        let maxLogit = top[0].logit
        var probs: [(token: llama_token, prob: Double)] = []
        probs.reserveCapacity(top.count)

        var total = 0.0
        for c in top {
            let scaled = Double((c.logit - maxLogit) / max(temperature, 0.01))
            let p = exp(scaled)
            probs.append((token: c.token, prob: p))
            total += p
        }

        guard total > 0 else { return top[0].token }

        for idx in probs.indices {
            probs[idx].prob /= total
        }

        let clippedTopP = Double(min(max(topP, 0.2), 1.0))
        var nucleus: [(token: llama_token, prob: Double)] = []
        var cumulative = 0.0
        for c in probs {
            nucleus.append(c)
            cumulative += c.prob
            if cumulative >= clippedTopP, nucleus.count >= 2 {
                break
            }
        }

        let nucleusTotal = nucleus.reduce(0.0) { $0 + $1.prob }
        guard nucleusTotal > 0 else { return top[0].token }

        let draw = Double.random(in: 0..<1)
        var running = 0.0
        for c in nucleus {
            running += c.prob / nucleusTotal
            if draw <= running {
                return c.token
            }
        }

        return nucleus.last?.token ?? top[0].token
    }

    private func tokenize(prompt: String, vocab: OpaquePointer?) throws -> [llama_token] {
        var capacity = max(256, prompt.utf8.count + 32)

        func runTokenize(_ size: Int) -> (Int32, [llama_token]) {
            var tokenBuffer = [llama_token](repeating: 0, count: size)
            let tokenCount: Int32 = prompt.withCString { cText in
                llama_tokenize(
                    vocab,
                    cText,
                    Int32(strlen(cText)),
                    &tokenBuffer,
                    Int32(tokenBuffer.count),
                    true,
                    true
                )
            }
            return (tokenCount, tokenBuffer)
        }

        var (tokenCount, tokenBuffer) = runTokenize(capacity)
        if tokenCount < 0 {
            // llama.cpp returns negative required size when buffer is too small.
            capacity = max(capacity * 2, Int(-tokenCount) + 8)
            (tokenCount, tokenBuffer) = runTokenize(capacity)
        }

        if tokenCount < 0 {
            throw LlamaServiceError.nativeBackendUnavailable("tokenization failed")
        }
        if tokenCount == 0 {
            return []
        }

        return Array(tokenBuffer.prefix(Int(tokenCount)))
    }

    private func decode(tokens: [llama_token], atPosition pos: Int, context: OpaquePointer) throws {
        guard !tokens.isEmpty else { return }

        let chunkSize = 256
        var offset = 0

        while offset < tokens.count {
            let end = min(offset + chunkSize, tokens.count)
            let chunk = Array(tokens[offset..<end])

            var batch = llama_batch_init(Int32(chunk.count), 0, 1)
            defer { llama_batch_free(batch) }

            for i in 0..<chunk.count {
                batch.token[i] = chunk[i]
                batch.pos[i] = Int32(pos + offset + i)
                batch.n_seq_id[i] = 1
                if let seqIds = batch.seq_id, let seqId = seqIds[i] {
                    seqId[0] = 0
                }
                batch.logits[i] = (i == chunk.count - 1) ? 1 : 0
            }
            batch.n_tokens = Int32(chunk.count)

            let decodeResult = llama_decode(context, batch)
            if decodeResult != 0 {
                throw LlamaServiceError.nativeBackendUnavailable("decode failed (\(decodeResult))")
            }

            offset = end
        }
    }

    private func tokenPiece(_ token: llama_token, vocab: OpaquePointer?) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)

        if n < 0 {
            let needed = Int(-n) + 8
            buffer = [CChar](repeating: 0, count: max(needed, 128))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        }

        guard n > 0 else { return nil }
        let bytes = buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func sanitizeGeneratedText(_ text: String) -> String {
        var out = text
        let junkMarkers = [
            "siri:1",
            "\nuser:",
            "\nassistant:",
            "\nsystem:",
            "<|eot_id|>",
            "<|start_header_id|>",
            "<|end_header_id|>"
        ]
        for marker in junkMarkers {
            if let range = out.range(of: marker, options: [.caseInsensitive]) {
                out = String(out[..<range.lowerBound])
            }
        }

        // Strip planner prompt-echo patterns like repeated "Mensaje del usuario: ...".
        let lower = out.lowercased()
        if lower.contains("mensaje del usuario:") {
            let lines = out.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let nonEcho = lines.filter { !$0.lowercased().hasPrefix("mensaje del usuario:") }
            if nonEcho.isEmpty {
                return ""
            }
            out = nonEcho.joined(separator: "\n")
        }

        // Cut at repetitive junk tags like "tiempo:1 siri:1 paga:1".
        if let regex = try? NSRegularExpression(pattern: #"\b[\p{L}_-]{2,}:\d+\b"#, options: []) {
            let full = NSRange(out.startIndex..., in: out)
            let matches = regex.matches(in: out, options: [], range: full)
            if matches.count >= 3, let first = matches.first, let r = Range(first.range, in: out) {
                out = String(out[..<r.lowerBound])
            }
        }

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikeJunkMarker(_ piece: String) -> Bool {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        if trimmed == "siri:1" || trimmed == "tiempo:1" || trimmed == "paga:1" { return true }
        if let regex = try? NSRegularExpression(pattern: #"^[\p{L}_-]{2,}:\d+$"#, options: []) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            return regex.firstMatch(in: trimmed, options: [], range: range) != nil
        }
        return false
    }
    #endif
}

private struct LlamaChatRequest: Codable {
    struct Message: Codable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let topP: Double?
    let stream: Bool
    let maxTokens: Int?
    let stop: [String]?
    let repetitionPenalty: Double?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case topP = "top_p"
        case stream
        case maxTokens = "max_tokens"
        case stop
        case repetitionPenalty = "repetition_penalty"
    }
}

private struct LlamaChatResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let role: String?
            let content: String?
        }
        let index: Int?
        let message: Message
    }

    let choices: [Choice]
}
