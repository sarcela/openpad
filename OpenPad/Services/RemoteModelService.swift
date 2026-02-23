import Foundation

enum RemoteServiceError: LocalizedError {
    case invalidURL
    case missingToken
    case badStatus(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Remote invalid URL"
        case .missingToken:
            return "Missing remote token"
        case .badStatus(let code, let body):
            return "Remote HTTP \(code): \(body.prefix(220))"
        case .emptyResponse:
            return "Empty remote response"
        }
    }
}

final class RemoteModelService {
    private let config = RemoteModelConfig.shared

    func runRemote(prompt: String) async throws -> String {
        let cfg = config.load()

        switch cfg.provider {
        case .anthropic:
            return try await callAnthropic(prompt: prompt, cfg: cfg)
        case .google:
            return try await callGoogle(prompt: prompt, cfg: cfg)
        default:
            return try await callOpenAICompatible(prompt: prompt, cfg: cfg)
        }
    }

    private func callOpenAICompatible(prompt: String, cfg: RemoteModelConfig.Runtime) async throws -> String {
        guard let url = URL(string: cfg.baseURL) else { throw RemoteServiceError.invalidURL }
        guard !cfg.token.isEmpty || cfg.provider == .ollama else { throw RemoteServiceError.missingToken }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if !cfg.token.isEmpty {
            request.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")
        }
        if !cfg.organization.isEmpty {
            request.setValue(cfg.organization, forHTTPHeaderField: "OpenAI-Organization")
            request.setValue(cfg.organization, forHTTPHeaderField: "HTTP-Referer")
        }
        if !cfg.project.isEmpty {
            request.setValue(cfg.project, forHTTPHeaderField: "OpenAI-Project")
            request.setValue(cfg.project, forHTTPHeaderField: "X-Title")
        }

        let payload = OpenAIChatRequest(
            model: cfg.model,
            messages: [.init(role: "user", content: prompt)],
            temperature: 0.4,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteServiceError.emptyResponse }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        if let decoded = try? JSONDecoder().decode(OpenAIChatResponse.self, from: data),
           let text = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }

        throw RemoteServiceError.emptyResponse
    }

    private func callAnthropic(prompt: String, cfg: RemoteModelConfig.Runtime) async throws -> String {
        guard let url = URL(string: cfg.baseURL) else { throw RemoteServiceError.invalidURL }
        guard !cfg.token.isEmpty else { throw RemoteServiceError.missingToken }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cfg.token, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let payload = AnthropicMessageRequest(
            model: cfg.model,
            max_tokens: 1024,
            messages: [.init(role: "user", content: prompt)]
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteServiceError.emptyResponse }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        if let decoded = try? JSONDecoder().decode(AnthropicMessageResponse.self, from: data) {
            let merged = decoded.content.compactMap { $0.text }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !merged.isEmpty { return merged }
        }

        throw RemoteServiceError.emptyResponse
    }

    private func callGoogle(prompt: String, cfg: RemoteModelConfig.Runtime) async throws -> String {
        guard !cfg.token.isEmpty else { throw RemoteServiceError.missingToken }

        var base = cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            base = "https://generativelanguage.googleapis.com/v1beta/models/\(cfg.model):generateContent?key=\(cfg.token)"
        }
        guard let url = URL(string: base) else { throw RemoteServiceError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = GoogleGenerateRequest(contents: [.init(parts: [.init(text: prompt)])])
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteServiceError.emptyResponse }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        if let decoded = try? JSONDecoder().decode(GoogleGenerateResponse.self, from: data),
           let text = decoded.candidates.first?.content.parts.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }

        throw RemoteServiceError.emptyResponse
    }
}

private struct OpenAIChatRequest: Codable {
    struct Message: Codable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let stream: Bool
}

private struct OpenAIChatResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let content: String?
        }
        let message: Message
    }

    let choices: [Choice]
}

private struct AnthropicMessageRequest: Codable {
    struct Message: Codable {
        let role: String
        let content: String
    }

    let model: String
    let max_tokens: Int
    let messages: [Message]
}

private struct AnthropicMessageResponse: Codable {
    struct ContentBlock: Codable {
        let type: String?
        let text: String?
    }

    let content: [ContentBlock]
}

private struct GoogleGenerateRequest: Codable {
    struct Content: Codable {
        struct Part: Codable { let text: String }
        let parts: [Part]
    }
    let contents: [Content]
}

private struct GoogleGenerateResponse: Codable {
    struct Candidate: Codable {
        struct Content: Codable {
            struct Part: Codable { let text: String? }
            let parts: [Part]
        }
        let content: Content
    }

    let candidates: [Candidate]
}
