import Foundation

struct AIModelOption: Identifiable {
    let id: String
    let name: String
    let detail: String
}

/// Curated text models verified against official provider docs on 2026-10-16.
/// Account availability varies; custom IDs and CLI defaults remain available.
enum AIModelCatalog {
    static func options(for provider: String) -> [AIModelOption] {
        switch provider {
        case "openai_api": return [
            .init(id: "gpt-6-luna", name: "GPT-6 Luna", detail: "Fast and cost-effective"),
            .init(id: "gpt-6.1-sol", name: "GPT-6.1 Sol", detail: "Balanced speed and capability"),
            .init(id: "gpt-6-astra", name: "GPT-6 Astra", detail: "Advanced reasoning"),
        ]
        case "anthropic_api": return [
            .init(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", detail: "Balanced speed and capability"),
            .init(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", detail: "Fast everyday tasks"),
            .init(id: "claude-opus-5-5", name: "Claude Opus 5.5", detail: "Complex reasoning and coding"),
            .init(id: "claude-fable-5-1", name: "Claude Fable 5.1", detail: "Demanding reasoning · access may vary"),
        ]
        case "gemini_api": return [
            .init(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", detail: "Fast general-purpose assistance"),
            .init(id: "gemini-3.5-flash-lite", name: "Gemini 3.5 Flash-Lite", detail: "Lightweight everyday tasks"),
            .init(id: "gemini-4-argon", name: "Gemini 4 Argon", detail: "Advanced reasoning"),
        ]
        default: return []
        }
    }
}

enum AIModelPreferences {
    static func key(for provider: String) -> String { "aiModel.\(provider)" }

    /// Migrate the old shared setting only to the provider that owned it.
    static func value(for provider: String, defaults: UserDefaults = .standard) -> String {
        let key = key(for: provider)
        if let value = defaults.string(forKey: key) { return value }
        guard defaults.string(forKey: "aiProvider") == provider,
              let legacy = defaults.string(forKey: "aiModel") else { return "" }
        defaults.set(legacy, forKey: key)
        defaults.removeObject(forKey: "aiModel")
        return legacy
    }
}
