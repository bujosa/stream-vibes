import Foundation

enum StreamingPlatform: String, CaseIterable, Codable, Identifiable, Sendable {
    case appleTVPlus = "apple_tv_plus"
    case crunchyroll = "crunchyroll"
    case netflix = "netflix"
    case max = "max"
    case disneyPlus = "disney_plus"
    case hulu = "hulu"
    case primeVideo = "prime_video"
    case peacock = "peacock"
    case paramountPlus = "paramount_plus"
    case youtube = "youtube"
    case theatrical = "theatrical"
    case other = "other"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleTVPlus: return "Apple TV+"
        case .crunchyroll: return "Crunchyroll"
        case .netflix: return "Netflix"
        case .max: return "Max"
        case .disneyPlus: return "Disney+"
        case .hulu: return "Hulu"
        case .primeVideo: return "Prime Video"
        case .peacock: return "Peacock"
        case .paramountPlus: return "Paramount+"
        case .youtube: return "YouTube"
        case .theatrical: return "Theaters"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .appleTVPlus: return "apple.logo"
        case .crunchyroll: return "sparkles.tv"
        case .netflix: return "play.rectangle.fill"
        case .max: return "popcorn.fill"
        case .disneyPlus: return "sparkles"
        case .hulu: return "tv.fill"
        case .primeVideo: return "shippingbox.fill"
        case .peacock: return "dot.radiowaves.left.and.right"
        case .paramountPlus: return "mountain.2.fill"
        case .youtube: return "play.tv.fill"
        case .theatrical: return "ticket.fill"
        case .other: return "rectangle.stack.fill"
        }
    }
}

struct PlatformAvailability: Identifiable, Hashable, Codable, Sendable {
    var id: String {
        "\(platform.rawValue)-\(availability ?? "streaming")-\(url ?? "")"
    }
    var platform: StreamingPlatform
    var availability: String?
    var url: String?
}

extension StreamingPlatform {
    static func detect(name rawName: String?, url rawURL: String? = nil, availability rawAvailability: String? = nil) -> StreamingPlatform {
        let normalizedName = (rawName ?? "")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let normalizedURL = (rawURL ?? "").lowercased()
        let normalizedAvailability = (rawAvailability ?? "")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let combined = "\(normalizedName) \(normalizedURL) \(normalizedAvailability)"

        if combined.contains("tv.apple.com")
            || combined.contains("apple tv+")
            || combined.contains("apple tv plus")
            || (combined.contains("apple") && combined.contains("tv")) {
            return .appleTVPlus
        }
        if combined.contains("crunchy") { return .crunchyroll }
        if combined.contains("netflix") { return .netflix }
        if combined == "max" || combined.contains("hbo") || combined.contains("max.com") { return .max }
        if combined.contains("disney") { return .disneyPlus }
        if combined.contains("hulu") { return .hulu }
        if combined.contains("prime") || combined.contains("amazon") { return .primeVideo }
        if combined.contains("peacock") { return .peacock }
        if combined.contains("paramount") { return .paramountPlus }
        if combined.contains("youtube") || combined.contains("youtu.be") { return .youtube }
        if combined.contains("theater") || combined.contains("cinema") || combined.contains("theatrical") {
            return .theatrical
        }
        return .other
    }
}

