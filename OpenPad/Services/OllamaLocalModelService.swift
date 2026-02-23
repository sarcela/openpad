import Foundation

enum OllamaServiceError: LocalizedError {
    case invalidBaseURL
    case badStatus(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid Ollama URL"
        case .badStatus(let code, let body):
            return "Ollama HTTP \(code): \(body.prefix(180))"
        case .emptyResponse:
            return "Ollama returned an empty response"
        }
    }
}

final class OllamaLocalModelService {
    private let config = LocalRuntimeConfig.shared

    func runLocal(prompt: String) async throws -> String {
        let cfg = config.loadOllama()
        guard var base = URL(string: cfg.baseURL) else { throw OllamaServiceError.invalidBaseURL }
        base.append(path: "api/generate")

        var req = URLRequest(url: base)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = OllamaGenerateRequest(model: cfg.model, prompt: prompt, stream: false)
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaServiceError.emptyResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw OllamaServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        let text = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw OllamaServiceError.emptyResponse }
        return text
    }
}

private struct OllamaGenerateRequest: Codable {
    let model: String
    let prompt: String
    let stream: Bool
}

private struct OllamaGenerateResponse: Codable {
    let response: String
}
