import Foundation

/// Parse credentials without echoing the URL into validation errors.
/// TLS is always required with full certificate and hostname verification.
struct DatabaseConnectionSettings {
    let host: String
    let port: Int
    let username: String
    let password: String
    let database: String
    let sslRootCertificate: String?

    init(urlString: String) throws {
        guard let components = URLComponents(string: urlString),
            ["postgres", "postgresql"].contains(components.scheme?.lowercased() ?? ""),
            let host = components.host, !host.isEmpty,
            let user = components.user, !user.isEmpty,
            let password = components.password, components.fragment == nil
        else {
            throw ConnectionError.invalidURL
        }
        let port = components.port ?? 5432
        let database = String(components.path.dropFirst())
        guard (1...65535).contains(port), components.path.hasPrefix("/"), !database.isEmpty else {
            throw ConnectionError.invalidURL
        }
        let modes = (components.queryItems ?? []).filter { $0.name.lowercased() == "sslmode" }
        guard modes.count <= 1 else { throw ConnectionError.invalidURL }
        if let mode = modes.first, !["require", "verify-full"].contains(mode.value?.lowercased() ?? "") {
            throw ConnectionError.insecureTLS
        }
        let roots = (components.queryItems ?? []).filter { $0.name.lowercased() == "sslrootcert" }
        guard roots.count <= 1 else { throw ConnectionError.invalidURL }
        if let root = roots.first, root.value?.isEmpty != false { throw ConnectionError.invalidURL }
        self.host = host
        self.port = port
        self.username = user
        self.password = password
        self.database = database
        self.sslRootCertificate = roots.first?.value.map { ($0 as NSString).expandingTildeInPath }
    }

    enum ConnectionError: LocalizedError {
        case invalidURL, insecureTLS
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter a valid PostgreSQL URL with a host, username, password and database."
            case .insecureTLS: return "StreamVibes requires verified TLS. Use sslmode=verify-full or omit sslmode."
            }
        }
    }
}
