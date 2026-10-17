import Foundation

enum AIRequestError: LocalizedError {
    case invalidModel, unsupportedProvider, invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidModel: return "Enter a valid model ID for the selected provider."
        case .unsupportedProvider: return "Choose an API provider."
        case .invalidResponse: return "The provider returned no text. Try again or check model access."
        }
    }
}

/// Request construction and response parsing, shared by the app and offline tests.
enum AIAPITransport {
    static func request(provider: AIProvider, apiKey: String, model: String, prompt: String) throws -> URLRequest {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$"#, options: .regularExpression) != nil else {
            throw AIRequestError.invalidModel
        }
        var endpoint: String
        var headers: [String: String] = ["Content-Type": "application/json"]
        let body: [String: Any]
        switch provider {
        case .openaiAPI:
            endpoint = "https://api.openai.com/v1/chat/completions"
            headers["Authorization"] = "Bearer \(apiKey)"
            body = ["model": model, "messages": [["role": "user", "content": prompt]], "max_completion_tokens": 8192]
        case .anthropicAPI:
            endpoint = "https://api.anthropic.com/v1/messages"
            headers["x-api-key"] = apiKey
            headers["anthropic-version"] = "2023-06-01"
            body = ["model": model, "max_tokens": 8192, "messages": [["role": "user", "content": prompt]]]
        case .geminiAPI:
            guard model.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
                throw AIRequestError.invalidModel
            }
            endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
            headers["x-goog-api-key"] = apiKey
            body = ["contents": [["parts": [["text": prompt]]]]]
        default: throw AIRequestError.unsupportedProvider
        }
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func text(provider: AIProvider, data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIRequestError.invalidResponse
        }
        var text: String?
        switch provider {
        case .openaiAPI:
            let choices = json["choices"] as? [[String: Any]]
            text = (choices?.first?["message"] as? [String: Any])?["content"] as? String
        case .anthropicAPI:
            let blocks = json["content"] as? [[String: Any]] ?? []
            text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .geminiAPI:
            let candidates = json["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        default: throw AIRequestError.unsupportedProvider
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIRequestError.invalidResponse
        }
        return text
    }
}