extension PlatformAvailability {
    var normalized: PlatformAvailability {
        PlatformAvailability(
            platform: StreamingPlatform.detect(name: platform.label, url: url, availability: availability),
            availability: availability?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            url: url?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private var dedupeKey: String {
        let normalizedAvailability = availability?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "streaming"
        if let url = url?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !url.isEmpty {
            return "\(platform.rawValue)|\(normalizedAvailability)|\(url)"
        }
        return "\(platform.rawValue)|\(normalizedAvailability)"
    }

    static func merged(preferred: [PlatformAvailability], fallback: [PlatformAvailability]) -> [PlatformAvailability] {
        let normalizedPreferred = unique(preferred.map(\.normalized))
        let normalizedFallback = unique(fallback.map(\.normalized))

        var merged: [PlatformAvailability] = []

        func appendSpecific(from source: [PlatformAvailability]) {
            for entry in source where entry.platform != .other {
                let sameURL = entry.url?.lowercased()
                let conflictsWithSpecific = merged.contains {
                    if $0.platform == entry.platform { return true }
                    if let sameURL, let existingURL = $0.url?.lowercased(), !sameURL.isEmpty {
                        return existingURL == sameURL
                    }
                    return false
                }
                if !conflictsWithSpecific {
                    merged.append(entry)
                }
            }
        }

        appendSpecific(from: normalizedPreferred)
        appendSpecific(from: normalizedFallback)

        if merged.isEmpty {
            for entry in normalizedPreferred + normalizedFallback where entry.platform == .other {
                if !merged.contains(where: { $0.dedupeKey == entry.dedupeKey }) {
                    merged.append(entry)
                }
            }
        }

        return merged
    }

    private static func unique(_ platforms: [PlatformAvailability]) -> [PlatformAvailability] {
        var seen: Set<String> = []
        var uniquePlatforms: [PlatformAvailability] = []
        for platform in platforms {
            if seen.insert(platform.dedupeKey).inserted {
                uniquePlatforms.append(platform)
            }
        }
        return uniquePlatforms
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct AppUser: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
}

struct WatchList: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var description: String?
    var imageURL: String?
    var bannerImageURL: String?
    var isActive: Bool
    let createdAt: Date
    var updatedAt: Date
    var createdBy: UUID?
    var createdByName: String?
    var totalItems: Int = 0
    var watchedItems: Int = 0

    var progress: Double {
        guard totalItems > 0 else { return 0 }
        return Double(watchedItems) / Double(totalItems)
    }
}

enum WatchStatus: String {
    case pending = "Pending"
    case inProgress = "In Progress"
    case watched = "Watched"
}

struct WatchItem: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var imageURL: String?
    var category: String
    var genre: String?
    var trailerURL: String?
    var year: Int?
    var overview: String?
    let createdAt: Date
    var isWatched: Bool = false
    var watchedAt: Date?
    var avgRating: Double = 0
    var ratingCount: Int = 0
    var addedBy: UUID?
    var addedByName: String?
    var totalSeasons: Int = 0
    var watchedSeasons: Int = 0
    var watchedEpisodeCount: Int = 0
    var imdbRating: Double?
    var rottenTomatoesScore: Int?
    var availablePlatforms: [PlatformAvailability] = []

    var seasonProgress: Double {
        guard totalSeasons > 0 else { return 0 }
        return Double(watchedSeasons) / Double(totalSeasons)
    }

    var hasSeasons: Bool { totalSeasons > 0 }

    var watchStatus: WatchStatus {
        if hasSeasons {
            if watchedSeasons >= totalSeasons { return .watched }
            if watchedSeasons > 0 || watchedEpisodeCount > 0 { return .inProgress }
            return .pending
        }
        return isWatched ? .watched : .pending
    }
}

struct ListEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let listId: UUID
    let itemId: UUID
    var position: Int
    let addedAt: Date
    var item: WatchItem?
    var seasonId: UUID?
    var season: ItemSeason?
}

struct ItemSeason: Identifiable, Hashable, Sendable {
    let id: UUID
    let itemId: UUID
    var seasonNumber: Int
    var name: String?
    var year: Int?
    var episodeCount: Int?
    var imageURL: String?
    var trailerURL: String?
    var overview: String?
    var isWatched: Bool = false
    var watchedAt: Date? = nil
    var ranking: Int? = nil
    var avgRating: Double = 0
    var ratingCount: Int = 0
}

struct ItemEpisode: Identifiable, Hashable, Sendable {
    let id: UUID
    let seasonId: UUID
    let itemId: UUID
    var episodeNumber: Int
    var title: String?
    var overview: String?
    var imageURL: String?
    var airDate: String?
    var runtimeMinutes: Int?
    var isWatched: Bool = false
    var watchedAt: Date? = nil
    var isSelected: Bool = true
    var isFavorite: Bool = false
    var avgRating: Double = 0
    var ratingCount: Int = 0
}

