import Foundation

enum RemoteServiceError: LocalizedError {
    case invalidURL
    case missingToken
    case badStatus(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Remote URL inválida"
        case .missingToken:
            return "Falta token remoto"
        case .badStatus(let code, let body):
            return "Remote HTTP \(code): \(body.prefix(180))"
        case .emptyResponse:
            return "Respuesta remota vacía"
        }
    }
}

final class RemoteModelService {
    private let config = RemoteModelConfig.shared

    func runRemote(prompt: String) async throws -> String {
        let cfg = config.load()

        guard let url = URL(string: cfg.baseURL) else {
            throw RemoteServiceError.invalidURL
        }
        guard !cfg.token.isEmpty else {
            throw RemoteServiceError.missingToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")

        let payload = ChatCompletionsRequest(
            model: cfg.model,
            messages: [
                .init(role: "user", content: prompt)
            ],
            temperature: 0.4
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw RemoteServiceError.emptyResponse
        }

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RemoteServiceError.badStatus(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
            throw RemoteServiceError.emptyResponse
        }
        return text
    }
}

private struct ChatCompletionsRequest: Codable {
    let model: String
    let messages: [ChatMessagePayload]
    let temperature: Double
}

private struct ChatMessagePayload: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionsResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message
    }

    struct Message: Codable {
        let content: String
    }
}
