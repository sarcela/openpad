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
                    return clean
                }
                if strictOffline {
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
        guard var base = URL(string: cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LlamaServiceError.invalidBaseURL
        }

        base.append(path: "v1/chat/completions")

        let explicitModel = cfg.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = explicitModel.isEmpty
            ? URL(fileURLWithPath: modelPath).deletingPathExtension().lastPathComponent
            : explicitModel

        let payload = LlamaChatRequest(
            model: modelName,
            messages: [
                .init(role: "system", content: "You are OpenPad, a helpful and concise assistant."),
                .init(role: "user", content: prompt)
            ],
            temperature: 0.2,
            stream: false
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
               let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }

            if let asText = String(data: data, encoding: .utf8),
               let raw = extractContentField(from: asText), !raw.isEmpty {
                return raw
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
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
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

    private init() {}

    var hasAnyNativeModule: Bool {
        #if canImport(LlamaCpp) || canImport(llama) || canImport(LlamaSwift)
        true
        #else
        false
        #endif
    }

    func generate(prompt: String, modelPath: String) async throws -> String? {
        #if canImport(LlamaCpp)
        // Compile-safe hook for Swift wrappers exposing module `LlamaCpp`.
        // Keep this shim API-agnostic; concrete package wiring can be done here
        // without touching call sites.
        _ = prompt
        _ = modelPath
        throw LlamaServiceError.nativeBackendUnavailable("LlamaCpp module detected but adapter is not bound to package API yet")
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

        let tokens = try tokenize(prompt: normalizedPrompt, vocab: vocab)
        if tokens.isEmpty { return nil }

        try decode(tokens: tokens, atPosition: 0, context: ctx)

        var generated = ""
        let maxNewTokens = 256
        var lastToken: llama_token?
        var repeatRun = 0

        for step in 0..<maxNewTokens {
            guard let logits = llama_get_logits_ith(ctx, -1) else { break }
            let vocabSize = Int(llama_vocab_n_tokens(vocab))
            if vocabSize <= 0 { break }

            var bestToken: llama_token = 0
            var bestLogit = -Float.greatestFiniteMagnitude
            for i in 0..<vocabSize {
                let value = logits[i]
                if value > bestLogit {
                    bestLogit = value
                    bestToken = llama_token(i)
                }
            }

            if bestToken == llama_vocab_eos(vocab) {
                break
            }

            if let lastToken, bestToken == lastToken {
                repeatRun += 1
            } else {
                repeatRun = 0
            }
            lastToken = bestToken

            if repeatRun >= 6 {
                break
            }

            if let piece = tokenPiece(bestToken, vocab: vocab), !piece.isEmpty {
                generated += piece

                let lower = generated.lowercased()
                if lower.hasSuffix("\nuser:") || lower.hasSuffix("\nassistant:") || lower.hasSuffix("\nsystem:") || lower.hasSuffix("siri:1") || looksLikeJunkMarker(piece) {
                    break
                }
            }

            try decode(tokens: [bestToken], atPosition: tokens.count + step, context: ctx)
        }

        let output = sanitizeGeneratedText(generated)
        return output.isEmpty ? nil : output
    }

    private func tokenize(prompt: String, vocab: OpaquePointer?) throws -> [llama_token] {
        let estimate = max(256, prompt.utf8.count + 32)
        var tokenBuffer = [llama_token](repeating: 0, count: estimate)

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

        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        for i in 0..<tokens.count {
            batch.token[i] = tokens[i]
            batch.pos[i] = Int32(pos + i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = (i == tokens.count - 1) ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)

        let decodeResult = llama_decode(context, batch)
        if decodeResult != 0 {
            throw LlamaServiceError.nativeBackendUnavailable("decode failed (\(decodeResult))")
        }
    }

    private func tokenPiece(_ token: llama_token, vocab: OpaquePointer?) -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    private func sanitizeGeneratedText(_ text: String) -> String {
        var out = text
        let junkMarkers = ["siri:1", "\nuser:", "\nassistant:", "\nsystem:"]
        for marker in junkMarkers {
            if let range = out.lowercased().range(of: marker) {
                let idx = range.lowerBound
                out = String(out[..<idx])
            }
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
    let stream: Bool
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
