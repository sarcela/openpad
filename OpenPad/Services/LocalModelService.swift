import Foundation

enum LocalInferencePurpose {
    case chat
    case tools
}

final class LocalModelService {
    private let llama = LlamaLocalModelService()
    private let mlx = MLXLocalModelService()

    private let runtimeConfig = LocalRuntimeConfig.shared
    private let liteConfig = OpenClawLiteConfig.shared

    func runLocal(prompt: String, purpose: LocalInferencePurpose = .chat, modelOverride: String? = nil) async throws -> String {
        let prepared = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let emergency = runtimeConfig.isEmergencyMemoryModeEnabled()
        let largePromptThreshold = emergency ? 4200 : (liteConfig.isLowPowerModeEnabled() ? 7000 : 12000)

        if prepared.count > largePromptThreshold {
            let reduced = try await reducePromptMemory(prepared, purpose: purpose)
            return try await runLocalDirect(prompt: reduced, purpose: purpose, modelOverride: modelOverride)
        }

        return try await runLocalDirect(prompt: prepared, purpose: purpose, modelOverride: modelOverride)
    }

    private func runLocalDirect(prompt: String, purpose: LocalInferencePurpose, modelOverride: String? = nil) async throws -> String {
        switch runtimeConfig.loadProvider() {
        case .llamaCpp:
            do {
                try autoConfigureModelIfPresent()
                let out = try await llama.runLocal(prompt: prompt)
                return sanitizeModelOutput(out)
            } catch LlamaServiceError.modelNotConfigured {
                try await Task.sleep(nanoseconds: 300_000_000)
                return "No llama.cpp model selected. Add a .gguf in Models and select it in Settings."
            } catch LlamaServiceError.modelFileNotFound(_) {
                return "The selected llama.cpp model file is missing. Re-select a .gguf in Settings."
            } catch LlamaServiceError.emptyResponse {
                let retryPrompt = "Answer directly in one short paragraph:\n\n\(String(prompt.suffix(1400)))"
                if let retry = try? await llama.runLocal(prompt: retryPrompt) {
                    let sanitized = sanitizeModelOutput(retry)
                    if !sanitized.isEmpty { return sanitized }
                }
                return "The local llama.cpp model returned an empty answer. Please retry with a shorter prompt."
            } catch LlamaServiceError.decodeFailed(_) {
                let compactPrompt = String(prompt.suffix(1800))
                if compactPrompt != prompt {
                    let retryPrompt = "Answer concisely and directly:\n\n\(compactPrompt)"
                    if let retry = try? await llama.runLocal(prompt: retryPrompt) {
                        let sanitized = sanitizeModelOutput(retry)
                        if !sanitized.isEmpty { return sanitized }
                    }
                }
                return "The local llama.cpp backend hit a decode limit. Try a shorter message or switch to stable profile."
            } catch LlamaServiceError.tokenizationFailed {
                return "The prompt could not be tokenized by the local llama.cpp model. Try removing unusual symbols and retry."
            } catch LlamaServiceError.vocabularyUnavailable {
                return "The selected llama.cpp model did not expose a usable vocabulary. Re-select a valid GGUF and retry."
            } catch LlamaServiceError.nativeBackendUnavailable {
                return "Native llama.cpp backend is unavailable in this build. Enable the llama module or use MLX."
            }
        case .mlx:
            let chatModel = runtimeConfig.loadMLXModelName()
            let chosenModel: String?
            if let forced = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !forced.isEmpty {
                chosenModel = forced
            } else {
                switch purpose {
                case .chat:
                    chosenModel = chatModel
                case .tools:
                    // Avoid OOM by preventing double-loading large models in the same interaction.
                    if runtimeConfig.isSeparateMLXToolsModelEnabled() {
                        chosenModel = runtimeConfig.loadMLXToolsModelName()
                    } else {
                        chosenModel = chatModel
                    }
                }
            }
            let out = try await mlx.runLocal(prompt: prompt, modelIdOverride: chosenModel)
            return sanitizeModelOutput(out)
        }
    }

    private func reducePromptMemory(_ prompt: String, purpose: LocalInferencePurpose) async throws -> String {
        let emergency = runtimeConfig.isEmergencyMemoryModeEnabled()
        let chunkSize = emergency ? 1500 : (liteConfig.isLowPowerModeEnabled() ? 2200 : 3200)
        let maxChunks = emergency ? 3 : (liteConfig.isLowPowerModeEnabled() ? 4 : 6)
        let chunks = splitText(prompt, size: chunkSize).prefix(maxChunks)

        var summaries: [String] = []
        for (idx, c) in chunks.enumerated() {
            let summarizePrompt = "Summarize this chunk in <= 8 bullets preserving concrete facts, filenames, numbers, and constraints.\n\nChunk \(idx + 1):\n\(c)"
            let s = try await runLocalDirect(prompt: summarizePrompt, purpose: .chat)
            summaries.append(String(s.prefix(1200)))
        }

        let merged = summaries.joined(separator: "\n\n")
        let reducePrompt = "Merge these chunk summaries into a compact context preserving critical details for the next model step.\n\n\(merged)"
        let compact = try await runLocalDirect(prompt: reducePrompt, purpose: .chat)

        return "[memory-guard condensed prompt]\n\(compact)\n\n[original task preserved]\nPurpose: \(purpose == .tools ? "tools" : "chat")"
    }

    private func splitText(_ text: String, size: Int) -> [String] {
        guard !text.isEmpty else { return [] }
        var out: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[idx..<end]))
            idx = end
            if out.count >= 12 { break }
        }
        return out
    }

    private func sanitizeModelOutput(_ text: String) -> String {
        var out = text

        // Remove chain-of-thought blocks emitted by some reasoning models.
        out = out.replacingOccurrences(of: #"(?is)<think>.*?</think>"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?im)^\s*thinking:\s*.*$"#, with: "", options: .regularExpression)

        // Strip common role/header artifacts that leak from prompts.
        out = out.replacingOccurrences(of: #"(?im)^\s*(assistant|asistente)\s*:\s*"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?im)^\s*(user|usuario|system|sistema)\s*:.*$"#, with: "", options: .regularExpression)

        // If the model starts echoing prompt labels, keep only the useful prefix.
        if let range = out.range(of: #"(?i)\bmensaje del usuario\s*:"#, options: .regularExpression) {
            out = String(out[..<range.lowerBound])
        }

        // Normalize runaway blank lines.
        out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)

        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty {
            return "I processed your request, but the model returned an internal reasoning block only. Please retry."
        }
        return out
    }

    private func autoConfigureModelIfPresent() throws {
        let docs = try LocalModelConfig.shared.documentsDirectory()
        if let modelURL = LocalModelConfig.shared.firstExistingModelPath(in: docs),
           FileManager.default.fileExists(atPath: modelURL.path) {
            try llama.configureModel(path: modelURL.path)
        }
    }
}
