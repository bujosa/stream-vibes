import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case none
    case claude = "claude"
    case ollama = "ollama"
    case anthropicAPI = "anthropic_api"
    case openaiAPI = "openai_api"
    case geminiAPI = "gemini_api"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .claude: return "Claude CLI"
        case .ollama: return "Ollama"
        case .anthropicAPI: return "Anthropic API"
        case .openaiAPI: return "OpenAI API"
        case .geminiAPI: return "Gemini API"
        }
    }

    var icon: String {
        switch self {
        case .none: return "xmark.circle"
        case .claude: return "sparkle"
        case .ollama: return "cpu"
        case .anthropicAPI: return "brain"
        case .openaiAPI: return "bubble.left.fill"
        case .geminiAPI: return "diamond.fill"
        }
    }

    var isCLI: Bool {
        switch self {
        case .claude, .ollama: return true
        default: return false
        }
    }

    var isAPI: Bool {
        switch self {
        case .anthropicAPI, .openaiAPI, .geminiAPI: return true
        default: return false
        }
    }

    var modelOptions: [AIModelOption] { AIModelCatalog.options(for: rawValue) }

    var defaultModel: String {
        modelOptions.first?.id ?? (self == .ollama ? "llama3.2" : "")
    }

    var defaultPath: String {
        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            return path
        }
        return candidatePaths.first ?? ""
    }

    var knownPaths: [String] {
        candidatePaths
    }

    func isKnownPath(_ path: String) -> Bool {
        candidatePaths.contains(path)
    }

    private var candidatePaths: [String] {
        switch self {
        case .none, .anthropicAPI, .openaiAPI, .geminiAPI:
            return []
        case .claude:
            return [
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude"
            ]
        case .ollama:
            return [
                "/opt/homebrew/bin/ollama",
                "/usr/local/bin/ollama"
            ]
        }
    }
}