struct EpisodeRating: Identifiable, Hashable, Sendable {
    let id: UUID
    let episodeId: UUID
    let userId: UUID
    var score: Double
    var comment: String?
    let createdAt: Date
    var updatedAt: Date
    var userName: String?
    var likeCount: Int = 0
    var isLikedByCurrentUser: Bool = false
    var replies: [EpisodeRatingReply] = []
}

struct EpisodeRatingReply: Identifiable, Hashable, Sendable {
    let id: UUID
    let ratingId: UUID
    let userId: UUID
    var message: String
    let createdAt: Date
    var userName: String?
}

struct EpisodeComment: Identifiable, Hashable, Sendable {
    let id: UUID
    let episodeId: UUID
    let userId: UUID
    var message: String
    let createdAt: Date
    var updatedAt: Date
    var userName: String?
    var likeCount: Int = 0
    var isLikedByCurrentUser: Bool = false
    var reactions: [EpisodeCommentReaction] = []
    var replies: [EpisodeCommentReply] = []
}

struct EpisodeCommentReaction: Identifiable, Hashable, Sendable {
    var id: String { emoji }
    let emoji: String
    var count: Int
    var isMine: Bool
}

struct SeasonReview: Identifiable, Hashable, Sendable {
    let id: UUID
    let seasonId: UUID
    let userId: UUID
    var score: Double
    var comment: String?
    let createdAt: Date
    var updatedAt: Date
    var userName: String?
}

struct EpisodeCommentReply: Identifiable, Hashable, Sendable {
    let id: UUID
    let commentId: UUID
    let userId: UUID
    var message: String
    let createdAt: Date
    var userName: String?
}

struct Rating: Identifiable, Hashable, Sendable {
    let id: UUID
    let itemId: UUID
    let userId: UUID
    var score: Double
    var comment: String?
    let createdAt: Date
    var updatedAt: Date
    var userName: String?
    var likeCount: Int = 0
    var isLikedByCurrentUser: Bool = false
    var replies: [RatingReply] = []
}

struct RatingReply: Identifiable, Hashable, Sendable {
    let id: UUID
    let ratingId: UUID
    let userId: UUID
    var message: String
    let createdAt: Date
    var userName: String?
}

struct ItemComment: Identifiable, Hashable, Sendable {
    let id: UUID
    let itemId: UUID
    let userId: UUID
    var message: String
    let createdAt: Date
    var updatedAt: Date
    var userName: String?
    var likeCount: Int = 0
    var isLikedByCurrentUser: Bool = false
    var reactions: [ItemCommentReaction] = []
    var replies: [ItemCommentReply] = []
}

struct ItemCommentReaction: Identifiable, Hashable, Sendable {
    var id: String { emoji }
    let emoji: String
    var count: Int
    var isMine: Bool
}

struct ItemCommentReply: Identifiable, Hashable, Sendable {
    let id: UUID
    let commentId: UUID
    let userId: UUID
    var message: String
    let createdAt: Date
    var userName: String?
}

enum ItemCategory: String, CaseIterable, Identifiable {
    case anime, movie, series, novela
    var id: String { rawValue }
    var label: String {
        switch self {
        case .anime: return "Anime"
        case .movie: return "Movie"
        case .series: return "Series"
        case .novela: return "Telenovela"
        }
    }
    var icon: String {
        switch self {
        case .anime: return "sparkles.tv"
        case .movie: return "film"
        case .series: return "tv"
        case .novela: return "theatermasks.fill"
        }
    }
    /// Whether items of this category are organized into seasons/episodes.
    var hasSeasons: Bool {
        switch self {
        case .series, .anime, .novela: return true
        case .movie: return false
        }
    }
    /// Convenience for checking the seasoned-ness of a raw category string from the database.
    static func categoryHasSeasons(_ rawCategory: String) -> Bool {
        ItemCategory(rawValue: rawCategory)?.hasSeasons ?? false
    }
}

enum AppTab: Hashable {
    case home, catalog, lists
    case category(ItemCategory)
}
