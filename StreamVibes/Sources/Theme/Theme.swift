import SwiftUI

enum SVTheme {
    // MARK: - Colors (Netflix-inspired dark theme)
    static let background = Color(red: 0.078, green: 0.078, blue: 0.078)       // #141414
    static let surface = Color(red: 0.094, green: 0.094, blue: 0.094)          // #181818
    static let surfaceLight = Color(red: 0.118, green: 0.118, blue: 0.118)     // #1E1E1E
    static let card = Color(red: 0.141, green: 0.141, blue: 0.141)            // #242424
    static let cardHover = Color(red: 0.176, green: 0.176, blue: 0.176)       // #2D2D2D
    static let accent = Color(red: 0.878, green: 0.475, blue: 0.384)          // #E07962 (warm coral)
    static let accentLight = Color(red: 0.929, green: 0.580, blue: 0.498)     // #ED947F
    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0.702, green: 0.702, blue: 0.702)   // #B3B3B3
    static let textMuted = Color(red: 0.502, green: 0.502, blue: 0.502)       // #808080
    static let border = Color(red: 0.200, green: 0.200, blue: 0.200)          // #333333
    static let success = Color(red: 0.180, green: 0.800, blue: 0.443)         // #2ECC71
    static let star = Color(red: 1.0, green: 0.843, blue: 0.0)               // #FFD700

    // Category colors
    static let anime = Color(red: 0.608, green: 0.349, blue: 0.714)           // #9B59B6
    static let movie = Color(red: 0.204, green: 0.596, blue: 0.859)           // #3498DB
    static let series = Color(red: 0.180, green: 0.800, blue: 0.443)          // #2ECC71
    static let novela = Color(red: 0.906, green: 0.298, blue: 0.549)          // #E74C8C

    // MARK: - Sizes
    static let cornerRadius: CGFloat = 8
    static let cardCornerRadius: CGFloat = 10
    static let spacing: CGFloat = 12
    static let sidebarWidth: CGFloat = 240

    static func categoryColor(_ category: String) -> Color {
        switch category {
        case "anime": return anime
        case "movie": return movie
        case "series": return series
        case "novela": return novela
        default: return textMuted
        }
    }

    static func categoryIcon(_ category: String) -> String {
        switch category {
        case "anime": return "sparkles.tv"
        case "movie": return "film"
        case "series": return "tv"
        case "novela": return "theatermasks.fill"
        default: return "questionmark"
        }
    }

    static func categoryLabel(_ category: String) -> String {
        switch category {
        case "anime": return "Anime"
        case "movie": return "Movie"
        case "series": return "Series"
        case "novela": return "Telenovela"
        default: return category.capitalized
        }
    }

    static func platformColor(_ platform: StreamingPlatform) -> Color {
        switch platform {
        case .appleTVPlus: return .white.opacity(0.9)
        case .crunchyroll: return Color.orange
        case .netflix: return Color.red
        case .max: return Color.blue.opacity(0.85)
        case .disneyPlus: return Color.indigo
        case .hulu: return Color.green
        case .primeVideo: return Color.cyan
        case .peacock: return Color.teal
        case .paramountPlus: return Color.blue
        case .youtube: return Color.red.opacity(0.9)
        case .theatrical: return Color.yellow
        case .other: return accent
        }
    }
}
