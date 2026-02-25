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

enum LlamaGenerationMode {
    case chat
    case tools
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

    private static let defaultSystemPrompt = "You are OpenPad, a concise and practical assistant. Answer directly with useful text only."

    func configureModel(path: String) throws {
        let clean = Self.normalizeModelPath(path)
        guard !clean.isEmpty else { throw LlamaServiceError.modelNotConfigured }

        let resolved = try Self.resolveExistingModelPath(from: clean)
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw LlamaServiceError.modelFileNotFound(resolved)
        }
        modelPath = resolved
    }

    func runLocal(prompt: String, mode: LlamaGenerationMode = .chat) async throws -> String {
        guard let configuredModelPath = modelPath else { throw LlamaServiceError.modelNotConfigured }
        let resolvedModelPath = try Self.resolveExistingModelPath(from: configuredModelPath)
        guard FileManager.default.fileExists(atPath: resolvedModelPath) else {
            throw LlamaServiceError.modelFileNotFound(resolvedModelPath)
        }
        if resolvedModelPath != configuredModelPath {
            modelPath = resolvedModelPath
            print("[LLAMA] model_path_recovered from=\(configuredModelPath) to=\(resolvedModelPath)")
        }

        #if canImport(LlamaSwift)
        let timeoutSeconds: Double = LlamaLocalModelService.runtimeConfig.isEmergencyMemoryModeEnabled() ? 90 : 180
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        do {
            return try await Task(priority: .userInitiated) {
                try Self.runSyncWithTemplateFallback(prompt: prompt, modelPath: resolvedModelPath, mode: mode, deadline: deadline)
            }.value
        } catch LlamaServiceError.backendBusyTimeout {
            // A previous generation can hold the backend lock briefly; retry once with a
            // short backoff to avoid surfacing transient busy errors to the UI.
            if Date().addingTimeInterval(0.55) < deadline {
                try await Task.sleep(nanoseconds: 550_000_000)
                return try await Task(priority: .userInitiated) {
                    try Self.runSyncWithTemplateFallback(prompt: prompt, modelPath: resolvedModelPath, mode: mode, deadline: deadline)
                }.value
            }
            throw LlamaServiceError.backendBusyTimeout
        }
        #else
        throw LlamaServiceError.nativeBackendUnavailable
        #endif
    }

    #if canImport(LlamaSwift)
    private static func runSyncWithTemplateFallback(prompt: String, modelPath: String, mode: LlamaGenerationMode, deadline: Date) throws -> String {
        let preferred = detectPromptFamily(from: modelPath)
        let attempts = promptFamilyFallbackOrder(preferred: preferred)
        var lastRecoverableError: LlamaServiceError?

        for family in attempts {
            do {
                let result = try runSync(prompt: prompt, modelPath: modelPath, mode: mode, deadline: deadline, promptFamily: family)
                if family != preferred {
                    print("[LLAMA] recovered_using_prompt_family=\(promptFamilyLabel(family)) preferred=\(promptFamilyLabel(preferred))")
                }
                return result
            } catch let error as LlamaServiceError {
                switch error {
                case .emptyResponse, .decodeFailed(_), .tokenizationFailed:
                    lastRecoverableError = error
                    continue
                default:
                    throw error
                }
            }
        }

        throw lastRecoverableError ?? .emptyResponse
    }

    private static func runSync(prompt: String, modelPath: String, mode: LlamaGenerationMode, deadline: Date, promptFamily: PromptFamily) throws -> String {
        try throwIfCancelled()
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw LlamaServiceError.modelFileNotFound(modelPath)
        }

        let remainingTime = deadline.timeIntervalSinceNow
        guard remainingTime > 0 else {
            throw LlamaServiceError.generationTimedOut
        }

        // Keep lock waits short so stale/overlapping generations fail fast instead of
        // burning most of the request budget before decode even starts.
        let lockWaitSeconds = min(4.0, max(0.35, remainingTime * 0.2))
        guard backendLock.lock(before: Date().addingTimeInterval(lockWaitSeconds)) else {
            if Date() >= deadline {
                throw LlamaServiceError.generationTimedOut
            }
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
            modelPath: modelPath,
            promptFamily: promptFamily
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

        let maxNewTokens = adaptiveMaxNewTokens(
            base: settings.maxNewTokens,
            mode: mode,
            promptTokenCount: promptTokens.count,
            contextSize: Int(contextParams.n_ctx)
        )
        let minTokensBeforeEOS = adaptiveMinTokensBeforeEOS(
            base: settings.minTokensBeforeEOS,
            mode: mode,
            promptTokenCount: promptTokens.count,
            maxNewTokens: maxNewTokens
        )

        var outputBytes = Data()
        var output = ""
        var currentPos = Int32(processedPromptTokens)
        let contextLimit = Int32(contextParams.n_ctx)
        let baseTemperature = sanitizeTemperature(Float(runtimeConfig.loadLocalTemperature()))
        // Tool/planner turns are much more reliable with near-greedy decoding.
        // Keep chat responses configurable, but clamp tool mode for deterministic JSON.
        let samplingTemperature: Float = {
            switch mode {
            case .chat: return baseTemperature
            case .tools: return min(baseTemperature, 0.05)
            }
        }()
        var lastToken: llama_token?
        var repeatCount = 0
        var generatedCount = 0
        var recentTokens: [llama_token] = []
        var controlTokenCache: [llama_token: Bool] = [:]
        let repeatWindowSize = 64
        var staleDecodeSteps = 0
        let staleDecodeLimit = max(10, min(24, maxNewTokens / 3))

        for _ in 0..<maxNewTokens {
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
                recentTokenCounts: recentTokenCounts,
                controlTokenCache: &controlTokenCache
            )
            if isControlLikeTokenCached(nextToken, vocab: vocab, cache: &controlTokenCache) {
                nextToken = bestTokenExcluding(
                    logits: logits,
                    vocabSize: vocabSize,
                    vocab: vocab,
                    excluded: Set([nextToken]),
                    allowControlTokens: false,
                    controlTokenCache: &controlTokenCache
                ) ?? pickToken(logits: logits, vocabSize: vocabSize, vocab: vocab, controlTokenCache: &controlTokenCache)
            }
            if nextToken == llama_vocab_eos(vocab), generatedCount < minTokensBeforeEOS {
                nextToken = bestTokenExcluding(
                    logits: logits,
                    vocabSize: vocabSize,
                    vocab: vocab,
                    excluded: Set([llama_vocab_eos(vocab)]),
                    allowControlTokens: false,
                    controlTokenCache: &controlTokenCache
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

            let previousOutput = output
            let previousByteCount = outputBytes.count
            if let pieceBytes = tokenPieceBytes(nextToken, vocab: vocab) {
                outputBytes.append(contentsOf: pieceBytes)
                output = decodeUTF8Prefix(outputBytes, previous: output)
                if let clipped = clipAtStopSequence(output) {
                    if clipped.isEmpty {
                        // Some checkpoints emit a stop marker before any real text.
                        // Ignore that marker and continue sampling instead of ending empty.
                        // Also drop accumulated bytes so future decode attempts don't keep
                        // re-emitting the same clipped marker prefix.
                        output = ""
                        outputBytes.removeAll(keepingCapacity: true)
                    } else {
                        output = clipped
                        break
                    }
                }
            }

            if output == previousOutput {
                // If text did not advance but byte buffer did, we're likely in the middle of
                // an incomplete UTF-8 sequence. Don't count that as a stale decode step.
                if outputBytes.count > previousByteCount {
                    staleDecodeSteps = 0
                } else {
                    staleDecodeSteps += 1
                }
            } else {
                staleDecodeSteps = 0
            }

            if staleDecodeSteps >= staleDecodeLimit {
                // Protect against native decoding loops that keep emitting non-renderable
                // fragments (or partial UTF-8 tails) without advancing visible text.
                if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw LlamaServiceError.emptyResponse
                }
                break
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
        let deEchoed = stripPromptEcho(from: clean, userPrompt: prompt)
        let withoutSystemEcho = stripSystemPromptEcho(from: deEchoed)

        guard !withoutSystemEcho.isEmpty else { throw LlamaServiceError.emptyResponse }
        if isLowSignalResponse(withoutSystemEcho, mode: mode) {
            throw LlamaServiceError.emptyResponse
        }
        if mode == .chat, isTemplateLeakResponse(withoutSystemEcho) {
            // Treat template/marker-heavy emissions as a failed attempt so the caller
            // can retry with the next prompt family instead of returning noisy output.
            throw LlamaServiceError.emptyResponse
        }
        let generatedText = withoutSystemEcho
        print("Generated text: \(generatedText)")
        return generatedText
    }

    private static func adaptiveMaxNewTokens(
        base: Int,
        mode: LlamaGenerationMode,
        promptTokenCount: Int,
        contextSize: Int
    ) -> Int {
        let safeContext = max(contextSize, 1)
        let promptRatio = Double(promptTokenCount) / Double(safeContext)
        let minTokens = max(48, min(base, 96))

        switch mode {
        case .tools:
            // Keep planner/tool generations bounded for deterministic JSON and latency.
            return max(minTokens, min(base, 128))
        case .chat:
            // Short prompts can afford a bit more budget; this reduces clipped answers.
            let boost: Int
            if promptRatio <= 0.20 {
                boost = 72
            } else if promptRatio <= 0.35 {
                boost = 44
            } else if promptRatio <= 0.50 {
                boost = 20
            } else {
                boost = 0
            }

            let contextHeadroom = max(24, contextSize - promptTokenCount - 8)
            let upperBound = min(240, contextHeadroom)
            return max(minTokens, min(base + boost, upperBound))
        }
    }

    private static func adaptiveMinTokensBeforeEOS(
        base: Int,
        mode: LlamaGenerationMode,
        promptTokenCount: Int,
        maxNewTokens: Int
    ) -> Int {
        switch mode {
        case .tools:
            return min(max(base, 6), max(8, maxNewTokens / 2))
        case .chat:
            let floor = promptTokenCount < 180 ? max(base, 14) : max(base, 10)
            return min(floor, max(10, maxNewTokens / 2))
        }
    }

    private static func pickToken(
        logits: UnsafePointer<Float>,
        vocabSize: Int,
        vocab: OpaquePointer?,
        controlTokenCache: inout [llama_token: Bool]
    ) -> llama_token {
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

            let filteredOut = isControlLikeTokenCached(token, vocab: vocab, cache: &controlTokenCache)

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

        // If logits are unusable (NaN/inf only), terminate gracefully instead of
        // forcing token 0 (often BOS/control), which can create noisy loops.
        if let vocab {
            return llama_vocab_eos(vocab)
        }
        return llama_token(0)
    }

    private static func bestTokenExcluding(
        logits: UnsafePointer<Float>,
        vocabSize: Int,
        vocab: OpaquePointer?,
        excluded: Set<llama_token>,
        allowControlTokens: Bool,
        controlTokenCache: inout [llama_token: Bool]
    ) -> llama_token? {
        var bestToken: llama_token?
        var bestLogit = -Float.greatestFiniteMagnitude

        for i in 0..<vocabSize {
            let token = llama_token(i)
            if excluded.contains(token) { continue }

            let logit = logits[i]
            guard logit.isFinite else { continue }
            if !allowControlTokens, isControlLikeTokenCached(token, vocab: vocab, cache: &controlTokenCache) { continue }

            if logit > bestLogit {
                bestLogit = logit
                bestToken = token
            }
        }

        return bestToken
    }

    private static func isControlLikeTokenCached(
        _ token: llama_token,
        vocab: OpaquePointer?,
        cache: inout [llama_token: Bool]
    ) -> Bool {
        if let cached = cache[token] { return cached }
        let computed = isControlLikeToken(token, vocab: vocab)
        cache[token] = computed
        return computed
    }

    private static func isControlLikeToken(_ token: llama_token, vocab: OpaquePointer?) -> Bool {
        // Empty/unrenderable pieces are usually BOS/EOS/control slots; sampling them tends to
        // waste decode steps and can yield empty/low-signal responses.
        guard let bytes = tokenPieceBytes(token, vocab: vocab), !bytes.isEmpty else { return true }

        // Some special/control tokens are not always valid UTF-8; decode lossily so we can
        // still detect marker patterns and avoid sampling them into visible output.
        let lossyPiece = String(decoding: bytes, as: UTF8.self)
        if isSpecialMarkerToken(lossyPiece) { return true }

        // When decoding fails hard, some runtimes surface replacement-only glyphs.
        // Treat those as control-like to keep visible output quality stable.
        let trimmed = lossyPiece.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let onlyReplacementScalars = trimmed.unicodeScalars.allSatisfy { $0.value == 0xFFFD }
            if onlyReplacementScalars { return true }
        }

        return false
    }

    private static func isSpecialMarkerToken(_ piece: String) -> Bool {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()

        // Be strict here: broad checks like "|>" can incorrectly filter valid code/math
        // tokens and hurt output quality.
        if lower.hasPrefix("<｜") || lower.hasSuffix("｜>") { return true }
        if lower.contains("<start_of_turn>") || lower.contains("<end_of_turn>") { return true }
        if lower.contains("[inst]") || lower.contains("[/inst]") { return true }
        if lower.contains("<<sys>>") || lower.contains("<</sys>>") { return true }
        if lower.contains("### instruction:") || lower.contains("### response:") { return true }

        // Match only full chat-protocol tags like <|im_start|>, <|eot_id|>, etc.
        if let regex = try? NSRegularExpression(pattern: #"<\|[a-z0-9_\-]+\|>"#, options: [.caseInsensitive]) {
            let nsRange = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            if regex.firstMatch(in: lower, options: [], range: nsRange) != nil {
                return true
            }
        }

        return false
    }

    private static func tokenPieceBytes(_ token: llama_token, vocab: OpaquePointer?) -> [UInt8]? {
        guard let vocab else { return nil }

        func renderPiece(special: Bool) -> [UInt8]? {
            var buffer = [CChar](repeating: 0, count: 128)
            var count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, special)

            if count < 0 {
                let needed = max(128, Int(-count) + 8)
                buffer = [CChar](repeating: 0, count: needed)
                count = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, special)
            }

            guard count > 0 else { return nil }
            return buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        }

        // Try normal rendering first. If the token is special/control, many runtimes only
        // expose its textual marker when `special=true`.
        return renderPiece(special: false) ?? renderPiece(special: true)
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
        recentTokenCounts: [llama_token: Int],
        controlTokenCache: inout [llama_token: Bool]
    ) -> llama_token {
        let clippedTemp = sanitizeTemperature(temperature)
        if clippedTemp <= 0.05 {
            // Keep tool/planner turns deterministic, but still apply a small repetition
            // penalty so low-temperature decoding doesn't get stuck in micro-loops.
            var bestToken: llama_token?
            var bestLogit = -Float.greatestFiniteMagnitude

            for i in 0..<vocabSize {
                let token = llama_token(i)
                if isControlLikeTokenCached(token, vocab: vocab, cache: &controlTokenCache) { continue }

                var l = logits[i]
                guard l.isFinite else { continue }
                if let repeats = recentTokenCounts[token], repeats > 0 {
                    let cappedRepeats = min(4, repeats)
                    l -= 0.55 * Float(cappedRepeats)
                }

                if l > bestLogit {
                    bestLogit = l
                    bestToken = token
                }
            }

            return bestToken ?? pickToken(logits: logits, vocabSize: vocabSize, vocab: vocab, controlTokenCache: &controlTokenCache)
        }

        let topK = min(64, vocabSize)
        var candidates: [(token: llama_token, logit: Float)] = []
        candidates.reserveCapacity(topK)

        for i in 0..<vocabSize {
            let token = llama_token(i)
            if isControlLikeTokenCached(token, vocab: vocab, cache: &controlTokenCache) { continue }

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
            return pickToken(logits: logits, vocabSize: vocabSize, vocab: vocab, controlTokenCache: &controlTokenCache)
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

    private static func buildFramedPrompt(userPrompt: String, modelPath: String, promptFamily: PromptFamily? = nil) -> String {
        let cleanUserPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = defaultSystemPrompt

        switch promptFamily ?? detectPromptFamily(from: modelPath) {
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
        case .gemma:
            return """
            <start_of_turn>system
            \(systemPrompt)<end_of_turn>
            <start_of_turn>user
            \(cleanUserPrompt)<end_of_turn>
            <start_of_turn>model
            """
        case .alpaca:
            return """
            Below is an instruction that describes a task. Write a response that appropriately completes the request.

            ### Instruction:
            \(systemPrompt)

            User request: \(cleanUserPrompt)

            ### Response:
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
        case gemma
        case alpaca
    }

    private static func promptFamilyFallbackOrder(preferred: PromptFamily) -> [PromptFamily] {
        // Try model-specific framing first, then progressively more permissive templates.
        let order: [PromptFamily] = [
            preferred,
            .llama3,
            .chatML,
            .mistralInstruct,
            .gemma,
            .alpaca,
            .plain
        ]

        var seen = Set<String>()
        var unique: [PromptFamily] = []
        for family in order {
            let key = promptFamilyLabel(family)
            if seen.contains(key) { continue }
            seen.insert(key)
            unique.append(family)
        }
        return unique
    }

    private static func promptFamilyLabel(_ family: PromptFamily) -> String {
        switch family {
        case .plain: return "plain"
        case .chatML: return "chatml"
        case .llama3: return "llama3"
        case .mistralInstruct: return "mistral_instruct"
        case .gemma: return "gemma"
        case .alpaca: return "alpaca"
        }
    }

    private static func detectPromptFamily(from modelPath: String) -> PromptFamily {
        let fileName = URL(fileURLWithPath: modelPath)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
        let normalizedFileName = normalizeModelIdentifier(fileName)

        // Also inspect parent folders/repo slug hints for imported models with generic filenames.
        let normalizedPath = normalizeModelIdentifier(modelPath.lowercased())
        let modelSignature = normalizedFileName + " " + normalizedPath

        // Llama 2 chat/instruct checkpoints expect [INST] wrappers and degrade with Llama 3 templates.
        // Check this first so names like "llama-2-...-instruct" don't get misclassified.
        let llama2Hints = ["llama-2", "llama2"]
        if llama2Hints.contains(where: { modelSignature.contains($0) }) &&
            (modelSignature.contains("chat") || modelSignature.contains("instruct")) {
            return .mistralInstruct
        }

        // Llama 3/3.1/3.2/4 and derivatives generally expect header-id chat templates.
        // Normalize separators so names like "Llama_3.2" still map correctly.
        let llamaHeaderTemplateHints = [
            "llama-3", "llama3", "meta-llama-3", "meta-llama3",
            // Common variants after normalization (e.g. "Llama-3.1" -> "llama-3-1").
            "llama-3-1", "llama-31", "llama31",
            "llama-3-2", "llama-32", "llama32",
            // Newer Llama checkpoints (e.g. Llama-4 Scout/Maverick) still use
            // chat-header style framing; avoid misclassifying them as [INST].
            "llama-4", "llama4", "meta-llama-4", "meta-llama4"
        ]
        if llamaHeaderTemplateHints.contains(where: { modelSignature.contains($0) }) {
            return .llama3
        }

        // Legacy/derived Llama chat checkpoints (e.g. TinyLlama/CodeLlama Instruct)
        // usually expect [INST] framing instead of plain "User/Assistant" prompts.
        if modelSignature.contains("llama") &&
            (modelSignature.contains("chat") || modelSignature.contains("instruct")) {
            return .mistralInstruct
        }

        // Qwen/Phi/DeepSeek and similar instruct variants usually expect ChatML markers.
        let chatMLHints = ["qwen", "qwq", "phi", "deepseek", "yi", "internlm", "smollm", "granite"]
        if chatMLHints.contains(where: { modelSignature.contains($0) }) {
            return .chatML
        }

        // Gemma / Gemma 2 style checkpoints generally expect turn tags.
        let gemmaHints = ["gemma", "medgemma"]
        if gemmaHints.contains(where: { modelSignature.contains($0) }) {
            return .gemma
        }

        // Mistral/Mixtral-style instruct models tend to follow [INST] wrappers.
        let mistralInstructHints = ["mistral", "mixtral", "zephyr", "openchat", "solar", "nous-hermes-2", "nemo-instruct"]
        if mistralInstructHints.contains(where: { modelSignature.contains($0) }) {
            return .mistralInstruct
        }

        // Older instruction-tuned checkpoints (Alpaca/Vicuna/WizardLM family) prefer ### Instruction/Response tags.
        let alpacaHints = ["alpaca", "vicuna", "wizardlm", "guanaco", "orca-mini", "koala", "airoboros"]
        if alpacaHints.contains(where: { modelSignature.contains($0) }) {
            return .alpaca
        }

        return .plain
    }

    private static func normalizeModelIdentifier(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    private static func sanitizeDecodedOutput(_ text: String) -> String {
        stripReasoningBlocks(from: text)
            .replacingOccurrences(of: #"(?im)^\s*(assistant|asistente|model|modelo)\s*:\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?im)^\s*(assistant|asistente|model|modelo)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?im)^\s*(user|usuario|system|sistema)\s*:.*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "<|begin_of_text|>", with: "")
            .replacingOccurrences(of: "<|eot_id|>", with: "")
            .replacingOccurrences(of: "<|eom_id|>", with: "")
            .replacingOccurrences(of: "<|end|>", with: "")
            .replacingOccurrences(of: "<|end_of_text|>", with: "")
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .replacingOccurrences(of: "<|im_start|>", with: "")
            .replacingOccurrences(of: "<|start_header_id|>", with: "")
            .replacingOccurrences(of: "<|end_header_id|>", with: "")
            .replacingOccurrences(of: "<｜end▁of▁sentence｜>", with: "")
            .replacingOccurrences(of: "<｜User｜>", with: "")
            .replacingOccurrences(of: "<｜Assistant｜>", with: "")
            .replacingOccurrences(of: "<start_of_turn>", with: "")
            .replacingOccurrences(of: "<end_of_turn>", with: "")
            .replacingOccurrences(of: "<s>", with: "")
            .replacingOccurrences(of: "</s>", with: "")
            .replacingOccurrences(of: "[INST]", with: "")
            .replacingOccurrences(of: "[/INST]", with: "")
            .replacingOccurrences(of: "<<SYS>>", with: "")
            .replacingOccurrences(of: "<</SYS>>", with: "")
            .replacingOccurrences(of: "### Instruction:", with: "")
            .replacingOccurrences(of: "### Response:", with: "")
            .replacingOccurrences(of: "### User:", with: "")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripReasoningBlocks(from text: String) -> String {
        var cleaned = text

        let patterns = [
            #"(?is)<think>.*?</think>"#,
            #"(?is)<thinking>.*?</thinking>"#,
            #"(?is)```(?:thinking|reasoning)\b.*?```"#,
            // Some local checkpoints truncate before a closing marker; drop the dangling tail.
            #"(?is)<think>.*$"#,
            #"(?is)<thinking>.*$"#,
            #"(?is)```(?:thinking|reasoning)\b.*$"#
        ]

        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        return cleaned
    }

    private static func stripPromptEcho(from output: String, userPrompt: String) -> String {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else { return "" }

        let cleanPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrompt.isEmpty else { return trimmedOutput }

        let normalizedOutput = normalizeWhitespace(trimmedOutput)
        let normalizedPrompt = normalizeWhitespace(cleanPrompt)

        if normalizedOutput == normalizedPrompt { return "" }

        let candidates = [
            cleanPrompt,
            "User: \(cleanPrompt)",
            "Usuario: \(cleanPrompt)",
            "Pregunta: \(cleanPrompt)"
        ]

        for candidate in candidates {
            let candidateTrimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidateTrimmed.isEmpty { continue }
            if trimmedOutput.hasPrefix(candidateTrimmed) {
                let remainder = String(trimmedOutput.dropFirst(candidateTrimmed.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !remainder.isEmpty {
                    return remainder
                }
            }
        }

        // Common failure mode on smaller GGUF checkpoints: first line mirrors the user
        // prompt (sometimes with role labels/quotes), followed by the real answer.
        // Strip that leading echoed line conservatively only when non-empty content remains.
        if let newline = trimmedOutput.firstIndex(of: "\n") {
            let firstLine = String(trimmedOutput[..<newline])
            let remainder = String(trimmedOutput[trimmedOutput.index(after: newline)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                let normalizedFirstLine = normalizeEchoLine(firstLine)
                if !normalizedFirstLine.isEmpty, normalizedFirstLine == normalizedPrompt {
                    return remainder
                }
            }
        }

        return trimmedOutput
    }

    private static func stripSystemPromptEcho(from output: String) -> String {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else { return "" }

        let normalizedSystemPrompt = normalizeWhitespace(defaultSystemPrompt)
        guard !normalizedSystemPrompt.isEmpty else { return trimmedOutput }

        let normalizedOutput = normalizeWhitespace(trimmedOutput)
        if normalizedOutput == normalizedSystemPrompt {
            return ""
        }

        let quotedPrefixes = [
            defaultSystemPrompt,
            "\"\(defaultSystemPrompt)\"",
            "'\(defaultSystemPrompt)'"
        ]

        for prefix in quotedPrefixes {
            if trimmedOutput.hasPrefix(prefix) {
                let remainder = String(trimmedOutput.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !remainder.isEmpty {
                    return remainder
                }
            }
        }

        if let newline = trimmedOutput.firstIndex(of: "\n") {
            let firstLine = String(trimmedOutput[..<newline])
            let remainder = String(trimmedOutput[trimmedOutput.index(after: newline)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty, normalizeWhitespace(firstLine) == normalizedSystemPrompt {
                return remainder
            }
        }

        return trimmedOutput
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeEchoLine(_ line: String) -> String {
        normalizeWhitespace(
            line
                .replacingOccurrences(of: #"(?im)^\s*(assistant|asistente|model|modelo)\s*:\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?im)^\s*(you asked|you said|prompt|pregunta|user|usuario)\s*[:\-]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`“”‘’«»[](){}*_")))
        )
    }

    private static func isLowSignalResponse(_ text: String, mode: LlamaGenerationMode) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Tool mode can legitimately emit terse JSON like "{}" or "[]".
        if mode == .tools {
            return false
        }

        let lowered = trimmed.lowercased()
        if ["assistant", "asistente", "model", "modelo"].contains(lowered) {
            return true
        }

        let hasLetterOrDigit = trimmed.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        if hasLetterOrDigit { return false }

        // Treat punctuation-only / marker-only emissions as low-quality so callers can retry.
        return true
    }

    private static func isTemplateLeakResponse(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let markers = [
            "<|", "|>",
            "<start_of_turn>", "<end_of_turn>",
            "<｜", "｜>",
            "[INST]", "[/INST]", "<<SYS>>", "<</SYS>>",
            "### Instruction:", "### Response:", "### User:",
            "begin_of_text", "start_header_id", "end_header_id", "eot_id"
        ]

        let lower = trimmed.lowercased()
        let markerHits = markers.reduce(into: 0) { count, marker in
            if lower.contains(marker.lowercased()) {
                count += 1
            }
        }

        // If multiple protocol markers leak, output quality is typically unusable.
        if markerHits >= 2 { return true }

        // Single marker with very short text is usually just framing residue.
        if markerHits == 1, trimmed.count <= 80 { return true }

        return false
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
            "<|eom_id|>",
            "<|end|>",
            "<|end_of_text|>",
            "<|im_end|>",
            "<|im_start|>",
            "<|start_header_id|>user<|end_header_id|>",
            "<｜end▁of▁sentence｜>",
            "<｜User｜>",
            "</s>",
            "[INST]",
            "[/INST]",
            "### Instruction:",
            "### User:",
            "### Input:",
            "<start_of_turn>user",
            "<start_of_turn>system",
            "<end_of_turn>"
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

        // iOS can persist bookmarks with /private/var/... while runtime paths resolve to /var/... (or vice versa).
        for variant in privatePathVariants(for: normalizedPath) {
            if FileManager.default.fileExists(atPath: variant) {
                return variant
            }
        }

        // iOS app container paths can change across reinstalls/updates while file names remain stable.
        let fileName = URL(fileURLWithPath: normalizedPath).lastPathComponent
        guard !fileName.isEmpty else { return normalizedPath }

        do {
            let docs = try LocalModelConfig.shared.documentsDirectory()
            let modelsDir = LocalModelConfig.shared.modelsDirectory(in: docs)

            // Try exact filename candidates first (decoded and query-fragment stripped variants).
            for candidateName in modelFileNameCandidates(from: fileName) {
                let candidate = modelsDir
                    .appendingPathComponent(candidateName, isDirectory: false)
                    .standardizedFileURL
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate.path
                }
            }

            // If the file was renamed/re-quantized, prefer the closest stem match in app storage.
            let requestedStem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.lowercased()
            if !requestedStem.isEmpty {
                let available = LocalModelConfig.shared.availableModels(in: docs)
                if let stemMatch = bestStemMatch(for: requestedStem, in: available) {
                    return stemMatch.path
                }
            }
        } catch {
            // Keep original path on lookup failures.
        }

        return normalizedPath
    }

    private static func modelFileNameCandidates(from rawFileName: String) -> [String] {
        let base = rawFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return [] }

        var candidates: [String] = []

        func appendUnique(_ value: String) {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            if !candidates.contains(clean) {
                candidates.append(clean)
            }
        }

        appendUnique(base)
        appendUnique(base.removingPercentEncoding ?? base)

        for value in Array(candidates) {
            if let hashIndex = value.firstIndex(of: "#") {
                appendUnique(String(value[..<hashIndex]))
            }
            if let queryIndex = value.firstIndex(of: "?") {
                appendUnique(String(value[..<queryIndex]))
            }
        }

        return candidates
    }

    private static func bestStemMatch(for requestedStem: String, in available: [URL]) -> URL? {
        guard !available.isEmpty else { return nil }

        // 1) Exact normalized match.
        let requestedNormalized = normalizeStemForMatch(requestedStem)
        guard !requestedNormalized.isEmpty else { return nil }

        let exactMatches = available.filter {
            normalizeStemForMatch($0.deletingPathExtension().lastPathComponent.lowercased()) == requestedNormalized
        }
        if let exact = pickBestModelCandidate(from: exactMatches, requestedStem: requestedStem) {
            return exact
        }

        // 2) Relaxed contains match so re-quantized/renamed files still resolve.
        let relaxedMatches = available.filter {
            let candidate = normalizeStemForMatch($0.deletingPathExtension().lastPathComponent.lowercased())
            return candidate.contains(requestedNormalized) || requestedNormalized.contains(candidate)
        }
        if let relaxed = pickBestModelCandidate(from: relaxedMatches, requestedStem: requestedStem) {
            return relaxed
        }

        return nil
    }

    private static func pickBestModelCandidate(from candidates: [URL], requestedStem: String) -> URL? {
        guard !candidates.isEmpty else { return nil }

        let requestedHint = quantizationHint(from: requestedStem)

        return candidates.max { lhs, rhs in
            let lhsName = lhs.deletingPathExtension().lastPathComponent.lowercased()
            let rhsName = rhs.deletingPathExtension().lastPathComponent.lowercased()

            let lhsScore = quantizationPreferenceScore(candidate: lhsName, requestedHint: requestedHint)
            let rhsScore = quantizationPreferenceScore(candidate: rhsName, requestedHint: requestedHint)
            if lhsScore != rhsScore { return lhsScore < rhsScore }

            let lhsSize = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let rhsSize = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if lhsSize != rhsSize { return lhsSize < rhsSize }

            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }
    }

    private static func quantizationPreferenceScore(candidate: String, requestedHint: String?) -> Int {
        let hint = quantizationHint(from: candidate)
        var score = quantizationQualityRank(from: hint)
        if let requestedHint, !requestedHint.isEmpty, hint == requestedHint {
            score += 1_000
        }
        return score
    }

    private static func quantizationHint(from stem: String) -> String? {
        let lower = stem.lowercased()

        let explicitHints = ["fp32", "f32", "fp16", "f16", "bf16"]
        if let hit = explicitHints.first(where: { lower.contains($0) }) {
            return hit
        }

        if let regex = try? NSRegularExpression(pattern: #"(?i)\biq\d+"#) {
            let nsRange = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            if let match = regex.firstMatch(in: lower, options: [], range: nsRange),
               let range = Range(match.range, in: lower) {
                return String(lower[range])
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"(?i)\bq\d+"#) {
            let nsRange = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            if let match = regex.firstMatch(in: lower, options: [], range: nsRange),
               let range = Range(match.range, in: lower) {
                return String(lower[range])
            }
        }

        return nil
    }

    private static func quantizationQualityRank(from hint: String?) -> Int {
        guard let hint else { return 0 }

        switch hint {
        case "fp32", "f32": return 160
        case "fp16", "f16", "bf16": return 150
        default:
            if hint.hasPrefix("iq") {
                let digits = hint.dropFirst(2)
                if let level = Int(digits) {
                    return 110 + (level * 10)
                }
            }
            if hint.hasPrefix("q") {
                let digits = hint.dropFirst(1)
                if let level = Int(digits) {
                    return 80 + (level * 10)
                }
            }
            return 0
        }
    }

    private static func normalizeStemForMatch(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"[-_ ]q\d+([_.-]k[_.-]?[msl])?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[-_ ](iq\d+|fp16|f16|f32|bf16|int4|int8|instruct|chat|gguf)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unwrapQuotedPath(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        if (raw.hasPrefix("\"") && raw.hasSuffix("\"")) ||
            (raw.hasPrefix("'") && raw.hasSuffix("'")) {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    private static func privatePathVariants(for path: String) -> [String] {
        var variants: [String] = []
        if path.hasPrefix("/private/") {
            variants.append(String(path.dropFirst("/private".count)))
        } else if path.hasPrefix("/var/") {
            variants.append("/private" + path)
        }
        return variants
    }
}
