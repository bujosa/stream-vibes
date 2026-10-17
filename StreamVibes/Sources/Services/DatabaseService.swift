import Foundation
import PostgresNIO
import NIOSSL

@Observable
@MainActor
final class DatabaseService {
    var catalogItems: [WatchItem] = []
    var lists: [WatchList] = []
    var currentEntries: [ListEntry] = []
    var users: [AppUser] = []
    var isConnected = false
    var isLoading = false
    var errorMessage: String?

    private var client: PostgresClient?
    private var clientTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    // MARK: - Connection

    func connect(urlString: String) async throws {
        let parsed = try Self.parseConnectionString(urlString)

        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .fullVerification
        tlsConfig.minimumTLSVersion = .tlsv12
        if let root = parsed.sslRootCertificate { tlsConfig.trustRoots = .file(root) }

        let config = PostgresClient.Configuration(
            host: parsed.host,
            port: parsed.port,
            username: parsed.username,
            password: parsed.password,
            database: parsed.database,
            tls: .require(tlsConfig)
        )

        disconnect()
        let newClient = PostgresClient(configuration: config)
        self.client = newClient

        clientTask = Task {
            await newClient.run()
        }

        do {
            // Fail a bad URL, unreachable host or untrusted certificate before migrations.
            // Closing the client also releases any connection-pool request on timeout.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    let rows = try await newClient.query("SELECT 1")
                    for try await _ in rows {}
                }
                group.addTask { @MainActor in
                    try await Task.sleep(for: .seconds(20))
                    self.disconnect()
                    throw DBError.connectionTimedOut
                }
                defer { group.cancelAll() }
                try await group.next()
            }
            try await runMigrations()
            try await fetchUsers()
            try await fetchCatalog()
            try await fetchLists()
            isConnected = true
            errorMessage = nil
            startAutoRefresh()
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        clientTask?.cancel()
        clientTask = nil
        client = nil
        isConnected = false
        catalogItems = []
        lists = []
        currentEntries = []
        users = []
    }

    // MARK: - Versioned Migrations

    private struct Migration {
        let version: Int
        let description: String
        let statements: [String]
    }

    private static let allMigrations: [Migration] = [
        Migration(version: 1, description: "Initial schema", statements: [
            """
            CREATE TABLE IF NOT EXISTS users (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                name VARCHAR(100) NOT NULL,
                created_at TIMESTAMPTZ DEFAULT NOW()
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS watch_lists (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                name VARCHAR(200) NOT NULL,
                description TEXT,
                is_active BOOLEAN DEFAULT TRUE,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                updated_at TIMESTAMPTZ DEFAULT NOW()
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS watch_items (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                title VARCHAR(300) NOT NULL,
                image_url TEXT,
                category VARCHAR(50) NOT NULL CHECK (category IN ('anime', 'movie', 'series', 'novela')),
                year INTEGER,
                overview TEXT,
                created_at TIMESTAMPTZ DEFAULT NOW()
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS list_entries (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                list_id UUID NOT NULL REFERENCES watch_lists(id) ON DELETE CASCADE,
                item_id UUID NOT NULL REFERENCES watch_items(id) ON DELETE CASCADE,
                position INTEGER DEFAULT 0,
                added_at TIMESTAMPTZ DEFAULT NOW(),
                UNIQUE(list_id, item_id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS ratings (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                item_id UUID NOT NULL REFERENCES watch_items(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id),
                score DECIMAL(3,1) NOT NULL CHECK (score >= 0 AND score <= 10),
                comment TEXT,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                updated_at TIMESTAMPTZ DEFAULT NOW(),
                UNIQUE(item_id, user_id)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_list_entries_list_id ON list_entries(list_id)",
            "CREATE INDEX IF NOT EXISTS idx_list_entries_item_id ON list_entries(item_id)",
            "CREATE INDEX IF NOT EXISTS idx_ratings_item_id ON ratings(item_id)",
            "CREATE INDEX IF NOT EXISTS idx_ratings_user_id ON ratings(user_id)",
        ]),
        Migration(version: 2, description: "Watched status on items", statements: [
            "ALTER TABLE watch_items ADD COLUMN IF NOT EXISTS is_watched BOOLEAN DEFAULT FALSE",
            "ALTER TABLE watch_items ADD COLUMN IF NOT EXISTS watched_at TIMESTAMPTZ",
        ]),
        Migration(version: 3, description: "Added-by tracking and trigram search", statements: [
            "CREATE EXTENSION IF NOT EXISTS pg_trgm",
            "ALTER TABLE watch_items ADD COLUMN IF NOT EXISTS added_by UUID REFERENCES users(id)",
            "CREATE INDEX IF NOT EXISTS idx_watch_items_title_trgm ON watch_items USING GIN (title gin_trgm_ops)",
        ]),
        Migration(version: 4, description: "Add genre column", statements: [
            "ALTER TABLE watch_items ADD COLUMN IF NOT EXISTS genre VARCHAR(100)",
        ]),
        Migration(version: 5, description: "Review likes and replies", statements: [
            """
            CREATE TABLE IF NOT EXISTS rating_likes (
                rating_id UUID NOT NULL REFERENCES ratings(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                PRIMARY KEY (rating_id, user_id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS rating_replies (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                rating_id UUID NOT NULL REFERENCES ratings(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                message TEXT NOT NULL,
                created_at TIMESTAMPTZ DEFAULT NOW()
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_rating_likes_rating_id ON rating_likes(rating_id)",
            "CREATE INDEX IF NOT EXISTS idx_rating_replies_rating_id ON rating_replies(rating_id)",
            "CREATE INDEX IF NOT EXISTS idx_rating_replies_user_id ON rating_replies(user_id)",
        ]),
        Migration(version: 6, description: "Add trailer URL column", statements: [
            "ALTER TABLE watch_items ADD COLUMN IF NOT EXISTS trailer_url TEXT",
        ]),
        Migration(version: 7, description: "List cover image and creator metadata", statements: [
            "ALTER TABLE watch_lists ADD COLUMN IF NOT EXISTS image_url TEXT",
            "ALTER TABLE watch_lists ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id)",
            "CREATE INDEX IF NOT EXISTS idx_watch_lists_created_by ON watch_lists(created_by)",
        ]),
        Migration(version: 8, description: "Standalone item comments", statements: [
            """
            CREATE TABLE IF NOT EXISTS item_comments (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                item_id UUID NOT NULL REFERENCES watch_items(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                message TEXT NOT NULL,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                updated_at TIMESTAMPTZ DEFAULT NOW()
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_item_comments_item_id ON item_comments(item_id)",
            "CREATE INDEX IF NOT EXISTS idx_item_comments_user_id ON item_comments(user_id)",
            """
            INSERT INTO item_comments (item_id, user_id, message, created_at, updated_at)
            SELECT r.item_id, r.user_id, r.comment, r.created_at, r.updated_at
            FROM ratings r
            WHERE r.comment IS NOT NULL AND btrim(r.comment) <> ''
            """,
        ]),
        Migration(version: 9, description: "Likes and emoji reactions for item comments", statements: [
            """
            CREATE TABLE IF NOT EXISTS item_comment_likes (
                comment_id UUID NOT NULL REFERENCES item_comments(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                PRIMARY KEY (comment_id, user_id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS item_comment_reactions (
                comment_id UUID NOT NULL REFERENCES item_comments(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                emoji VARCHAR(16) NOT NULL,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                PRIMARY KEY (comment_id, user_id, emoji)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_item_comment_likes_comment_id ON item_comment_likes(comment_id)",
            "CREATE INDEX IF NOT EXISTS idx_item_comment_reactions_comment_id ON item_comment_reactions(comment_id)",
        ]),
        Migration(version: 10, description: "Replies for item comments", statements: [
            """
            CREATE TABLE IF NOT EXISTS item_comment_replies (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                comment_id UUID NOT NULL REFERENCES item_comments(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                message TEXT NOT NULL,
                created_at TIMESTAMPTZ DEFAULT NOW()
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_item_comment_replies_comment_id ON item_comment_replies(comment_id)",
            "CREATE INDEX IF NOT EXISTS idx_item_comment_replies_user_id ON item_comment_replies(user_id)",
        ]),
        Migration(version: 11, description: "Item seasons and season tracking on list entries", statements: [
            """
            CREATE TABLE IF NOT EXISTS item_seasons (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                item_id UUID NOT NULL REFERENCES watch_items(id) ON DELETE CASCADE,
                season_number INTEGER NOT NULL,
                name VARCHAR(200),
                year INTEGER,
                episode_count INTEGER,
                image_url TEXT,
                overview TEXT,
                UNIQUE(item_id, season_number)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_item_seasons_item_id ON item_seasons(item_id)",
            "ALTER TABLE list_entries ADD COLUMN IF NOT EXISTS season_id UUID REFERENCES item_seasons(id)",
            "ALTER TABLE list_entries DROP CONSTRAINT IF EXISTS list_entries_list_id_item_id_key",
            """
            CREATE UNIQUE INDEX IF NOT EXISTS uq_list_entries_list_item_season
            ON list_entries (list_id, item_id, COALESCE(season_id, '00000000-0000-0000-0000-000000000000'::UUID))
            """,
        ]),
        Migration(version: 12, description: "Add trailer URL to item seasons", statements: [
            "ALTER TABLE item_seasons ADD COLUMN IF NOT EXISTS trailer_url TEXT",
        ]),
        Migration(version: 13, description: "Recently accessed items tracking", statements: [
            """
            CREATE TABLE IF NOT EXISTS recently_accessed (
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                item_id UUID NOT NULL REFERENCES watch_items(id) ON DELETE CASCADE,
                accessed_at TIMESTAMPTZ DEFAULT NOW(),
                PRIMARY KEY (user_id, item_id)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_recently_accessed_user_id ON recently_accessed(user_id)",
            "CREATE INDEX IF NOT EXISTS idx_recently_accessed_accessed_at ON recently_accessed(accessed_at DESC)",
        ]),
        Migration(version: 14, description: "Season watch status", statements: [
            "ALTER TABLE item_seasons ADD COLUMN IF NOT EXISTS is_watched BOOLEAN DEFAULT FALSE",
            "ALTER TABLE item_seasons ADD COLUMN IF NOT EXISTS watched_at TIMESTAMPTZ",
        ]),
        Migration(version: 15, description: "List banner image", statements: [
            "ALTER TABLE watch_lists ADD COLUMN IF NOT EXISTS banner_image_url TEXT",
        ]),
        Migration(version: 16, description: "Season ranking", statements: [
            "ALTER TABLE item_seasons ADD COLUMN IF NOT EXISTS ranking INTEGER",
        ]),
        Migration(version: 17, description: "Episodes table", statements: [
            """
            CREATE TABLE IF NOT EXISTS item_episodes (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                season_id UUID NOT NULL REFERENCES item_seasons(id) ON DELETE CASCADE,
                item_id UUID NOT NULL REFERENCES watch_items(id) ON DELETE CASCADE,
                episode_number INTEGER NOT NULL,
                title VARCHAR(300),
                overview TEXT,
                image_url TEXT,
                air_date VARCHAR(20),
                runtime_minutes INTEGER,
                is_watched BOOLEAN DEFAULT FALSE,
                watched_at TIMESTAMPTZ,
                is_selected BOOLEAN DEFAULT TRUE,
                UNIQUE(season_id, episode_number)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_item_episodes_season_id ON item_episodes(season_id)",
            "CREATE INDEX IF NOT EXISTS idx_item_episodes_item_id ON item_episodes(item_id)",
        ]),
        Migration(version: 18, description: "Episode ratings, comments, favorites", statements: [
            "ALTER TABLE item_episodes ADD COLUMN IF NOT EXISTS is_favorite BOOLEAN DEFAULT FALSE",
            """
            CREATE TABLE IF NOT EXISTS episode_ratings (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                episode_id UUID NOT NULL REFERENCES item_episodes(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id),
                score DECIMAL(3,1) NOT NULL CHECK (score >= 0 AND score <= 10),
                comment TEXT,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                updated_at TIMESTAMPTZ DEFAULT NOW(),
                UNIQUE(episode_id, user_id)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_episode_ratings_episode_id ON episode_ratings(episode_id)",
            """
            CREATE TABLE IF NOT EXISTS episode_rating_likes (
                rating_id UUID NOT NULL REFERENCES episode_ratings(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                PRIMARY KEY (rating_id, user_id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS episode_rating_replies (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                rating_id UUID NOT NULL REFERENCES episode_ratings(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                message TEXT NOT NULL,
                created_at TIMESTAMPTZ DEFAULT NOW()
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_episode_rating_replies_rating_id ON episode_rating_replies(rating_id)",
            """
            CREATE TABLE IF NOT EXISTS episode_comments (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                episode_id UUID NOT NULL REFERENCES item_episodes(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                message TEXT NOT NULL,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                updated_at TIMESTAMPTZ DEFAULT NOW()
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_episode_comments_episode_id ON episode_comments(episode_id)",
            """
            CREATE TABLE IF NOT EXISTS episode_comment_likes (
                comment_id UUID NOT NULL REFERENCES episode_comments(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                PRIMARY KEY (comment_id, user_id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS episode_comment_reactions (
                comment_id UUID NOT NULL REFERENCES episode_comments(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                emoji VARCHAR(16) NOT NULL,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                PRIMARY KEY (comment_id, user_id, emoji)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS episode_comment_replies (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                comment_id UUID NOT NULL REFERENCES episode_comments(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                message TEXT NOT NULL,
                created_at TIMESTAMPTZ DEFAULT NOW()
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_episode_comment_replies_comment_id ON episode_comment_replies(comment_id)",
        ]),
        Migration(version: 19, description: "External ratings and platform availability", statements: [
            "ALTER TABLE watch_items ADD COLUMN IF NOT EXISTS imdb_rating DOUBLE PRECISION",
            "ALTER TABLE watch_items ADD COLUMN IF NOT EXISTS rotten_tomatoes_score INTEGER",
            "ALTER TABLE watch_items ADD COLUMN IF NOT EXISTS available_platforms TEXT",
        ]),
        Migration(version: 20, description: "Season reviews", statements: [
            """
            CREATE TABLE IF NOT EXISTS season_reviews (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                season_id UUID NOT NULL REFERENCES item_seasons(id) ON DELETE CASCADE,
                user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                score DECIMAL(3,1) NOT NULL CHECK (score >= 0 AND score <= 10),
                comment TEXT,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                updated_at TIMESTAMPTZ DEFAULT NOW(),
                UNIQUE(season_id, user_id)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_season_reviews_season_id ON season_reviews(season_id)",
        ]),
        Migration(version: 21, description: "Allow novela category", statements: [
            "ALTER TABLE watch_items DROP CONSTRAINT IF EXISTS watch_items_category_check",
            "ALTER TABLE watch_items ADD CONSTRAINT watch_items_category_check CHECK (category IN ('anime', 'movie', 'series', 'novela'))",
        ]),
    ]

    private func runMigrations() async throws {
        guard let client else { return }

        try await client.query("""
            CREATE TABLE IF NOT EXISTS _migrations (
                version INTEGER PRIMARY KEY,
                description TEXT NOT NULL,
                applied_at TIMESTAMPTZ DEFAULT NOW()
            )
            """)

        let rows = try await client.query("SELECT version FROM _migrations ORDER BY version")
        var applied: Set<Int> = []
        for try await (version,) in rows.decode((Int,).self) {
            applied.insert(version)
        }

        let pending = Self.allMigrations.filter { !applied.contains($0.version) }
            .sorted { $0.version < $1.version }

        for migration in pending {
            for sql in migration.statements {
                try await client.query(.init(stringLiteral: sql))
            }
            try await client.query(
                "INSERT INTO _migrations (version, description) VALUES (\(migration.version), \(migration.description))"
            )
        }
    }

    // MARK: - Users

    func fetchUsers() async throws {
        guard let client else { return }
        let rows = try await client.query("SELECT id, name, created_at FROM users ORDER BY created_at")
        var result: [AppUser] = []
        for try await (id, name, createdAt) in rows.decode((UUID, String, Date).self) {
            result.append(AppUser(id: id, name: name, createdAt: createdAt))
        }
        self.users = result
    }

    func createUser(name: String) async throws -> AppUser {
        guard let client else { throw DBError.notConnected }
        let rows = try await client.query(
            "INSERT INTO users (name) VALUES (\(name)) RETURNING id, name, created_at"
        )
        for try await (id, name, createdAt) in rows.decode((UUID, String, Date).self) {
            let user = AppUser(id: id, name: name, createdAt: createdAt)
            try await fetchUsers()
            return user
        }
        throw DBError.unexpectedResult
    }

    // MARK: - Catalog (all items)

    private func encodePlatforms(_ platforms: [PlatformAvailability]) -> String? {
        guard !platforms.isEmpty,
              let data = try? JSONEncoder().encode(platforms),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private func decodePlatforms(_ raw: String?) -> [PlatformAvailability] {
        guard let raw,
              let data = raw.data(using: .utf8),
              let platforms = try? JSONDecoder().decode([PlatformAvailability].self, from: data) else {
            return []
        }
        return platforms
    }

    func fetchCatalog() async throws {
        guard let client else { return }
        let rows = try await client.query("""
            SELECT wi.id, wi.title, wi.image_url, wi.category, wi.genre, wi.trailer_url, wi.year, wi.overview,
                   wi.is_watched, wi.watched_at, wi.created_at,
                   COALESCE(AVG(r.score), 0)::DOUBLE PRECISION as avg_rating,
                   COUNT(r.id)::INTEGER as rating_count,
                   wi.added_by, u2.name as added_by_name,
                   (SELECT COUNT(*)::INTEGER FROM item_seasons s WHERE s.item_id = wi.id) as total_seasons,
                   (SELECT COUNT(*)::INTEGER FROM item_seasons s WHERE s.item_id = wi.id AND s.is_watched = TRUE) as watched_seasons,
                   (SELECT COUNT(*)::INTEGER FROM item_episodes e JOIN item_seasons s ON s.id = e.season_id WHERE s.item_id = wi.id AND e.is_watched = TRUE AND e.is_selected = TRUE) as watched_episode_count,
                   wi.imdb_rating, wi.rotten_tomatoes_score, wi.available_platforms
            FROM watch_items wi
            LEFT JOIN ratings r ON r.item_id = wi.id
            LEFT JOIN users u2 ON u2.id = wi.added_by
            GROUP BY wi.id, u2.name
            ORDER BY wi.created_at DESC
            """)
        var result: [WatchItem] = []
        for try await (id, title, imgUrl, cat, genre, trailerUrl, year, overview, watched, watchedAt, created, avgRating, ratingCount, addedBy, addedByName, totalSeasons, watchedSeasons, watchedEpisodeCount, imdbRating, rottenTomatoesScore, availablePlatforms)
            in rows.decode((UUID, String, String?, String, String?, String?, Int?, String?, Bool, Date?, Date, Double, Int, UUID?, String?, Int, Int, Int, Double?, Int?, String?).self) {
            var item = WatchItem(id: id, title: title, imageURL: imgUrl, category: cat, genre: genre, trailerURL: trailerUrl, year: year, overview: overview, createdAt: created)
            item.isWatched = watched
            item.watchedAt = watchedAt
            item.avgRating = avgRating
            item.ratingCount = ratingCount
            item.addedBy = addedBy
            item.addedByName = addedByName
            item.totalSeasons = totalSeasons
            item.watchedSeasons = watchedSeasons
            item.watchedEpisodeCount = watchedEpisodeCount
            item.imdbRating = imdbRating
            item.rottenTomatoesScore = rottenTomatoesScore
            item.availablePlatforms = decodePlatforms(availablePlatforms)
            result.append(item)
        }
        self.catalogItems = result
    }

    func createItem(title: String, category: String, genre: String? = nil, trailerURL: String? = nil, imageURL: String?, year: Int?, overview: String?, imdbRating: Double? = nil, rottenTomatoesScore: Int? = nil, availablePlatforms: [PlatformAvailability] = [], isWatched: Bool = false, addedBy: UUID? = nil) async throws -> UUID {
        guard let client else { throw DBError.notConnected }
        let watchedAt: Date? = isWatched ? Date() : nil
        let platformsJSON = encodePlatforms(availablePlatforms)
        let rows = try await client.query(
            "INSERT INTO watch_items (title, category, genre, trailer_url, image_url, year, overview, imdb_rating, rotten_tomatoes_score, available_platforms, is_watched, watched_at, added_by) VALUES (\(title), \(category), \(genre), \(trailerURL), \(imageURL), \(year), \(overview), \(imdbRating), \(rottenTomatoesScore), \(platformsJSON), \(isWatched), \(watchedAt), \(addedBy)) RETURNING id"
        )
        for try await (id,) in rows.decode((UUID,).self) {
            try await fetchCatalog()
            return id
        }
        throw DBError.unexpectedResult
    }

    func toggleItemWatched(itemId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            UPDATE watch_items SET is_watched = NOT is_watched,
            watched_at = CASE WHEN NOT is_watched THEN NOW() ELSE NULL END
            WHERE id = \(itemId)
            """)
        try await fetchCatalog()
    }

    func resetDatabase() async throws {
        guard let client else { throw DBError.notConnected }
        // Drop all data tables in correct order (respecting foreign keys)
        try await client.query("DROP TABLE IF EXISTS recently_accessed CASCADE")
        try await client.query("DROP TABLE IF EXISTS item_comment_replies CASCADE")
        try await client.query("DROP TABLE IF EXISTS item_comment_reactions CASCADE")
        try await client.query("DROP TABLE IF EXISTS item_comment_likes CASCADE")
        try await client.query("DROP TABLE IF EXISTS item_comments CASCADE")
        try await client.query("DROP TABLE IF EXISTS episode_comment_replies CASCADE")
        try await client.query("DROP TABLE IF EXISTS episode_comment_reactions CASCADE")
        try await client.query("DROP TABLE IF EXISTS episode_comment_likes CASCADE")
        try await client.query("DROP TABLE IF EXISTS episode_comments CASCADE")
        try await client.query("DROP TABLE IF EXISTS season_reviews CASCADE")
        try await client.query("DROP TABLE IF EXISTS episode_rating_replies CASCADE")
        try await client.query("DROP TABLE IF EXISTS episode_rating_likes CASCADE")
        try await client.query("DROP TABLE IF EXISTS episode_ratings CASCADE")
        try await client.query("DROP TABLE IF EXISTS item_episodes CASCADE")
        try await client.query("DROP TABLE IF EXISTS item_seasons CASCADE")
        try await client.query("DROP TABLE IF EXISTS rating_replies CASCADE")
        try await client.query("DROP TABLE IF EXISTS rating_likes CASCADE")
        try await client.query("DROP TABLE IF EXISTS ratings CASCADE")
        try await client.query("DROP TABLE IF EXISTS list_entries CASCADE")
        try await client.query("DROP TABLE IF EXISTS watch_items CASCADE")
        try await client.query("DROP TABLE IF EXISTS watch_lists CASCADE")
        try await client.query("DROP TABLE IF EXISTS users CASCADE")
        try await client.query("DROP TABLE IF EXISTS _migrations CASCADE")
        // Re-run migrations to recreate empty tables
        try await runMigrations()
        // Refresh in-memory state
        catalogItems = []
        lists = []
        users = []
        currentEntries = []
    }

    func deleteItem(id: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("DELETE FROM watch_items WHERE id = \(id)")
        try await fetchCatalog()
    }

    func updateItem(id: UUID, title: String, category: String, genre: String? = nil, trailerURL: String? = nil, imageURL: String?, year: Int?, overview: String?, imdbRating: Double? = nil, rottenTomatoesScore: Int? = nil, availablePlatforms: [PlatformAvailability] = []) async throws {
        guard let client else { throw DBError.notConnected }
        let platformsJSON = encodePlatforms(availablePlatforms)
        try await client.query("""
            UPDATE watch_items SET title = \(title), category = \(category), genre = \(genre),
            trailer_url = \(trailerURL), image_url = \(imageURL), year = \(year), overview = \(overview),
            imdb_rating = \(imdbRating), rotten_tomatoes_score = \(rottenTomatoesScore), available_platforms = \(platformsJSON)
            WHERE id = \(id)
            """)
        try await fetchCatalog()
    }

    // MARK: - Item Seasons

    func fetchSeasons(for itemId: UUID) async throws -> [ItemSeason] {
        guard let client else { return [] }
        let rows = try await client.query("""
            SELECT s.id, s.item_id, s.season_number, s.name, s.year, s.episode_count, s.image_url, s.trailer_url, s.overview,
                   s.is_watched, s.watched_at, s.ranking,
                   COALESCE(AVG(sr.score)::DOUBLE PRECISION, 0) AS avg_rating,
                   COUNT(sr.id)::INTEGER AS rating_count
            FROM item_seasons s
            LEFT JOIN season_reviews sr ON sr.season_id = s.id
            WHERE s.item_id = \(itemId)
            GROUP BY s.id
            ORDER BY s.season_number ASC
            """)
        var result: [ItemSeason] = []
        for try await (id, itemId, num, name, year, epCount, imgUrl, trailerUrl, overview, isWatched, watchedAt, ranking, avgRating, ratingCount)
            in rows.decode((UUID, UUID, Int, String?, Int?, Int?, String?, String?, String?, Bool, Date?, Int?, Double, Int).self) {
            var season = ItemSeason(
                id: id, itemId: itemId, seasonNumber: num,
                name: name, year: year, episodeCount: epCount,
                imageURL: imgUrl, trailerURL: trailerUrl, overview: overview
            )
            season.isWatched = isWatched
            season.watchedAt = watchedAt
            season.ranking = ranking
            season.avgRating = avgRating
            season.ratingCount = ratingCount
            result.append(season)
        }
        return result
    }

    func toggleSeasonWatched(seasonId: UUID) async throws {
        guard let client else { throw DBError.notConnected }

        // Check current state to determine direction
        let checkRows = try await client.query("SELECT is_watched FROM item_seasons WHERE id = \(seasonId)")
        var currentlyWatched = false
        for try await (isW,) in checkRows.decode((Bool,).self) {
            currentlyWatched = isW
        }

        try await client.query("""
            UPDATE item_seasons SET is_watched = NOT is_watched,
            watched_at = CASE WHEN NOT is_watched THEN NOW() ELSE NULL END
            WHERE id = \(seasonId)
            """)

        // Cascade to episodes: mark all episodes to match the season state
        if !currentlyWatched {
            try await client.query("""
                UPDATE item_episodes SET is_watched = TRUE, watched_at = NOW()
                WHERE season_id = \(seasonId) AND is_watched = FALSE
                """)
        } else {
            try await client.query("""
                UPDATE item_episodes SET is_watched = FALSE, watched_at = NULL
                WHERE season_id = \(seasonId) AND is_watched = TRUE
                """)
        }

        // Auto-sync parent item's isWatched based on season completion
        try await client.query("""
            UPDATE watch_items SET
                is_watched = (SELECT COUNT(*) = COUNT(*) FILTER (WHERE is_watched = TRUE) FROM item_seasons WHERE item_id = watch_items.id),
                watched_at = CASE
                    WHEN (SELECT COUNT(*) = COUNT(*) FILTER (WHERE is_watched = TRUE) FROM item_seasons WHERE item_id = watch_items.id) THEN NOW()
                    ELSE NULL
                END
            WHERE id = (SELECT item_id FROM item_seasons WHERE id = \(seasonId))
            """)

        try await fetchCatalog()
    }

    /// Re-sync a season's is_watched from its episodes, then sync the parent item's status.
    func syncSeasonAndItemStatus(seasonId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        // Sync season: watched only if all selected episodes are watched
        try await client.query("""
            UPDATE item_seasons SET
                is_watched = (
                    SELECT COUNT(*) FILTER (WHERE is_selected) > 0
                       AND COUNT(*) FILTER (WHERE is_selected) = COUNT(*) FILTER (WHERE is_watched AND is_selected)
                    FROM item_episodes WHERE season_id = item_seasons.id
                ),
                watched_at = CASE
                    WHEN (SELECT COUNT(*) FILTER (WHERE is_selected) > 0
                             AND COUNT(*) FILTER (WHERE is_selected) = COUNT(*) FILTER (WHERE is_watched AND is_selected)
                          FROM item_episodes WHERE season_id = item_seasons.id) THEN COALESCE(item_seasons.watched_at, NOW())
                    ELSE NULL
                END
            WHERE id = \(seasonId)
            """)
        // Sync parent item
        try await client.query("""
            UPDATE watch_items SET
                is_watched = (SELECT COUNT(*) = COUNT(*) FILTER (WHERE is_watched = TRUE) FROM item_seasons WHERE item_id = watch_items.id),
                watched_at = CASE
                    WHEN (SELECT COUNT(*) = COUNT(*) FILTER (WHERE is_watched = TRUE) FROM item_seasons WHERE item_id = watch_items.id) THEN COALESCE(watch_items.watched_at, NOW())
                    ELSE NULL
                END
            WHERE id = (SELECT item_id FROM item_seasons WHERE id = \(seasonId))
            """)
    }

    func createSeason(itemId: UUID, seasonNumber: Int, name: String?, year: Int?, episodeCount: Int?, imageURL: String?, trailerURL: String?, overview: String?) async throws -> UUID {
        guard let client else { throw DBError.notConnected }
        let rows = try await client.query("""
            INSERT INTO item_seasons (item_id, season_number, name, year, episode_count, image_url, trailer_url, overview)
            VALUES (\(itemId), \(seasonNumber), \(name), \(year), \(episodeCount), \(imageURL), \(trailerURL), \(overview))
            ON CONFLICT (item_id, season_number) DO UPDATE SET
                name = EXCLUDED.name, year = EXCLUDED.year,
                episode_count = EXCLUDED.episode_count, image_url = EXCLUDED.image_url,
                trailer_url = EXCLUDED.trailer_url, overview = EXCLUDED.overview
            RETURNING id
            """)
        for try await (id,) in rows.decode((UUID,).self) {
            return id
        }
        throw DBError.unexpectedResult
    }

    func createSeasons(itemId: UUID, seasons: [AISeasonResult]) async throws {
        for season in seasons {
            _ = try await createSeason(
                itemId: itemId,
                seasonNumber: season.seasonNumber,
                name: season.name,
                year: season.year,
                episodeCount: season.episodeCount,
                imageURL: season.imageURL,
                trailerURL: season.trailerURL,
                overview: season.overview
            )
        }
    }

    func ensureSeasonScaffold(for item: WatchItem) async throws -> [ItemSeason] {
        guard ItemCategory.categoryHasSeasons(item.category) else { return [] }

        var seasons = try await fetchSeasons(for: item.id)
        if seasons.isEmpty {
            _ = try await createSeason(
                itemId: item.id,
                seasonNumber: 1,
                name: nil,
                year: item.year,
                episodeCount: nil,
                imageURL: item.imageURL,
                trailerURL: item.trailerURL,
                overview: item.overview
            )
            seasons = try await fetchSeasons(for: item.id)
        }

        return seasons.sorted { $0.seasonNumber < $1.seasonNumber }
    }

    // MARK: - Season Ranking

    func updateSeasonRanking(seasonId: UUID, ranking: Int?) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            UPDATE item_seasons SET ranking = \(ranking) WHERE id = \(seasonId)
            """)
    }

    func updateSeasonRankings(rankings: [(seasonId: UUID, ranking: Int)]) async throws {
        guard let client else { throw DBError.notConnected }
        for (seasonId, ranking) in rankings {
            try await client.query("""
                UPDATE item_seasons SET ranking = \(ranking) WHERE id = \(seasonId)
                """)
        }
    }

    // MARK: - Episodes

    func fetchEpisodes(for seasonId: UUID) async throws -> [ItemEpisode] {
        guard let client else { return [] }
        let rows = try await client.query("""
            SELECT e.id, e.season_id, e.item_id, e.episode_number, e.title, e.overview,
                   e.image_url, e.air_date, e.runtime_minutes, e.is_watched, e.watched_at, e.is_selected,
                   COALESCE(e.is_favorite, FALSE),
                   COALESCE(AVG(er.score)::DOUBLE PRECISION, 0) AS avg_rating,
                   COUNT(er.id)::INTEGER AS rating_count
            FROM item_episodes e
            LEFT JOIN episode_ratings er ON er.episode_id = e.id
            WHERE e.season_id = \(seasonId)
            GROUP BY e.id
            ORDER BY e.episode_number ASC
            """)
        var result: [ItemEpisode] = []
        for try await (id, seasonId, itemId, num, title, overview, imgUrl, airDate, runtime, isWatched, watchedAt, isSelected, isFavorite, avgRating, ratingCount)
            in rows.decode((UUID, UUID, UUID, Int, String?, String?, String?, String?, Int?, Bool, Date?, Bool, Bool, Double, Int).self) {
            var episode = ItemEpisode(
                id: id, seasonId: seasonId, itemId: itemId,
                episodeNumber: num, title: title, overview: overview,
                imageURL: imgUrl, airDate: airDate, runtimeMinutes: runtime
            )
            episode.isWatched = isWatched
            episode.watchedAt = watchedAt
            episode.isSelected = isSelected
            episode.isFavorite = isFavorite
            episode.avgRating = avgRating
            episode.ratingCount = ratingCount
            result.append(episode)
        }
        return result
    }

    func createEpisode(seasonId: UUID, itemId: UUID, episodeNumber: Int, title: String?,
                       overview: String?, imageURL: String?, airDate: String?,
                       runtimeMinutes: Int?) async throws -> UUID {
        guard let client else { throw DBError.notConnected }
        let rows = try await client.query("""
            INSERT INTO item_episodes (season_id, item_id, episode_number, title, overview,
                                        image_url, air_date, runtime_minutes)
            VALUES (\(seasonId), \(itemId), \(episodeNumber), \(title), \(overview),
                    \(imageURL), \(airDate), \(runtimeMinutes))
            ON CONFLICT (season_id, episode_number) DO UPDATE SET
                title = EXCLUDED.title, overview = EXCLUDED.overview,
                image_url = EXCLUDED.image_url, air_date = EXCLUDED.air_date,
                runtime_minutes = EXCLUDED.runtime_minutes
            RETURNING id
            """)
        for try await (id,) in rows.decode((UUID,).self) {
            return id
        }
        throw DBError.unexpectedResult
    }

    func createEpisodes(seasonId: UUID, itemId: UUID, episodes: [AIEpisodeResult]) async throws {
        for ep in episodes {
            _ = try await createEpisode(
                seasonId: seasonId, itemId: itemId,
                episodeNumber: ep.episodeNumber,
                title: ep.title, overview: ep.overview,
                imageURL: nil, airDate: ep.airDate,
                runtimeMinutes: ep.runtimeMinutes
            )
        }
    }

    func toggleEpisodeWatched(episodeId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            UPDATE item_episodes SET is_watched = NOT is_watched,
            watched_at = CASE WHEN NOT is_watched THEN NOW() ELSE NULL END
            WHERE id = \(episodeId)
            """)

        // Auto-sync season: if all selected episodes are watched, mark season watched
        try await client.query("""
            UPDATE item_seasons SET
                is_watched = (
                    SELECT COUNT(*) FILTER (WHERE is_selected) = COUNT(*) FILTER (WHERE is_watched AND is_selected)
                    FROM item_episodes WHERE season_id = item_seasons.id
                ),
                watched_at = CASE
                    WHEN (SELECT COUNT(*) FILTER (WHERE is_selected) = COUNT(*) FILTER (WHERE is_watched AND is_selected)
                          FROM item_episodes WHERE season_id = item_seasons.id) THEN NOW()
                    ELSE NULL
                END
            WHERE id = (SELECT season_id FROM item_episodes WHERE id = \(episodeId))
            """)

        // Auto-sync parent item
        try await client.query("""
            UPDATE watch_items SET
                is_watched = (SELECT COUNT(*) = COUNT(*) FILTER (WHERE is_watched = TRUE)
                              FROM item_seasons WHERE item_id = watch_items.id),
                watched_at = CASE
                    WHEN (SELECT COUNT(*) = COUNT(*) FILTER (WHERE is_watched = TRUE)
                          FROM item_seasons WHERE item_id = watch_items.id) THEN NOW()
                    ELSE NULL
                END
            WHERE id = (SELECT item_id FROM item_episodes WHERE id = \(episodeId))
            """)

        try await fetchCatalog()
    }

    func toggleEpisodeSelected(episodeId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            UPDATE item_episodes SET is_selected = NOT is_selected
            WHERE id = \(episodeId)
            """)
    }

    func markAllEpisodesWatched(seasonId: UUID, watched: Bool) async throws {
        guard let client else { throw DBError.notConnected }
        if watched {
            try await client.query("""
                UPDATE item_episodes SET is_watched = TRUE, watched_at = NOW()
                WHERE season_id = \(seasonId) AND is_selected = TRUE AND is_watched = FALSE
                """)
        } else {
            try await client.query("""
                UPDATE item_episodes SET is_watched = FALSE, watched_at = NULL
                WHERE season_id = \(seasonId) AND is_watched = TRUE
                """)
        }

        // Sync season watched status (compute from actual episode states)
        try await client.query("""
            UPDATE item_seasons SET
                is_watched = (
                    SELECT COUNT(*) FILTER (WHERE is_selected) = COUNT(*) FILTER (WHERE is_watched AND is_selected)
                    FROM item_episodes WHERE season_id = item_seasons.id
                ),
                watched_at = CASE
                    WHEN (SELECT COUNT(*) FILTER (WHERE is_selected) = COUNT(*) FILTER (WHERE is_watched AND is_selected)
                          FROM item_episodes WHERE season_id = item_seasons.id) THEN COALESCE(item_seasons.watched_at, NOW())
                    ELSE NULL
                END
            WHERE id = \(seasonId)
            """)

        // Sync parent item
        try await client.query("""
            UPDATE watch_items SET
                is_watched = (SELECT COUNT(*) = COUNT(*) FILTER (WHERE is_watched = TRUE)
                              FROM item_seasons WHERE item_id = watch_items.id),
                watched_at = CASE
                    WHEN (SELECT COUNT(*) = COUNT(*) FILTER (WHERE is_watched = TRUE)
                          FROM item_seasons WHERE item_id = watch_items.id) THEN NOW()
                    ELSE NULL
                END
            WHERE id = (SELECT item_id FROM item_seasons WHERE id = \(seasonId))
            """)

        try await fetchCatalog()
    }

    // MARK: - Episode Favorites

    func toggleEpisodeFavorite(episodeId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            UPDATE item_episodes SET is_favorite = NOT COALESCE(is_favorite, FALSE)
            WHERE id = \(episodeId)
            """)
    }

    // MARK: - Season Reviews

    func rateSeason(seasonId: UUID, userId: UUID, score: Double, comment: String?) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            INSERT INTO season_reviews (season_id, user_id, score, comment)
            VALUES (\(seasonId), \(userId), \(score), \(comment))
            ON CONFLICT (season_id, user_id)
            DO UPDATE SET score = \(score), comment = \(comment), updated_at = NOW()
            """)
    }

    func fetchSeasonReviews(for seasonId: UUID) async throws -> [SeasonReview] {
        guard let client else { return [] }
        let rows = try await client.query("""
            SELECT sr.id, sr.season_id, sr.user_id, sr.score::DOUBLE PRECISION, sr.comment, sr.created_at, sr.updated_at, u.name
            FROM season_reviews sr
            JOIN users u ON u.id = sr.user_id
            WHERE sr.season_id = \(seasonId)
            ORDER BY sr.updated_at DESC
            """)
        var result: [SeasonReview] = []
        for try await (id, seasonId, userId, score, comment, createdAt, updatedAt, userName)
            in rows.decode((UUID, UUID, UUID, Double, String?, Date, Date, String).self) {
            var review = SeasonReview(id: id, seasonId: seasonId, userId: userId, score: score, comment: comment, createdAt: createdAt, updatedAt: updatedAt)
            review.userName = userName
            result.append(review)
        }
        return result
    }

    // MARK: - Episode Ratings

    func rateEpisode(episodeId: UUID, userId: UUID, score: Double, comment: String?) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            INSERT INTO episode_ratings (episode_id, user_id, score, comment)
            VALUES (\(episodeId), \(userId), \(score), \(comment))
            ON CONFLICT (episode_id, user_id)
            DO UPDATE SET score = \(score), comment = \(comment), updated_at = NOW()
            """)
    }

    func fetchEpisodeRatings(for episodeId: UUID, currentUserId: UUID? = nil) async throws -> [EpisodeRating] {
        guard let client else { return [] }
        let rows: PostgresRowSequence
        if let currentUserId {
            rows = try await client.query("""
                SELECT r.id, r.episode_id, r.user_id, r.score::DOUBLE PRECISION, r.comment, r.created_at, r.updated_at, u.name,
                       COUNT(rl.user_id)::INTEGER AS like_count,
                       COALESCE(BOOL_OR(rl.user_id = \(currentUserId)), FALSE) AS liked_by_me
                FROM episode_ratings r
                JOIN users u ON u.id = r.user_id
                LEFT JOIN episode_rating_likes rl ON rl.rating_id = r.id
                WHERE r.episode_id = \(episodeId)
                GROUP BY r.id, u.name
                ORDER BY u.name
                """)
        } else {
            rows = try await client.query("""
                SELECT r.id, r.episode_id, r.user_id, r.score::DOUBLE PRECISION, r.comment, r.created_at, r.updated_at, u.name,
                       0::INTEGER AS like_count, FALSE AS liked_by_me
                FROM episode_ratings r
                JOIN users u ON u.id = r.user_id
                WHERE r.episode_id = \(episodeId)
                ORDER BY u.name
                """)
        }
        var result: [EpisodeRating] = []
        for try await (id, episodeId, userId, score, comment, created, updated, userName, likeCount, likedByMe)
            in rows.decode((UUID, UUID, UUID, Double, String?, Date, Date, String, Int, Bool).self) {
            var rating = EpisodeRating(id: id, episodeId: episodeId, userId: userId, score: score, comment: comment, createdAt: created, updatedAt: updated)
            rating.userName = userName
            rating.likeCount = likeCount
            rating.isLikedByCurrentUser = likedByMe
            result.append(rating)
        }
        // Fetch replies
        var repliesByRating: [UUID: [EpisodeRatingReply]] = [:]
        let replyRows = try await client.query("""
            SELECT rr.id, rr.rating_id, rr.user_id, rr.message, rr.created_at, u.name
            FROM episode_rating_replies rr
            JOIN episode_ratings r ON r.id = rr.rating_id
            JOIN users u ON u.id = rr.user_id
            WHERE r.episode_id = \(episodeId)
            ORDER BY rr.created_at ASC
            """)
        for try await (replyId, ratingId, userId, message, createdAt, userName)
            in replyRows.decode((UUID, UUID, UUID, String, Date, String).self) {
            repliesByRating[ratingId, default: []].append(
                EpisodeRatingReply(id: replyId, ratingId: ratingId, userId: userId, message: message, createdAt: createdAt, userName: userName)
            )
        }
        return result.map { r in var m = r; m.replies = repliesByRating[r.id] ?? []; return m }
    }

    func toggleEpisodeRatingLike(ratingId: UUID, userId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            WITH deleted AS (
                DELETE FROM episode_rating_likes WHERE rating_id = \(ratingId) AND user_id = \(userId) RETURNING 1
            )
            INSERT INTO episode_rating_likes (rating_id, user_id)
            SELECT \(ratingId), \(userId) WHERE NOT EXISTS (SELECT 1 FROM deleted)
            """)
    }

    func addEpisodeRatingReply(ratingId: UUID, userId: UUID, message: String) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            INSERT INTO episode_rating_replies (rating_id, user_id, message)
            VALUES (\(ratingId), \(userId), \(message))
            """)
    }

    // MARK: - Episode Comments

    func addEpisodeComment(episodeId: UUID, userId: UUID, message: String) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            INSERT INTO episode_comments (episode_id, user_id, message)
            VALUES (\(episodeId), \(userId), \(message))
            """)
    }

    func fetchEpisodeComments(for episodeId: UUID, currentUserId: UUID? = nil) async throws -> [EpisodeComment] {
        guard let client else { return [] }
        let rows: PostgresRowSequence
        if let currentUserId {
            rows = try await client.query("""
                SELECT c.id, c.episode_id, c.user_id, c.message, c.created_at, c.updated_at, u.name,
                       COUNT(l.user_id)::INTEGER AS like_count,
                       COALESCE(BOOL_OR(l.user_id = \(currentUserId)), FALSE) AS liked_by_me
                FROM episode_comments c
                JOIN users u ON u.id = c.user_id
                LEFT JOIN episode_comment_likes l ON l.comment_id = c.id
                WHERE c.episode_id = \(episodeId)
                GROUP BY c.id, u.name
                ORDER BY c.created_at DESC
                """)
        } else {
            rows = try await client.query("""
                SELECT c.id, c.episode_id, c.user_id, c.message, c.created_at, c.updated_at, u.name,
                       0::INTEGER AS like_count, FALSE AS liked_by_me
                FROM episode_comments c
                JOIN users u ON u.id = c.user_id
                WHERE c.episode_id = \(episodeId)
                ORDER BY c.created_at DESC
                """)
        }
        var result: [EpisodeComment] = []
        for try await (id, episodeId, userId, message, createdAt, updatedAt, userName, likeCount, likedByMe)
            in rows.decode((UUID, UUID, UUID, String, Date, Date, String, Int, Bool).self) {
            var comment = EpisodeComment(id: id, episodeId: episodeId, userId: userId, message: message, createdAt: createdAt, updatedAt: updatedAt)
            comment.userName = userName
            comment.likeCount = likeCount
            comment.isLikedByCurrentUser = likedByMe
            result.append(comment)
        }
        // Reactions
        let reactionRows = try await client.query("""
            SELECT r.comment_id, r.emoji, COUNT(*)::INTEGER AS cnt
            FROM episode_comment_reactions r JOIN episode_comments c ON c.id = r.comment_id
            WHERE c.episode_id = \(episodeId) GROUP BY r.comment_id, r.emoji
            """)
        var reactionsByComment: [UUID: [String: Int]] = [:]
        for try await (commentId, emoji, count) in reactionRows.decode((UUID, String, Int).self) {
            reactionsByComment[commentId, default: [:]][emoji] = count
        }
        var myReactionsByComment: [UUID: Set<String>] = [:]
        if let currentUserId {
            let myRows = try await client.query("""
                SELECT r.comment_id, r.emoji FROM episode_comment_reactions r
                JOIN episode_comments c ON c.id = r.comment_id
                WHERE c.episode_id = \(episodeId) AND r.user_id = \(currentUserId)
                """)
            for try await (commentId, emoji) in myRows.decode((UUID, String).self) {
                myReactionsByComment[commentId, default: []].insert(emoji)
            }
        }
        result = result.map { comment in
            var m = comment
            let rMap = reactionsByComment[comment.id] ?? [:]
            let mySet = myReactionsByComment[comment.id] ?? []
            m.reactions = rMap.keys.sorted().map { EpisodeCommentReaction(emoji: $0, count: rMap[$0] ?? 0, isMine: mySet.contains($0)) }
            return m
        }
        // Replies
        let replyRows = try await client.query("""
            SELECT r.id, r.comment_id, r.user_id, r.message, r.created_at, u.name
            FROM episode_comment_replies r JOIN episode_comments c ON c.id = r.comment_id
            JOIN users u ON u.id = r.user_id
            WHERE c.episode_id = \(episodeId) ORDER BY r.created_at ASC
            """)
        var repliesByComment: [UUID: [EpisodeCommentReply]] = [:]
        for try await (replyId, commentId, userId, message, createdAt, userName)
            in replyRows.decode((UUID, UUID, UUID, String, Date, String).self) {
            repliesByComment[commentId, default: []].append(
                EpisodeCommentReply(id: replyId, commentId: commentId, userId: userId, message: message, createdAt: createdAt, userName: userName)
            )
        }
        return result.map { c in var m = c; m.replies = repliesByComment[c.id] ?? []; return m }
    }

    func toggleEpisodeCommentLike(commentId: UUID, userId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            WITH deleted AS (
                DELETE FROM episode_comment_likes WHERE comment_id = \(commentId) AND user_id = \(userId) RETURNING 1
            )
            INSERT INTO episode_comment_likes (comment_id, user_id)
            SELECT \(commentId), \(userId) WHERE NOT EXISTS (SELECT 1 FROM deleted)
            """)
    }

    func toggleEpisodeCommentReaction(commentId: UUID, userId: UUID, emoji: String) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            WITH deleted AS (
                DELETE FROM episode_comment_reactions WHERE comment_id = \(commentId) AND user_id = \(userId) AND emoji = \(emoji) RETURNING 1
            )
            INSERT INTO episode_comment_reactions (comment_id, user_id, emoji)
            SELECT \(commentId), \(userId), \(emoji) WHERE NOT EXISTS (SELECT 1 FROM deleted)
            """)
    }

    func addEpisodeCommentReply(commentId: UUID, userId: UUID, message: String) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            INSERT INTO episode_comment_replies (comment_id, user_id, message)
            VALUES (\(commentId), \(userId), \(message))
            """)
    }

    func deleteEpisodeComment(commentId: UUID, userId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("DELETE FROM episode_comments WHERE id = \(commentId) AND user_id = \(userId)")
    }

    // MARK: - Episode Average Rating

    func fetchEpisodeAverageRating(for itemId: UUID) async throws -> (avg: Double, count: Int) {
        guard let client else { return (0, 0) }
        let rows = try await client.query("""
            SELECT COALESCE(AVG(er.score)::DOUBLE PRECISION, 0), COUNT(er.id)::INTEGER
            FROM episode_ratings er
            JOIN item_episodes e ON e.id = er.episode_id
            WHERE e.item_id = \(itemId)
            """)
        for try await (avg, count) in rows.decode((Double, Int).self) {
            return (avg, count)
        }
        return (0, 0)
    }

    // MARK: - Lists

    func fetchLists() async throws {
        guard let client else { return }
        let rows = try await client.query("""
            SELECT l.id, l.name, l.description, l.image_url, l.banner_image_url, l.is_active, l.created_at, l.updated_at,
                   l.created_by, u.name,
                   COUNT(le.id)::INTEGER as total,
                   COUNT(CASE WHEN wi.is_watched THEN 1 END)::INTEGER as watched
            FROM watch_lists l
            LEFT JOIN list_entries le ON le.list_id = l.id
            LEFT JOIN watch_items wi ON wi.id = le.item_id
            LEFT JOIN users u ON u.id = l.created_by
            GROUP BY l.id, u.name
            ORDER BY l.is_active DESC, l.updated_at DESC
            """)
        var result: [WatchList] = []
        for try await (id, name, desc, imageURL, bannerImageURL, isActive, createdAt, updatedAt, createdBy, createdByName, total, watched)
            in rows.decode((UUID, String, String?, String?, String?, Bool, Date, Date, UUID?, String?, Int, Int).self) {
            var list = WatchList(
                id: id,
                name: name,
                description: desc,
                imageURL: imageURL,
                bannerImageURL: bannerImageURL,
                isActive: isActive,
                createdAt: createdAt,
                updatedAt: updatedAt,
                createdBy: createdBy,
                createdByName: createdByName
            )
            list.totalItems = total
            list.watchedItems = watched
            result.append(list)
        }
        self.lists = result
    }

    func createList(name: String, description: String?, imageURL: String?, bannerImageURL: String? = nil, createdBy: UUID?) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query(
            "INSERT INTO watch_lists (name, description, image_url, banner_image_url, created_by) VALUES (\(name), \(description), \(imageURL), \(bannerImageURL), \(createdBy))"
        )
        try await fetchLists()
    }

    func updateList(id: UUID, name: String, description: String?, imageURL: String?, bannerImageURL: String? = nil, isActive: Bool) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            UPDATE watch_lists SET name = \(name), description = \(description),
            image_url = \(imageURL), banner_image_url = \(bannerImageURL), is_active = \(isActive), updated_at = NOW() WHERE id = \(id)
            """)
        try await fetchLists()
    }

    func closeSeason(listId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        // Remove entries where the item is not watched
        try await client.query("""
            DELETE FROM list_entries
            WHERE list_id = \(listId)
              AND item_id IN (SELECT id FROM watch_items WHERE is_watched = FALSE)
            """)
        // Mark list as completed
        try await client.query("""
            UPDATE watch_lists SET is_active = FALSE, updated_at = NOW() WHERE id = \(listId)
            """)
        try await fetchEntries(for: listId)
        try await fetchLists()
    }

    func reopenSeason(listId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            UPDATE watch_lists SET is_active = TRUE, updated_at = NOW() WHERE id = \(listId)
            """)
        try await fetchLists()
    }

    func deleteList(id: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("DELETE FROM watch_lists WHERE id = \(id)")
        try await fetchLists()
    }

    // MARK: - List Entries

    func fetchEntries(for listId: UUID) async throws {
        guard let client else { return }
        let rows = try await client.query("""
            SELECT le.id, le.list_id, le.item_id, le.position, le.added_at,
                   wi.title, wi.image_url, wi.category, wi.genre, wi.trailer_url, wi.year, wi.overview,
                   wi.is_watched, wi.watched_at, wi.created_at,
                   wi.imdb_rating, wi.rotten_tomatoes_score, wi.available_platforms,
                   le.season_id, s.season_number, s.name, s.image_url, s.trailer_url
            FROM list_entries le
            JOIN watch_items wi ON wi.id = le.item_id
            LEFT JOIN item_seasons s ON s.id = le.season_id
            WHERE le.list_id = \(listId)
            ORDER BY le.position ASC, le.added_at DESC
            """)
        var result: [ListEntry] = []
        for try await (eid, lid, iid, pos, addedAt, title, imgUrl, cat, genre, trailerUrl, year, overview, watched, watchedAt, itemCreated, imdbRating, rottenTomatoesScore, availablePlatforms, seasonId, seasonNum, seasonName, seasonImgUrl, seasonTrailerUrl)
            in rows.decode((UUID, UUID, UUID, Int, Date, String, String?, String, String?, String?, Int?, String?, Bool, Date?, Date, Double?, Int?, String?, UUID?, Int?, String?, String?, String?).self) {
            var item = WatchItem(id: iid, title: title, imageURL: imgUrl, category: cat, genre: genre, trailerURL: trailerUrl, year: year, overview: overview, createdAt: itemCreated)
            item.isWatched = watched
            item.watchedAt = watchedAt
            item.imdbRating = imdbRating
            item.rottenTomatoesScore = rottenTomatoesScore
            item.availablePlatforms = decodePlatforms(availablePlatforms)
            var entry = ListEntry(id: eid, listId: lid, itemId: iid, position: pos, addedAt: addedAt)
            entry.item = item
            entry.seasonId = seasonId
            if let seasonId, let seasonNum {
                entry.season = ItemSeason(id: seasonId, itemId: iid, seasonNumber: seasonNum, name: seasonName, imageURL: seasonImgUrl, trailerURL: seasonTrailerUrl)
            }
            result.append(entry)
        }
        self.currentEntries = result
    }

    func addItemToList(listId: UUID, itemId: UUID, seasonId: UUID? = nil) async throws {
        guard let client else { throw DBError.notConnected }
        let posRows = try await client.query(
            "SELECT (COALESCE(MAX(position), -1) + 1)::INTEGER FROM list_entries WHERE list_id = \(listId)"
        )
        var nextPos = 0
        for try await (pos,) in posRows.decode((Int,).self) {
            nextPos = pos
        }
        try await client.query(
            "INSERT INTO list_entries (list_id, item_id, position, season_id) VALUES (\(listId), \(itemId), \(nextPos), \(seasonId)) ON CONFLICT DO NOTHING"
        )
        try await fetchEntries(for: listId)
        try await fetchLists()
    }

    func removeEntry(entryId: UUID, listId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("DELETE FROM list_entries WHERE id = \(entryId)")
        try await fetchEntries(for: listId)
        try await fetchLists()
    }

    // MARK: - Ratings

    func fetchRatings(for itemId: UUID, currentUserId: UUID? = nil) async throws -> [Rating] {
        guard let client else { return [] }

        let rows: PostgresRowSequence
        do {
            if let currentUserId {
                rows = try await client.query("""
                    SELECT r.id, r.item_id, r.user_id, r.score::DOUBLE PRECISION, r.comment, r.created_at, r.updated_at, u.name,
                           COUNT(rl.user_id)::INTEGER AS like_count,
                           COALESCE(BOOL_OR(rl.user_id = \(currentUserId)), FALSE) AS liked_by_me
                    FROM ratings r
                    JOIN users u ON u.id = r.user_id
                    LEFT JOIN rating_likes rl ON rl.rating_id = r.id
                    WHERE r.item_id = \(itemId)
                    GROUP BY r.id, u.name
                    ORDER BY u.name
                    """)
            } else {
                rows = try await client.query("""
                    SELECT r.id, r.item_id, r.user_id, r.score::DOUBLE PRECISION, r.comment, r.created_at, r.updated_at, u.name,
                           COUNT(rl.user_id)::INTEGER AS like_count,
                           FALSE AS liked_by_me
                    FROM ratings r
                    JOIN users u ON u.id = r.user_id
                    LEFT JOIN rating_likes rl ON rl.rating_id = r.id
                    WHERE r.item_id = \(itemId)
                    GROUP BY r.id, u.name
                    ORDER BY u.name
                    """)
            }
        } catch {
            // Backward-compatible fallback if likes tables are unavailable.
            rows = try await client.query("""
                SELECT r.id, r.item_id, r.user_id, r.score::DOUBLE PRECISION, r.comment, r.created_at, r.updated_at, u.name,
                       0::INTEGER AS like_count,
                       FALSE AS liked_by_me
                FROM ratings r
                JOIN users u ON u.id = r.user_id
                WHERE r.item_id = \(itemId)
                ORDER BY u.name
                """)
        }

        var result: [Rating] = []
        for try await (id, itemId, userId, score, comment, created, updated, userName, likeCount, likedByMe)
            in rows.decode((UUID, UUID, UUID, Double, String?, Date, Date, String, Int, Bool).self) {
            var rating = Rating(id: id, itemId: itemId, userId: userId, score: score, comment: comment, createdAt: created, updatedAt: updated)
            rating.userName = userName
            rating.likeCount = likeCount
            rating.isLikedByCurrentUser = likedByMe
            result.append(rating)
        }

        // Fetch all replies for this item and attach them to each rating.
        var repliesByRating: [UUID: [RatingReply]] = [:]
        do {
            let replyRows = try await client.query("""
                SELECT rr.id, rr.rating_id, rr.user_id, rr.message, rr.created_at, u.name
                FROM rating_replies rr
                JOIN ratings r ON r.id = rr.rating_id
                JOIN users u ON u.id = rr.user_id
                WHERE r.item_id = \(itemId)
                ORDER BY rr.created_at ASC
                """)
            for try await (replyId, ratingId, userId, message, createdAt, userName)
                in replyRows.decode((UUID, UUID, UUID, String, Date, String).self) {
                let reply = RatingReply(
                    id: replyId,
                    ratingId: ratingId,
                    userId: userId,
                    message: message,
                    createdAt: createdAt,
                    userName: userName
                )
                repliesByRating[ratingId, default: []].append(reply)
            }
        } catch {
            repliesByRating = [:]
        }
        result = result.map { rating in
            var mutable = rating
            mutable.replies = repliesByRating[rating.id] ?? []
            return mutable
        }

        return result
    }

    func rateItem(itemId: UUID, userId: UUID, score: Double, comment: String?) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            INSERT INTO ratings (item_id, user_id, score, comment)
            VALUES (\(itemId), \(userId), \(score), \(comment))
            ON CONFLICT (item_id, user_id)
            DO UPDATE SET score = \(score), comment = \(comment), updated_at = NOW()
            """)
        try await fetchCatalog()
    }

    func toggleRatingLike(ratingId: UUID, userId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            WITH deleted AS (
                DELETE FROM rating_likes
                WHERE rating_id = \(ratingId) AND user_id = \(userId)
                RETURNING 1
            )
            INSERT INTO rating_likes (rating_id, user_id)
            SELECT \(ratingId), \(userId)
            WHERE NOT EXISTS (SELECT 1 FROM deleted)
            """)
    }

    func addRatingReply(ratingId: UUID, userId: UUID, message: String) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            INSERT INTO rating_replies (rating_id, user_id, message)
            VALUES (\(ratingId), \(userId), \(message))
            """)
    }

    // MARK: - Item Comments

    func fetchItemComments(for itemId: UUID, currentUserId: UUID? = nil) async throws -> [ItemComment] {
        guard let client else { return [] }
        let rows: PostgresRowSequence
        if let currentUserId {
            rows = try await client.query("""
                SELECT c.id, c.item_id, c.user_id, c.message, c.created_at, c.updated_at, u.name,
                       COUNT(l.user_id)::INTEGER AS like_count,
                       COALESCE(BOOL_OR(l.user_id = \(currentUserId)), FALSE) AS liked_by_me
                FROM item_comments c
                JOIN users u ON u.id = c.user_id
                LEFT JOIN item_comment_likes l ON l.comment_id = c.id
                WHERE c.item_id = \(itemId)
                GROUP BY c.id, u.name
                ORDER BY c.created_at DESC
                """)
        } else {
            rows = try await client.query("""
                SELECT c.id, c.item_id, c.user_id, c.message, c.created_at, c.updated_at, u.name,
                       COUNT(l.user_id)::INTEGER AS like_count,
                       FALSE AS liked_by_me
                FROM item_comments c
                JOIN users u ON u.id = c.user_id
                LEFT JOIN item_comment_likes l ON l.comment_id = c.id
                WHERE c.item_id = \(itemId)
                GROUP BY c.id, u.name
                ORDER BY c.created_at DESC
                """)
        }

        var result: [ItemComment] = []
        for try await (id, itemId, userId, message, createdAt, updatedAt, userName, likeCount, likedByMe)
            in rows.decode((UUID, UUID, UUID, String, Date, Date, String, Int, Bool).self) {
            var comment = ItemComment(
                id: id,
                itemId: itemId,
                userId: userId,
                message: message,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            comment.userName = userName
            comment.likeCount = likeCount
            comment.isLikedByCurrentUser = likedByMe
            result.append(comment)
        }

        let reactionRows = try await client.query("""
            SELECT r.comment_id, r.emoji, COUNT(*)::INTEGER AS reaction_count
            FROM item_comment_reactions r
            JOIN item_comments c ON c.id = r.comment_id
            WHERE c.item_id = \(itemId)
            GROUP BY r.comment_id, r.emoji
            """)
        var reactionsByComment: [UUID: [String: Int]] = [:]
        for try await (commentId, emoji, count)
            in reactionRows.decode((UUID, String, Int).self) {
            reactionsByComment[commentId, default: [:]][emoji] = count
        }

        var myReactionsByComment: [UUID: Set<String>] = [:]
        if let currentUserId {
            let myReactionRows = try await client.query("""
                SELECT r.comment_id, r.emoji
                FROM item_comment_reactions r
                JOIN item_comments c ON c.id = r.comment_id
                WHERE c.item_id = \(itemId) AND r.user_id = \(currentUserId)
                """)
            for try await (commentId, emoji) in myReactionRows.decode((UUID, String).self) {
                myReactionsByComment[commentId, default: []].insert(emoji)
            }
        }

        result = result.map { comment in
            var mutable = comment
            let reactionMap = reactionsByComment[comment.id] ?? [:]
            let mySet = myReactionsByComment[comment.id] ?? []
            mutable.reactions = reactionMap.keys.sorted().map { emoji in
                ItemCommentReaction(emoji: emoji, count: reactionMap[emoji] ?? 0, isMine: mySet.contains(emoji))
            }
            return mutable
        }

        let replyRows = try await client.query("""
            SELECT r.id, r.comment_id, r.user_id, r.message, r.created_at, u.name
            FROM item_comment_replies r
            JOIN item_comments c ON c.id = r.comment_id
            JOIN users u ON u.id = r.user_id
            WHERE c.item_id = \(itemId)
            ORDER BY r.created_at ASC
            """)
        var repliesByComment: [UUID: [ItemCommentReply]] = [:]
        for try await (replyId, commentId, userId, message, createdAt, userName)
            in replyRows.decode((UUID, UUID, UUID, String, Date, String).self) {
            let reply = ItemCommentReply(
                id: replyId,
                commentId: commentId,
                userId: userId,
                message: message,
                createdAt: createdAt,
                userName: userName
            )
            repliesByComment[commentId, default: []].append(reply)
        }

        result = result.map { comment in
            var mutable = comment
            mutable.replies = repliesByComment[comment.id] ?? []
            return mutable
        }
        return result
    }

    func addItemComment(itemId: UUID, userId: UUID, message: String) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            INSERT INTO item_comments (item_id, user_id, message)
            VALUES (\(itemId), \(userId), \(message))
            """)
    }

    func toggleItemCommentLike(commentId: UUID, userId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            WITH deleted AS (
                DELETE FROM item_comment_likes
                WHERE comment_id = \(commentId) AND user_id = \(userId)
                RETURNING 1
            )
            INSERT INTO item_comment_likes (comment_id, user_id)
            SELECT \(commentId), \(userId)
            WHERE NOT EXISTS (SELECT 1 FROM deleted)
            """)
    }

    func toggleItemCommentReaction(commentId: UUID, userId: UUID, emoji: String) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            WITH deleted AS (
                DELETE FROM item_comment_reactions
                WHERE comment_id = \(commentId) AND user_id = \(userId) AND emoji = \(emoji)
                RETURNING 1
            )
            INSERT INTO item_comment_reactions (comment_id, user_id, emoji)
            SELECT \(commentId), \(userId), \(emoji)
            WHERE NOT EXISTS (SELECT 1 FROM deleted)
            """)
    }

    func addItemCommentReply(commentId: UUID, userId: UUID, message: String) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            INSERT INTO item_comment_replies (comment_id, user_id, message)
            VALUES (\(commentId), \(userId), \(message))
            """)
    }

    func deleteItemComment(commentId: UUID, userId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            DELETE FROM item_comments
            WHERE id = \(commentId) AND user_id = \(userId)
            """)
    }

    // MARK: - Search (fuzzy with pg_trgm)

    func searchItems(query: String, category: String? = nil) async throws -> [WatchItem] {
        guard let client, !query.isEmpty else { return [] }
        let pattern = "%\(query)%"

        let rows: PostgresRowSequence
        if let category {
            rows = try await client.query("""
                SELECT wi.id, wi.title, wi.image_url, wi.category, wi.genre, wi.trailer_url, wi.year, wi.overview,
                       wi.is_watched, wi.watched_at, wi.created_at,
                       COALESCE(AVG(r.score), 0)::DOUBLE PRECISION,
                       COUNT(r.id)::INTEGER, wi.imdb_rating, wi.rotten_tomatoes_score, wi.available_platforms,
                       similarity(wi.title, \(query))::DOUBLE PRECISION
                FROM watch_items wi
                LEFT JOIN ratings r ON r.item_id = wi.id
                WHERE (wi.title ILIKE \(pattern) OR similarity(wi.title, \(query)) > 0.15)
                  AND wi.category = \(category)
                GROUP BY wi.id
                ORDER BY similarity(wi.title, \(query)) DESC, wi.title
                LIMIT 30
                """)
        } else {
            rows = try await client.query("""
                SELECT wi.id, wi.title, wi.image_url, wi.category, wi.genre, wi.trailer_url, wi.year, wi.overview,
                       wi.is_watched, wi.watched_at, wi.created_at,
                       COALESCE(AVG(r.score), 0)::DOUBLE PRECISION,
                       COUNT(r.id)::INTEGER, wi.imdb_rating, wi.rotten_tomatoes_score, wi.available_platforms,
                       similarity(wi.title, \(query))::DOUBLE PRECISION
                FROM watch_items wi
                LEFT JOIN ratings r ON r.item_id = wi.id
                WHERE wi.title ILIKE \(pattern) OR similarity(wi.title, \(query)) > 0.15
                GROUP BY wi.id
                ORDER BY similarity(wi.title, \(query)) DESC, wi.title
                LIMIT 30
                """)
        }

        var result: [WatchItem] = []
        for try await (id, title, imgUrl, cat, genre, trailerUrl, year, overview, watched, watchedAt, created, avgRating, ratingCount, imdbRating, rottenTomatoesScore, availablePlatforms, _)
            in rows.decode((UUID, String, String?, String, String?, String?, Int?, String?, Bool, Date?, Date, Double, Int, Double?, Int?, String?, Double).self) {
            var item = WatchItem(id: id, title: title, imageURL: imgUrl, category: cat, genre: genre, trailerURL: trailerUrl, year: year, overview: overview, createdAt: created)
            item.isWatched = watched
            item.watchedAt = watchedAt
            item.avgRating = avgRating
            item.ratingCount = ratingCount
            item.imdbRating = imdbRating
            item.rottenTomatoesScore = rottenTomatoesScore
            item.availablePlatforms = decodePlatforms(availablePlatforms)
            result.append(item)
        }
        return result
    }

    // MARK: - Related Items

    func fetchRelatedItems(for item: WatchItem) async throws -> [WatchItem] {
        guard let client else { return [] }
        let rows = try await client.query("""
            SELECT wi.id, wi.title, wi.image_url, wi.category, wi.genre, wi.trailer_url,
                   wi.year, wi.overview, wi.is_watched, wi.watched_at, wi.created_at,
                   COALESCE(AVG(r.score), 0)::DOUBLE PRECISION as avg_rating,
                   COUNT(r.id)::INTEGER as rating_count, wi.imdb_rating, wi.rotten_tomatoes_score, wi.available_platforms,
                   (
                       CASE WHEN wi.genre IS NOT NULL AND wi.genre = \(item.genre) THEN 2.0 ELSE 0.0 END
                       + CASE WHEN wi.category = \(item.category) THEN 1.0 ELSE 0.0 END
                       + similarity(wi.title, \(item.title))::DOUBLE PRECISION
                   ) AS relevance
            FROM watch_items wi
            LEFT JOIN ratings r ON r.item_id = wi.id
            WHERE wi.id != \(item.id)
              AND (
                  (wi.genre IS NOT NULL AND wi.genre = \(item.genre))
                  OR wi.category = \(item.category)
                  OR similarity(wi.title, \(item.title)) > 0.1
              )
            GROUP BY wi.id
            ORDER BY relevance DESC, wi.title
            LIMIT 8
            """)

        var result: [WatchItem] = []
        for try await (id, title, imgUrl, cat, genre, trailerUrl, year, overview, watched, watchedAt, created, avgRating, ratingCount, imdbRating, rottenTomatoesScore, availablePlatforms, _)
            in rows.decode((UUID, String, String?, String, String?, String?, Int?, String?, Bool, Date?, Date, Double, Int, Double?, Int?, String?, Double).self) {
            var relatedItem = WatchItem(id: id, title: title, imageURL: imgUrl, category: cat, genre: genre, trailerURL: trailerUrl, year: year, overview: overview, createdAt: created)
            relatedItem.isWatched = watched
            relatedItem.watchedAt = watchedAt
            relatedItem.avgRating = avgRating
            relatedItem.ratingCount = ratingCount
            relatedItem.imdbRating = imdbRating
            relatedItem.rottenTomatoesScore = rottenTomatoesScore
            relatedItem.availablePlatforms = decodePlatforms(availablePlatforms)
            result.append(relatedItem)
        }
        return result
    }

    // MARK: - Recently Accessed

    func trackItemAccess(userId: UUID, itemId: UUID) async throws {
        guard let client else { throw DBError.notConnected }
        try await client.query("""
            INSERT INTO recently_accessed (user_id, item_id, accessed_at)
            VALUES (\(userId), \(itemId), NOW())
            ON CONFLICT (user_id, item_id)
            DO UPDATE SET accessed_at = NOW()
            """)
        try await client.query("""
            DELETE FROM recently_accessed
            WHERE user_id = \(userId)
              AND accessed_at < (
                  SELECT accessed_at FROM recently_accessed
                  WHERE user_id = \(userId)
                  ORDER BY accessed_at DESC
                  LIMIT 1 OFFSET 10
              )
            """)
    }

    func fetchRecentlyAccessed(userId: UUID, excludeItemId: UUID, limit: Int = 10) async throws -> [WatchItem] {
        guard let client else { return [] }
        let rows = try await client.query("""
            SELECT wi.id, wi.title, wi.image_url, wi.category, wi.genre, wi.trailer_url,
                   wi.year, wi.overview, wi.is_watched, wi.watched_at, wi.created_at,
                   COALESCE(AVG(r.score), 0)::DOUBLE PRECISION as avg_rating,
                   COUNT(r.id)::INTEGER as rating_count, wi.imdb_rating, wi.rotten_tomatoes_score, wi.available_platforms
            FROM recently_accessed ra
            JOIN watch_items wi ON wi.id = ra.item_id
            LEFT JOIN ratings r ON r.item_id = wi.id
            WHERE ra.user_id = \(userId)
              AND ra.item_id != \(excludeItemId)
            GROUP BY wi.id, ra.accessed_at
            ORDER BY ra.accessed_at DESC
            LIMIT \(limit)
            """)

        var result: [WatchItem] = []
        for try await (id, title, imgUrl, cat, genre, trailerUrl, year, overview, watched, watchedAt, created, avgRating, ratingCount, imdbRating, rottenTomatoesScore, availablePlatforms)
            in rows.decode((UUID, String, String?, String, String?, String?, Int?, String?, Bool, Date?, Date, Double, Int, Double?, Int?, String?).self) {
            var item = WatchItem(id: id, title: title, imageURL: imgUrl, category: cat, genre: genre, trailerURL: trailerUrl, year: year, overview: overview, createdAt: created)
            item.isWatched = watched
            item.watchedAt = watchedAt
            item.avgRating = avgRating
            item.ratingCount = ratingCount
            item.imdbRating = imdbRating
            item.rottenTomatoesScore = rottenTomatoesScore
            item.availablePlatforms = decodePlatforms(availablePlatforms)
            result.append(item)
        }
        return result
    }

    func fetchRecentlyAccessed(userId: UUID, limit: Int = 10) async throws -> [WatchItem] {
        guard let client else { return [] }
        let rows = try await client.query("""
            SELECT wi.id, wi.title, wi.image_url, wi.category, wi.genre, wi.trailer_url,
                   wi.year, wi.overview, wi.is_watched, wi.watched_at, wi.created_at,
                   COALESCE(AVG(r.score), 0)::DOUBLE PRECISION as avg_rating,
                   COUNT(r.id)::INTEGER as rating_count, wi.imdb_rating, wi.rotten_tomatoes_score, wi.available_platforms
            FROM recently_accessed ra
            JOIN watch_items wi ON wi.id = ra.item_id
            LEFT JOIN ratings r ON r.item_id = wi.id
            WHERE ra.user_id = \(userId)
            GROUP BY wi.id, ra.accessed_at
            ORDER BY ra.accessed_at DESC
            LIMIT \(limit)
            """)

        var result: [WatchItem] = []
        for try await (id, title, imgUrl, cat, genre, trailerUrl, year, overview, watched, watchedAt, created, avgRating, ratingCount, imdbRating, rottenTomatoesScore, availablePlatforms)
            in rows.decode((UUID, String, String?, String, String?, String?, Int?, String?, Bool, Date?, Date, Double, Int, Double?, Int?, String?).self) {
            var item = WatchItem(id: id, title: title, imageURL: imgUrl, category: cat, genre: genre, trailerURL: trailerUrl, year: year, overview: overview, createdAt: created)
            item.isWatched = watched
            item.watchedAt = watchedAt
            item.avgRating = avgRating
            item.ratingCount = ratingCount
            item.imdbRating = imdbRating
            item.rottenTomatoesScore = rottenTomatoesScore
            item.availablePlatforms = decodePlatforms(availablePlatforms)
            result.append(item)
        }
        return result
    }

    // MARK: - Stats

    func fetchStats() async throws -> (totalWatched: Int, avgRating: Double, totalItems: Int) {
        guard let client else { return (0, 0, 0) }
        let rows = try await client.query("""
            SELECT
                (SELECT COUNT(*)::INTEGER FROM watch_items WHERE is_watched = TRUE),
                COALESCE((SELECT AVG(score) FROM ratings), 0)::DOUBLE PRECISION,
                (SELECT COUNT(*)::INTEGER FROM watch_items)
            """)
        for try await (watched, avg, total) in rows.decode((Int, Double, Int).self) {
            return (watched, avg, total)
        }
        return (0, 0, 0)
    }

    // MARK: - Auto Refresh

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                try? await self?.refreshAll()
            }
        }
    }

    func refreshAll() async throws {
        try await fetchCatalog()
        try await fetchLists()
    }

    // MARK: - URL Parsing

    typealias ConnectionParams = DatabaseConnectionSettings

    static func parseConnectionString(_ urlString: String) throws -> ConnectionParams {
        try DatabaseConnectionSettings(urlString: urlString)
    }

    enum DBError: LocalizedError {
        case notConnected, invalidURL, unexpectedResult, connectionTimedOut
        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to database"
            case .invalidURL: return "Invalid PostgreSQL connection URL"
            case .unexpectedResult: return "Unexpected database result"
            case .connectionTimedOut: return "Could not establish a verified database connection. Check the URL, network and server CA certificate, then try again."
            }
        }
    }
}
