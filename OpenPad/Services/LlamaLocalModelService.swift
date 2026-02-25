import Foundation

#if canImport(LlamaSwift)
import LlamaSwift
#endif

enum LlamaServiceError: LocalizedError {
    case modelNotConfigured
    case modelFileNotFound(String)
    case nativeBackendUnavailable
    case tokenizationFailed
    case decodeFailed(Int32)
    case emptyResponse
    case vocabularyUnavailable
    case backendBusyTimeout
    case generationTimedOut

    var errorDescription: String? {
        switch self {
        case .modelNotConfigured: return "No model configured. Set a .gguf path first."
        case .modelFileNotFound(let path): return "Model not found at: \(path)"
        case .nativeBackendUnavailable: return "Native llama.swift backend is unavailable in this build."
        case .tokenizationFailed: return "Failed to tokenize prompt."
        case .decodeFailed(let code): return "llama_decode failed (\(code))."
        case .emptyResponse: return "llama.swift returned an empty response."
        case .vocabularyUnavailable: return "Failed to load tokenizer vocabulary from the selected model."
        case .backendBusyTimeout: return "llama.swift backend is busy (likely a previous generation got stuck)."
        case .generationTimedOut: return "llama.swift generation timed out."
        }
    }
}

final class LlamaLocalModelService {
    static var hasNativeModule: Bool {
        #if canImport(LlamaSwift)
        true
        #else
        false
        #endif
    }

    static var isNativeBackendReady: Bool { hasNativeModule }

    private static let backendLock = NSLock()
    private static var backendInitialized = false
    private static let runtimeConfig = LocalRuntimeConfig.shared
    private var modelPath: String?

    private struct GenerationSettings {
        let nCtx: Int32
        let nBatch: Int32
        let maxNewTokens: Int
        let maxRepeats: Int
        let minTokensBeforeEOS: Int
    }

    func configureModel(path: String) throws {
        let clean = Self.normalizeModelPath(path)
        guard !clean.isEmpty else { throw LlamaServiceError.modelNotConfigured }
        guard FileManager.default.fileExists(atPath: clean) else {
            throw LlamaServiceError.modelFileNotFound(clean)
        }
        modelPath = clean
    }

    func runLocal(prompt: String) async throws -> String {
        guard let modelPath else { throw LlamaServiceError.modelNotConfigured }
        #if canImport(LlamaSwift)
        let timeoutSeconds: Double = LlamaLocalModelService.runtimeConfig.isEmergencyMemoryModeEnabled() ? 35 : 55
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try Self.runSync(prompt: prompt, modelPath: modelPath)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw LlamaServiceError.generationTimedOut
            }

