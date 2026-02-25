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
    case cancelled

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
        case .cancelled: return "llama.swift generation cancelled."
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

        let resolved = try Self.resolveExistingModelPath(from: clean)
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw LlamaServiceError.modelFileNotFound(resolved)
        }
        modelPath = resolved
    }

    func runLocal(prompt: String) async throws -> String {
        guard let modelPath else { throw LlamaServiceError.modelNotConfigured }
        #if canImport(LlamaSwift)
        let timeoutSeconds: Double = LlamaLocalModelService.runtimeConfig.isEmergencyMemoryModeEnabled() ? 90 : 180
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        return try await Task.detached(priority: .userInitiated) {
            try Self.runSync(prompt: prompt, modelPath: modelPath, deadline: deadline)
        }.value
        #else
        throw LlamaServiceError.nativeBackendUnavailable
        #endif
    }

    #if canImport(LlamaSwift)
    private static func runSync(prompt: String, modelPath: String, deadline: Date) throws -> String {
        try throwIfCancelled()
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw LlamaServiceError.modelFileNotFound(modelPath)
        }

        let lockWaitSeconds = min(12.0, max(3.0, Date().distance(to: deadline) * 0.25))
        guard backendLock.lock(before: Date().addingTimeInterval(lockWaitSeconds)) else {
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
        let framedPrompt = buildFramedPrompt(
            userPrompt: prompt,
            modelPath: modelPath
        )

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
        let maxPromptTokensByContext = max(64, Int(contextParams.n_ctx) - reservedForGeneration)
        let maxPromptTokens = maxPromptTokensByContext

        let allPromptTokens = Array(tokens.prefix(Int(tokenCount)))
        let promptTokens: [llama_token]
        if allPromptTokens.count <= maxPromptTokens {
            promptTokens = allPromptTokens
        } else {
            // Keep an instruction prefix (system + role scaffolding) and trim oldest middle context first.
            // Preserving only BOS hurts answer quality when long prompts get clipped.
            let targetPrefix = min(96, max(16, maxPromptTokens / 8))
            let headCount = min(targetPrefix, allPromptTokens.count)
            let tailCount = max(0, maxPromptTokens - headCount)
            promptTokens = Array(allPromptTokens.prefix(headCount) + allPromptTokens.suffix(tailCount))
        }

        print("[LLAMA] prompt_tokens=\(promptTokens.count) (raw=\(allPromptTokens.count)) n_ctx=\(contextParams.n_ctx) n_batch=\(contextParams.n_batch)")

        let batchCapacity = max(Int(contextParams.n_batch), 2)
        var batch = llama_batch_init(Int32(batchCapacity), 0, 1)
        defer { llama_batch_free(batch) }

        var processedPromptTokens = 0
        var start = 0
        while start < promptTokens.count {
            try throwIfCancelled()
            if Date() >= deadline { throw LlamaServiceError.generationTimedOut }
            let end = min(start + batchCapacity, promptTokens.count)
            let chunk = Array(promptTokens[start..<end])

            batch.n_tokens = Int32(chunk.count)
            for i in 0..<chunk.count {
                batch.token[i] = chunk[i]
                batch.pos[i] = Int32(processedPromptTokens + i)
                batch.n_seq_id[i] = 1
                if let seqIDs = batch.seq_id, let seqID = seqIDs[i] { seqID[0] = 0 }
                let isLastPromptToken = (end == promptTokens.count) && (i == chunk.count - 1)
                batch.logits[i] = isLastPromptToken ? 1 : 0
            }

            let decodeResult = llama_decode(context, batch)
            guard decodeResult == 0 else { throw LlamaServiceError.decodeFailed(decodeResult) }

            processedPromptTokens += chunk.count
            start = end
        }

        var outputBytes = Data()
        var output = ""
        var currentPos = Int32(processedPromptTokens)
        let contextLimit = Int32(contextParams.n_ctx)
        let samplingTemperature = sanitizeTemperature(Float(runtimeConfig.loadLocalTemperature()))
        var lastToken: llama_token?
        var repeatCount = 0
        var generatedCount = 0
        var recentTokens: [llama_token] = []
        let repeatWindowSize = 64

        for _ in 0..<settings.maxNewTokens {
            try throwIfCancelled()
            if Date() >= deadline { throw LlamaServiceError.generationTimedOut }
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
                if isSpecialMarkerToken(piece) {
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
        return isSpecialMarkerToken(piece)
    }

    private static func isSpecialMarkerToken(_ piece: String) -> Bool {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.contains("<|") ||
            trimmed.contains("|>") ||
            trimmed.hasPrefix("<｜") ||
            trimmed.hasSuffix("｜>")
    }

    private static func tokenPieceBytes(_ token: llama_token, vocab: OpaquePointer?) -> [UInt8]? {
        guard let vocab else { return nil }

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

    private static func buildFramedPrompt(userPrompt: String, modelPath: String) -> String {
        let cleanUserPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = "You are OpenPad, a concise and practical assistant. Answer directly with useful text only."

        switch detectPromptFamily(from: modelPath) {
        case .chatML:
            return """
            <|im_start|>system
            \(systemPrompt)
            <|im_end|>
            <|im_start|>user
            \(cleanUserPrompt)
            <|im_end|>
            <|im_start|>assistant
            """
        case .llama3:
            return """
            <|begin_of_text|><|start_header_id|>system<|end_header_id|>

            \(systemPrompt)<|eot_id|><|start_header_id|>user<|end_header_id|>

            \(cleanUserPrompt)<|eot_id|><|start_header_id|>assistant<|end_header_id|>

            """
        case .mistralInstruct:
            return """
            <s>[INST] <<SYS>>
            \(systemPrompt)
            <</SYS>>

            \(cleanUserPrompt) [/INST]
            """
        case .plain:
            return """
            \(systemPrompt)
            User: \(cleanUserPrompt)
            Assistant:
            """
        }
    }

    private enum PromptFamily {
        case plain
        case chatML
        case llama3
        case mistralInstruct
    }

    private static func detectPromptFamily(from modelPath: String) -> PromptFamily {
        let modelName = URL(fileURLWithPath: modelPath)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()

        // Llama 3/3.1/3.2 and derivatives generally expect header-id chat templates.
        let llama3Hints = ["llama-3", "llama3", "meta-llama", "openhermes", "instruct"]
        if llama3Hints.contains(where: { modelName.contains($0) }) &&
            (modelName.contains("llama") || modelName.contains("hermes")) {
            return .llama3
        }

        // Llama 2 chat/instruct checkpoints expect [INST] wrappers and degrade with plain prompts.
        let llama2Hints = ["llama-2", "llama2"]
        if llama2Hints.contains(where: { modelName.contains($0) }) &&
            (modelName.contains("chat") || modelName.contains("instruct")) {
            return .mistralInstruct
        }

        // Qwen/Phi/DeepSeek and similar instruct variants usually expect ChatML markers.
        let chatMLHints = ["qwen", "phi", "deepseek", "yi", "internlm"]
        if chatMLHints.contains(where: { modelName.contains($0) }) {
            return .chatML
        }

        // Mistral/Mixtral-style instruct models tend to follow [INST] wrappers.
        let mistralInstructHints = ["mistral", "mixtral", "zephyr", "openchat", "solar", "nous-hermes-2"]
        if mistralInstructHints.contains(where: { modelName.contains($0) }) {
            return .mistralInstruct
        }

        return .plain
    }

    private static func sanitizeDecodedOutput(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"(?is)<think>.*?</think>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?im)^\s*(assistant|asistente)\s*:\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?im)^\s*(user|usuario|system|sistema)\s*:.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "<|begin_of_text|>", with: "")
            .replacingOccurrences(of: "<|eot_id|>", with: "")
            .replacingOccurrences(of: "<|end|>", with: "")
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .replacingOccurrences(of: "<|im_start|>", with: "")
            .replacingOccurrences(of: "<|start_header_id|>", with: "")
            .replacingOccurrences(of: "<|end_header_id|>", with: "")
            .replacingOccurrences(of: "<｜end▁of▁sentence｜>", with: "")
            .replacingOccurrences(of: "<｜User｜>", with: "")
            .replacingOccurrences(of: "<｜Assistant｜>", with: "")
            .replacingOccurrences(of: "<s>", with: "")
            .replacingOccurrences(of: "</s>", with: "")
            .replacingOccurrences(of: "[INST]", with: "")
            .replacingOccurrences(of: "[/INST]", with: "")
            .replacingOccurrences(of: "<<SYS>>", with: "")
            .replacingOccurrences(of: "<</SYS>>", with: "")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizeTemperature(_ temperature: Float) -> Float {
        guard temperature.isFinite else { return 0.2 }
        return max(0.0, min(1.0, temperature))
    }

    private static func throwIfCancelled() throws {
        if Task.isCancelled {
            throw LlamaServiceError.cancelled
        }
    }

    private static func clipAtStopSequence(_ text: String) -> String? {
        let literalStops = [
            "<|begin_of_text|>",
            "<|eot_id|>",
            "<|end|>",
            "<|im_end|>",
            "<|im_start|>",
            "<|start_header_id|>user<|end_header_id|>",
            "<｜end▁of▁sentence｜>",
            "<｜User｜>",
            "</s>",
            "[INST]",
            "[/INST]"
        ]

        var markers: [String.Index] = []
        for stop in literalStops {
            if let range = text.range(of: stop, options: [.caseInsensitive]) {
                markers.append(range.lowerBound)
            }
        }

        // Clip when a new *user/system* turn marker leaks into generation.
        // Do not clip on assistant labels; many models start with "Assistant:" before useful text.
        if let regex = try? NSRegularExpression(pattern: #"(?im)^\s*(user|usuario|system|sistema)\s*:"#) {
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: nsRange),
               let swiftRange = Range(match.range, in: text) {
                markers.append(swiftRange.lowerBound)
            }
        }

        guard let marker = markers.min() else { return nil }
        return String(text[..<marker]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeModelPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let unwrapped = unwrapQuotedPath(trimmed)

        if let fileURL = URL(string: unwrapped), fileURL.isFileURL {
            let decoded = fileURL.path.removingPercentEncoding ?? fileURL.path
            guard !decoded.isEmpty else { return "" }
            return URL(fileURLWithPath: decoded).standardizedFileURL.path
        }

        let expanded = (unwrapped as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func resolveExistingModelPath(from normalizedPath: String) throws -> String {
        if FileManager.default.fileExists(atPath: normalizedPath) {
            return normalizedPath
        }

        // iOS app container paths can change across reinstalls/updates while file names remain stable.
        let fileName = URL(fileURLWithPath: normalizedPath).lastPathComponent
        guard !fileName.isEmpty else { return normalizedPath }

        do {
            let docs = try LocalModelConfig.shared.documentsDirectory()
            let candidate = LocalModelConfig.shared.modelsDirectory(in: docs)
                .appendingPathComponent(fileName, isDirectory: false)
                .standardizedFileURL
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        } catch {
            // Keep original path on lookup failures.
        }

        return normalizedPath
    }

    private static func unwrapQuotedPath(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        if (raw.hasPrefix("\"") && raw.hasSuffix("\"")) ||
            (raw.hasPrefix("'") && raw.hasSuffix("'")) {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }
}
