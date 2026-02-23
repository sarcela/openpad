import Foundation

enum LocalInferencePurpose {
    case chat
    case tools
}

final class LocalModelService {
    private let llama = LlamaLocalModelService()
    private let ollama = OllamaLocalModelService()
    private let mlx = MLXLocalModelService()

    private let runtimeConfig = LocalRuntimeConfig.shared
    private let liteConfig = OpenClawLiteConfig.shared

    func runLocal(prompt: String, purpose: LocalInferencePurpose = .chat) async throws -> String {
        let prepared = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let largePromptThreshold = liteConfig.isLowPowerModeEnabled() ? 7000 : 12000

        if prepared.count > largePromptThreshold {
            let reduced = try await reducePromptMemory(prepared, purpose: purpose)
            return try await runLocalDirect(prompt: reduced, purpose: purpose)
        }

        return try await runLocalDirect(prompt: prepared, purpose: purpose)
    }

    private func runLocalDirect(prompt: String, purpose: LocalInferencePurpose) async throws -> String {
        switch runtimeConfig.loadProvider() {
        case .llamaCpp:
            do {
                try autoConfigureModelIfPresent()
                return try await llama.runLocal(prompt: prompt)
            } catch LlamaServiceError.modelNotConfigured {
                try await Task.sleep(nanoseconds: 300_000_000)
                return "No llama.cpp model selected. Add a .gguf in Models and select it in Settings."
            }
        case .ollama:
            return try await ollama.runLocal(prompt: prompt)
        case .mlx:
            let chatModel = runtimeConfig.loadMLXModelName()
            let modelOverride: String?
            switch purpose {
            case .chat:
                modelOverride = chatModel
            case .tools:
                // Avoid OOM by preventing double-loading large models in the same interaction.
                if runtimeConfig.isSeparateMLXToolsModelEnabled() {
                    modelOverride = runtimeConfig.loadMLXToolsModelName()
                } else {
                    modelOverride = chatModel
                }
            }
            return try await mlx.runLocal(prompt: prompt, modelIdOverride: modelOverride)
        }
    }

    private func reducePromptMemory(_ prompt: String, purpose: LocalInferencePurpose) async throws -> String {
        let chunkSize = liteConfig.isLowPowerModeEnabled() ? 2200 : 3200
        let maxChunks = liteConfig.isLowPowerModeEnabled() ? 4 : 6
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

    private func autoConfigureModelIfPresent() throws {
        let docs = try LocalModelConfig.shared.documentsDirectory()
        if let modelURL = LocalModelConfig.shared.firstExistingModelPath(in: docs),
           FileManager.default.fileExists(atPath: modelURL.path) {
            try llama.configureModel(path: modelURL.path)
        }
    }
}