            guard let first = try await group.next() else {
                throw LlamaServiceError.generationTimedOut
            }
            group.cancelAll()
            return first
        }
        #else
        throw LlamaServiceError.nativeBackendUnavailable
        #endif
    }

    #if canImport(LlamaSwift)
    private static func runSync(prompt: String, modelPath: String) throws -> String {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw LlamaServiceError.modelFileNotFound(modelPath)
        }

        guard backendLock.lock(before: Date().addingTimeInterval(2.0)) else {
            throw LlamaServiceError.backendBusyTimeout
        }
        defer { backendLock.unlock() }
        if !backendInitialized { llama_backend_init(); backendInitialized = true }

        let modelParams = llama_model_default_params()
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaServiceError.nativeBackendUnavailable
        }
        defer { llama_model_free(model) }

        let settings = generationSettings()
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(settings.nCtx)
        contextParams.n_batch = min(contextParams.n_ctx, UInt32(min(settings.nBatch, 256)))
        guard let context = llama_init_from_model(model, contextParams) else {
            throw LlamaServiceError.nativeBackendUnavailable
        }
        defer { llama_free(context) }

        guard let vocab = llama_model_get_vocab(model) else {
            throw LlamaServiceError.vocabularyUnavailable
        }
        let framedPrompt = """
        You are OpenPad, a concise and practical assistant.
        Answer directly with useful text only.
        User: \(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        Assistant:
        """

        var tokenCapacity = max(512, framedPrompt.utf8.count + 32)
        var tokens = [llama_token](repeating: 0, count: tokenCapacity)
        var tokenCount = framedPrompt.withCString { cText in
            llama_tokenize(vocab, cText, Int32(strlen(cText)), &tokens, Int32(tokens.count), true, true)
        }

        if tokenCount < 0 {
            tokenCapacity = max(tokenCapacity * 2, Int(-tokenCount) + 8)
            tokens = [llama_token](repeating: 0, count: tokenCapacity)
            tokenCount = framedPrompt.withCString { cText in
                llama_tokenize(vocab, cText, Int32(strlen(cText)), &tokens, Int32(tokens.count), true, true)
            }
        }

        guard tokenCount > 0 else { throw LlamaServiceError.tokenizationFailed }
        let reservedForGeneration = min(
            max(96, settings.maxNewTokens),
            max(32, Int(contextParams.n_ctx) / 3)
        )
        let maxPromptTokens = max(64, Int(contextParams.n_ctx) - reservedForGeneration)
        let promptTokens = Array(tokens.prefix(Int(tokenCount)).suffix(maxPromptTokens))

        let batchCapacity = max(Int(contextParams.n_batch), promptTokens.count + 1)
        var batch = llama_batch_init(Int32(batchCapacity), 0, 1)
        defer { llama_batch_free(batch) }

        batch.n_tokens = Int32(promptTokens.count)
        for i in 0..<promptTokens.count {
            batch.token[i] = promptTokens[i]
            batch.pos[i] = Int32(i)
            batch.n_seq_id[i] = 1
            if let seqIDs = batch.seq_id, let seqID = seqIDs[i] { seqID[0] = 0 }
            batch.logits[i] = (i == promptTokens.count - 1) ? 1 : 0
        }

        let firstDecode = llama_decode(context, batch)
        guard firstDecode == 0 else { throw LlamaServiceError.decodeFailed(firstDecode) }

        var outputBytes = Data()
        var output = ""
        var currentPos = batch.n_tokens
        let contextLimit = Int32(contextParams.n_ctx)
        let samplingTemperature = sanitizeTemperature(Float(runtimeConfig.loadLocalTemperature()))
        var lastToken: llama_token?
        var repeatCount = 0
        var generatedCount = 0
        var recentTokens: [llama_token] = []
        let repeatWindowSize = 64

        for _ in 0..<settings.maxNewTokens {
            if currentPos >= contextLimit { break }
            guard let logits = llama_get_logits_ith(context, batch.n_tokens - 1) else { break }
            let vocabSize = Int(llama_vocab_n_tokens(vocab))
            if vocabSize <= 0 { break }

            let recentTokenCounts = Dictionary(recentTokens.map { ($0, 1) }, uniquingKeysWith: +)
            var nextToken = sampleToken(
                logits: logits,
                vocabSize: vocabSize,
                vocab: vocab,
                temperature: samplingTemperature,
                recentTokenCounts: recentTokenCounts
            )
            if isControlLikeToken(nextToken, vocab: vocab) {
                nextToken = bestTokenExcluding(
                    logits: logits,
                    vocabSize: vocabSize,
                    vocab: vocab,
                    excluded: Set([nextToken]),
                    allowControlTokens: false
                ) ?? pickToken(logits: logits, vocabSize: vocabSize, vocab: vocab)
            }
            if nextToken == llama_vocab_eos(vocab), generatedCount < settings.minTokensBeforeEOS {
                nextToken = bestTokenExcluding(
                    logits: logits,
                    vocabSize: vocabSize,
                    vocab: vocab,
                    excluded: Set([llama_vocab_eos(vocab)]),
                    allowControlTokens: false
                ) ?? nextToken
            }
            if nextToken == llama_vocab_eos(vocab) { break }

            if let lastToken, lastToken == nextToken {
                repeatCount += 1
            } else {
                repeatCount = 0
            }
            if repeatCount >= settings.maxRepeats { break }
            lastToken = nextToken
            recentTokens.append(nextToken)
            if recentTokens.count > repeatWindowSize {
                recentTokens.removeFirst(recentTokens.count - repeatWindowSize)
            }

            if let pieceBytes = tokenPieceBytes(nextToken, vocab: vocab) {
                outputBytes.append(contentsOf: pieceBytes)
                output = decodeUTF8Prefix(outputBytes, previous: output)
                if let clipped = clipAtStopSequence(output) {
                    output = clipped
                    break
                }
            }

            generatedCount += 1

            batch.n_tokens = 1
            batch.token[0] = nextToken
            batch.pos[0] = currentPos
            batch.n_seq_id[0] = 1
            if let seqIDs = batch.seq_id, let seqID = seqIDs[0] { seqID[0] = 0 }
            batch.logits[0] = 1
            currentPos += 1

            let stepDecode = llama_decode(context, batch)
            if stepDecode != 0 {
                if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw LlamaServiceError.decodeFailed(stepDecode)
                }
                break
            }
        }

        let clean = sanitizeDecodedOutput(output)

        guard !clean.isEmpty else { throw LlamaServiceError.emptyResponse }
        let generatedText = clean
        print("Generated text: \(generatedText)")
        return generatedText
    }

    private static func pickToken(logits: UnsafePointer<Float>, vocabSize: Int, vocab: OpaquePointer?) -> llama_token {
        var best = llama_token(0)
        var bestLogit = -Float.greatestFiniteMagnitude
        var fallback = llama_token(0)
        var fallbackLogit = -Float.greatestFiniteMagnitude

        for i in 0..<vocabSize {
            let token = llama_token(i)
            let logit = logits[i]
            guard logit.isFinite else { continue }

            if logit > fallbackLogit {
                fallback = token
                fallbackLogit = logit
            }

            var filteredOut = false
            if let piece = tokenPieceString(token, vocab: vocab) {
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.contains("<|") || trimmed.contains("|>") {
                    filteredOut = true
                }
            }

            if !filteredOut, logit > bestLogit {
                best = token
                bestLogit = logit
            }
        }

        if let vocab, best == llama_vocab_eos(vocab), fallback != best {
            return fallback
        }

        if bestLogit > -Float.greatestFiniteMagnitude / 2 {
            return best
        }
        if fallbackLogit > -Float.greatestFiniteMagnitude / 2 {
            return fallback
        }

        return llama_token(0)
    }

    private static func bestTokenExcluding(
        logits: UnsafePointer<Float>,
        vocabSize: Int,
        vocab: OpaquePointer?,
        excluded: Set<llama_token>,
        allowControlTokens: Bool
    ) -> llama_token? {
        var bestToken: llama_token?
        var bestLogit = -Float.greatestFiniteMagnitude

        for i in 0..<vocabSize {
            let token = llama_token(i)
            if excluded.contains(token) { continue }

            let logit = logits[i]
            guard logit.isFinite else { continue }
            if !allowControlTokens, isControlLikeToken(token, vocab: vocab) { continue }

            if logit > bestLogit {
                bestLogit = logit
                bestToken = token
            }
        }

        return bestToken
    }

    private static func isControlLikeToken(_ token: llama_token, vocab: OpaquePointer?) -> Bool {
        guard let piece = tokenPieceString(token, vocab: vocab) else { return false }
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.contains("<|") || trimmed.contains("|>")
    }

    private static func tokenPieceBytes(_ token: llama_token, vocab: OpaquePointer?) -> [UInt8]? {
        var buffer = [CChar](repeating: 0, count: 128)
        var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)

        if count < 0 {
            let needed = max(128, Int(-count) + 8)
            buffer = [CChar](repeating: 0, count: needed)
            count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }

        guard count > 0 else { return nil }
        return buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    }

    private static func tokenPieceString(_ token: llama_token, vocab: OpaquePointer?) -> String? {
        guard let bytes = tokenPieceBytes(token, vocab: vocab) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }
    #endif


    #if canImport(LlamaSwift)
    private static func sampleToken(
        logits: UnsafePointer<Float>,
        vocabSize: Int,
        vocab: OpaquePointer?,
        temperature: Float,
        recentTokenCounts: [llama_token: Int]
    ) -> llama_token {
        let clippedTemp = sanitizeTemperature(temperature)
        if clippedTemp <= 0.05 {
            return pickToken(logits: logits, vocabSize: vocabSize, vocab: vocab)
        }

        let topK = min(64, vocabSize)
        var candidates: [(token: llama_token, logit: Float)] = []
        candidates.reserveCapacity(topK)

        for i in 0..<vocabSize {
            let token = llama_token(i)
            if isControlLikeToken(token, vocab: vocab) { continue }

            var l = logits[i]
            guard l.isFinite else { continue }

            if let repeats = recentTokenCounts[token], repeats > 0 {
                let cappedRepeats = min(3, repeats)
                l -= 0.45 * Float(cappedRepeats)
            }

            if candidates.count < topK {
                candidates.append((token, l))
                if candidates.count == topK {
                    candidates.sort { $0.logit > $1.logit }
                }
                continue
            }
            if let last = candidates.last, l > last.logit {
                candidates[candidates.count - 1] = (token, l)
                candidates.sort { $0.logit > $1.logit }
            }
        }

        guard !candidates.isEmpty else {
            return pickToken(logits: logits, vocabSize: vocabSize, vocab: vocab)
        }

        let maxLogit = candidates[0].logit
        var probs: [(llama_token, Double)] = []
        var total = 0.0
        for c in candidates {
            let p = exp(Double((c.logit - maxLogit) / clippedTemp))
            guard p.isFinite else { continue }
            probs.append((c.token, p))
            total += p
        }
        if total <= 0 { return candidates[0].token }

        for i in probs.indices { probs[i].1 /= total }

        // Nucleus top-p = 0.9
        var nucleus: [(llama_token, Double)] = []
        var cumulative = 0.0
        for p in probs {
            nucleus.append(p)
            cumulative += p.1
            if cumulative >= 0.9 && nucleus.count >= 2 { break }
        }

        let nsum = nucleus.reduce(0.0) { $0 + $1.1 }
        if nsum <= 0 { return candidates[0].token }

        let r = Double.random(in: 0..<1)
        var run = 0.0
        for (tok, prob) in nucleus {
            run += prob / nsum
            if r <= run { return tok }
        }
        return nucleus.last?.0 ?? candidates[0].token
    }
    #endif

    private static func decodeUTF8Prefix(_ data: Data, previous: String) -> String {
        if let full = String(data: data, encoding: .utf8) {
            return full
        }

        // Token streams can end in partial multi-byte sequences between decode steps.
        // Keep the last known-good text instead of injecting replacement glyphs.
        let maxTrim = min(4, data.count)
        if maxTrim > 1 {
            for trim in 1..<maxTrim {
                let candidate = data.dropLast(trim)
                if let prefix = String(data: candidate, encoding: .utf8) {
                    return prefix
                }
            }
        }

        return previous
    }

    private static func generationSettings() -> GenerationSettings {
        let emergency = runtimeConfig.isEmergencyMemoryModeEnabled()
        let profile = runtimeConfig.loadRunProfile()

        if emergency {
            return GenerationSettings(nCtx: 896, nBatch: 96, maxNewTokens: 96, maxRepeats: 4, minTokensBeforeEOS: 8)
        }

        switch profile {
        case .stable:
            return GenerationSettings(nCtx: 1024, nBatch: 128, maxNewTokens: 110, maxRepeats: 5, minTokensBeforeEOS: 10)
        case .balanced:
            return GenerationSettings(nCtx: 1280, nBatch: 160, maxNewTokens: 140, maxRepeats: 6, minTokensBeforeEOS: 12)
        case .turbo:
            return GenerationSettings(nCtx: 1536, nBatch: 192, maxNewTokens: 170, maxRepeats: 7, minTokensBeforeEOS: 14)
        }
    }

    private static func sanitizeDecodedOutput(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"(?is)<think>.*?</think>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?im)^\s*(assistant|asistente)\s*:\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?im)^\s*(user|usuario|system|sistema)\s*:.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "<|eot_id|>", with: "")
            .replacingOccurrences(of: "<|end|>", with: "")
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .replacingOccurrences(of: "<｜end▁of▁sentence｜>", with: "")
            .replacingOccurrences(of: "<｜User｜>", with: "")
            .replacingOccurrences(of: "<｜Assistant｜>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizeTemperature(_ temperature: Float) -> Float {
        guard temperature.isFinite else { return 0.2 }
        return max(0.0, min(1.0, temperature))
    }

    private static func clipAtStopSequence(_ text: String) -> String? {
        let stops = [
            "\nuser:",
            "\nassistant:",
            "\nusuario:",
            "\nasistente:",
            "<|eot_id|>",
            "<|end|>",
            "<|im_end|>",
            "<｜end▁of▁sentence｜>",
            "<｜User｜>",
            "<｜Assistant｜>"
        ]
        guard let marker = stops
            .compactMap({ text.range(of: $0, options: [.caseInsensitive])?.lowerBound })
            .min()
        else {
            return nil
        }
        return String(text[..<marker]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeModelPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}
