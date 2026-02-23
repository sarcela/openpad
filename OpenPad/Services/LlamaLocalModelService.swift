import Foundation

enum LlamaServiceError: LocalizedError {
    case modelNotConfigured
    case modelFileNotFound(String)
    case backendUnavailable
    case invalidBaseURL
    case badStatus(Int, String)
    case emptyResponse
    case nonLocalEndpointBlocked
    case nativeBackendRequired

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
        }
    }
}

final class LlamaLocalModelService {
    private var modelPath: String?
    private let runtimeConfig = LocalRuntimeConfig.shared

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

        // En modo estricto offline, bloqueamos endpoints no locales.
        if runtimeConfig.isOfflineStrictModeEnabled() {
            let cfg = runtimeConfig.loadLlama()
            guard let base = URL(string: cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  isLocalEndpoint(base) else {
                throw LlamaServiceError.nonLocalEndpointBlocked
            }
        }

        // Siempre intentamos primero backend nativo (si existe en el build).
        #if canImport(LlamaCpp)
        // Adapter hook: si integras un paquete con APIs nativas, enrútalo aquí.
        // Hoy mantenemos el camino llama-server local para compatibilidad.
        _ = modelPath
        #endif

        let out = try await runViaLlamaServer(prompt: prompt, modelPath: modelPath)
        if runtimeConfig.isOfflineStrictModeEnabled(), out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LlamaServiceError.nativeBackendRequired
        }
        return out
    }

    private func runViaLlamaServer(prompt: String, modelPath: String) async throws -> String {
        let cfg = runtimeConfig.loadLlama()
        guard var base = URL(string: cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LlamaServiceError.invalidBaseURL
        }

        // Endpoint OpenAI-compatible de llama-server.
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

            // Fallback: algunos builds usan /completion con campo content
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
