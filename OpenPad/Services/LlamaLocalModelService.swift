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

    var errorDescription: String? {
        switch self {
        case .modelNotConfigured: return "No model configured. Set a .gguf path first."
        case .modelFileNotFound(let path): return "Model not found at: \(path)"
        case .nativeBackendUnavailable: return "Native llama.swift backend is unavailable in this build."
        case .tokenizationFailed: return "Failed to tokenize prompt."
        case .decodeFailed(let code): return "llama_decode failed (\(code))."
        case .emptyResponse: return "llama.swift returned an empty response."
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
    private var modelPath: String?

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
        return try await Task.detached(priority: .userInitiated) {
            try Self.runSync(prompt: prompt, modelPath: modelPath)
        }.value
        #else
        throw LlamaServiceError.nativeBackendUnavailable
        #endif
    }

    #if canImport(LlamaSwift)
    private static func runSync(prompt: String, modelPath: String) throws -> String {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw LlamaServiceError.modelFileNotFound(modelPath)
        }

        backendLock.lock(); defer { backendLock.unlock() }
        if !backendInitialized { llama_backend_init(); backendInitialized = true }

        let modelParams = llama_model_default_params()
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaServiceError.nativeBackendUnavailable
        }
        defer { llama_model_free(model) }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 2048
        contextParams.n_batch = 512
        guard let context = llama_init_from_model(model, contextParams) else {
            throw LlamaServiceError.nativeBackendUnavailable
        }
        defer { llama_free(context) }

        let vocab = llama_model_get_vocab(model)
        let framedPrompt = """
        You are OpenPad, a concise and practical assistant.
        User: \(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        Assistant:
        """

        var tokens = [llama_token](repeating: 0, count: max(512, framedPrompt.utf8.count + 8))
        let tokenCount = framedPrompt.withCString { cText in
            llama_tokenize(vocab, cText, Int32(strlen(cText)), &tokens, Int32(tokens.count), true, true)
        }
        guard tokenCount > 0 else { throw LlamaServiceError.tokenizationFailed }
        let promptTokens = Array(tokens.prefix(Int(tokenCount)))

        var batch = llama_batch_init(contextParams.n_batch, 0, 1)
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

        var output = ""
        var currentPos = batch.n_tokens

        for _ in 0..<240 {
            guard let logits = llama_get_logits_ith(context, batch.n_tokens - 1) else { break }
            let vocabSize = Int(llama_vocab_n_tokens(vocab))
            if vocabSize <= 0 { break }

            var maxLogit = logits[0]
            var nextToken: llama_token = 0
            for i in 1..<vocabSize where logits[i] > maxLogit {
                maxLogit = logits[i]; nextToken = llama_token(i)
            }
            if nextToken == llama_vocab_eos(vocab) { break }

            var buffer = [CChar](repeating: 0, count: 128)
            let length = llama_token_to_piece(vocab, nextToken, &buffer, Int32(buffer.count), 0, false)
            if length > 0 {
                let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
                if let piece = String(bytes: bytes, encoding: .utf8) { output += piece }
            }

            batch.n_tokens = 1
            batch.token[0] = nextToken
            batch.pos[0] = currentPos
            batch.n_seq_id[0] = 1
            if let seqIDs = batch.seq_id, let seqID = seqIDs[0] { seqID[0] = 0 }
            batch.logits[0] = 1
            currentPos += 1

            let stepDecode = llama_decode(context, batch)
            guard stepDecode == 0 else { throw LlamaServiceError.decodeFailed(stepDecode) }
        }

        let clean = output
            .replacingOccurrences(of: #"(?im)^\s*(assistant|asistente)\s*:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LlamaServiceError.emptyResponse }
        return clean
    }
    #endif

    private static func normalizeModelPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}
