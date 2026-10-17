import Foundation

enum MetadataRequest {
    /// OMDb is optional and always uses the user's own configured credential.
    static func omdbURL(apiKey: String, parameters: [URLQueryItem]) -> URL? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.omdbapi.com"
        components.path = "/"
        components.queryItems = parameters.filter { $0.name.lowercased() != "apikey" }
            + [URLQueryItem(name: "apikey", value: key)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
