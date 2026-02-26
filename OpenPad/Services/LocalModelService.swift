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
            let llamaMode: LlamaGenerationMode = (purpose == .tools) ? .tools : .chat
            do {
                try autoConfigureModelIfPresent()
                let out = try await llama.runLocal(prompt: prompt, mode: llamaMode)
                return sanitizeModelOutput(out)
            } catch LlamaServiceError.modelNotConfigured {
                try await Task.sleep(nanoseconds: 300_000_000)
                return "No llama.swift model selected. Add a .gguf in Models and select it in Settings."
            } catch LlamaServiceError.modelFileNotFound(_) {
                return "The selected llama.swift model file is missing. Re-select a .gguf in Settings."
            } catch LlamaServiceError.emptyResponse {
                let retryPrompt = buildLlamaRetryPrompt(from: prompt, purpose: purpose, reason: .emptyResponse)
                if let retry = try? await llama.runLocal(prompt: retryPrompt, mode: llamaMode) {
                    let sanitized = sanitizeModelOutput(retry)
                    if !sanitized.isEmpty { return sanitized }
                }
                return "The local llama.swift model returned an empty answer. Please retry with a shorter prompt."
            } catch LlamaServiceError.decodeFailed(_) {
                let retryPrompt = buildLlamaRetryPrompt(from: prompt, purpose: purpose, reason: .decodeFailed)
                if retryPrompt != prompt,
                   let retry = try? await llama.runLocal(prompt: retryPrompt, mode: llamaMode) {
                    let sanitized = sanitizeModelOutput(retry)
                    if !sanitized.isEmpty { return sanitized }
                }
                return "The local llama.swift backend hit a decode limit. Try a shorter message or switch to stable profile."
            } catch LlamaServiceError.tokenizationFailed {
                // Recover once with a compact, control-char-stripped prompt. This helps
                // on native GGUF checkpoints that fail tokenization on very long or
                // noisy pasted content.
                let retryPrompt = buildLlamaRetryPrompt(from: prompt, purpose: purpose, reason: .tokenizationFailed)
                if retryPrompt != prompt,
                   let retry = try? await llama.runLocal(prompt: retryPrompt, mode: llamaMode) {
                    let sanitized = sanitizeModelOutput(retry)
                    if !sanitized.isEmpty { return sanitized }
                }
                return "The prompt could not be tokenized by the local llama.swift model. I retried with a compact/sanitized prompt, but it still failed. Try removing unusual symbols and retry."
            } catch LlamaServiceError.vocabularyUnavailable {
                return "The selected llama.swift model did not expose a usable vocabulary. Re-select a valid GGUF and retry."
            } catch LlamaServiceError.backendBusyTimeout {
                return "llama.swift is still finishing a previous response. Please retry in a few seconds."
            } catch LlamaServiceError.generationTimedOut {
                // One compact retry often succeeds on constrained devices where the
                // first attempt spends most of the budget processing long context.
                let retryPrompt = buildLlamaRetryPrompt(from: prompt, purpose: purpose, reason: .generationTimedOut)
                if let retry = try? await llama.runLocal(prompt: retryPrompt, mode: llamaMode) {
                    let sanitized = sanitizeModelOutput(retry)
                    if !sanitized.isEmpty { return sanitized }
                }
                return "The local llama.swift model timed out before completing an answer. I retried with a compact prompt but it still timed out. Try a shorter message or switch to stable profile."
            } catch LlamaServiceError.cancelled {
                return "Cancelled local llama.swift generation. You can retry with a shorter prompt."
            } catch LlamaServiceError.nativeBackendUnavailable {
                return "Native llama.swift backend is unavailable in this build. Enable the llama module or use MLX."
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

    private enum LlamaRetryReason {
        case emptyResponse
        case decodeFailed
        case tokenizationFailed
        case generationTimedOut
    }

    private func buildLlamaRetryPrompt(from prompt: String, purpose: LocalInferencePurpose, reason: LlamaRetryReason) -> String {
        let compactLimit: Int = (reason == .generationTimedOut) ? 1600 : 1800
        let suffix = String(prompt.suffix(compactLimit))

        // Keep printable text plus common whitespace; drop control scalars that can
        // break tokenization on some native GGUF vocabularies.
        let cleanedScalars = suffix.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\r" || scalar == "\t" { return true }
            return !CharacterSet.controlCharacters.contains(scalar)
        }
        let cleaned = String(String.UnicodeScalarView(cleanedScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let payload = cleaned.isEmpty ? String(prompt.suffix(1200)).trimmingCharacters(in: .whitespacesAndNewlines) : cleaned

        switch purpose {
        case .chat:
            switch reason {
            case .emptyResponse:
                return "Answer directly in one short paragraph:\n\n\(payload)"
            case .generationTimedOut:
                return "Answer directly and concisely in at most 6 sentences:\n\n\(payload)"
            case .decodeFailed, .tokenizationFailed:
                return "Answer directly and concisely based on this compact prompt:\n\n\(payload)"
            }
        case .tools:
            // Preserve deterministic tool/planner behavior: keep JSON-oriented guidance
            // even during retries so we don't regress into prose answers.
            return "Return only valid JSON with no markdown or explanations. Use an empty JSON object {} if uncertain.\n\n\(payload)"
        }
    }

    private func sanitizeModelOutput(_ text: String) -> String {
        var out = text

        // Remove chain-of-thought blocks emitted by some reasoning models.
        out = out.replacingOccurrences(of: #"(?is)<think>.*?</think>"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?im)^\s*thinking:\s*.*$"#, with: "", options: .regularExpression)

        // Strip common role/header artifacts that leak from prompts.
        out = out.replacingOccurrences(of: #"(?im)^\s*(assistant|asistente)\s*:\s*"#, with: "", options: .regularExpression)
        out = stripLeadingRoleLeakPreamble(out)

        // If the model leaks "mensaje del usuario:" scaffolding at the very start,
        // strip only that leading label block instead of truncating any later mention.
        if let leakedPrefix = out.range(of: #"(?is)^\s*mensaje del usuario\s*:.*?(?:\n\s*\n|\n)"#, options: .regularExpression) {
            let remainder = String(out[leakedPrefix.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remainder.isEmpty {
                out = remainder
            }
        }

        // Normalize runaway blank lines.
        out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)

        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty {
            return "I processed your request, but the model returned an internal reasoning block only. Please retry."
        }
        return out
    }

    private func stripLeadingRoleLeakPreamble(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return text }

        func isLeakedRoleLine(_ line: String) -> Bool {
            line.range(
                of: #"(?i)^\s*(user|usuario|system|sistema)\s*:\s*.*$"#,
                options: .regularExpression
            ) != nil
        }

        var idx = 0
        while idx < lines.count {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                idx += 1
                continue
            }
            if isLeakedRoleLine(lines[idx]) {
                idx += 1
                continue
            }
            break
        }

        if idx == 0 || idx >= lines.count { return text }
        let remainder = lines[idx...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? text : remainder
    }

    private func autoConfigureModelIfPresent() throws {
        let modelConfig = LocalModelConfig.shared
        let docs = try modelConfig.documentsDirectory()

        let persisted = runtimeConfig.loadLlama().model.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = modelConfig.loadSelectedModelPath()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = modelConfig.firstExistingModelPath(in: docs)?.path ?? ""

        var candidates: [String] = []
        for path in [persisted, selected, fallback] where !path.isEmpty {
            if !candidates.contains(path) { candidates.append(path) }
        }

        for candidate in candidates {
            do {
                let resolved = try llama.configureModel(path: candidate)

                if selected != resolved {
                    modelConfig.saveSelectedModelPath(resolved)
                }
                if persisted != resolved {
                    let cfg = runtimeConfig.loadLlama()
                    runtimeConfig.saveLlama(baseURL: cfg.baseURL, model: resolved)
                }
                return
            } catch LlamaServiceError.modelNotConfigured {
                continue
            } catch LlamaServiceError.modelFileNotFound(_) {
                continue
            }
        }
    }
}
