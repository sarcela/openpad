import Foundation

#if canImport(LlamaCpp)
import LlamaCpp
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
        #if canImport(LlamaCpp) || canImport(llama)
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
        #elseif canImport(llama)
        // Compile-safe hook for C module `llama`.
        _ = prompt
        _ = modelPath
        throw LlamaServiceError.nativeBackendUnavailable("llama module detected but adapter is not bound to package API yet")
        #else
        return nil
        #endif
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
