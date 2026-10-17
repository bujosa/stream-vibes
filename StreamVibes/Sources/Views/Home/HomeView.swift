import SwiftUI

struct HomeView: View {
    @Environment(DatabaseService.self) var db
    @AppStorage("currentUserId") private var currentUserId = ""
    @Binding var selectedTab: AppTab
    @Binding var selectedItem: WatchItem?

    @State private var recentlyViewedItems: [WatchItem] = []

    private var currentUser: AppUser? {
        guard let uuid = UUID(uuidString: currentUserId) else { return nil }
        return db.users.first { $0.id == uuid }
    }

    private var pendingItems: [WatchItem] {
        db.catalogItems.filter { $0.watchStatus == .pending }
    }

    private var inProgressItems: [WatchItem] {
        db.catalogItems.filter { $0.watchStatus == .inProgress }
    }

    private var watchedItems: [WatchItem] {
        db.catalogItems.filter { $0.watchStatus == .watched }
    }

    private var topRated: [WatchItem] {
        db.catalogItems.filter { $0.avgRating > 0 }.sorted { $0.avgRating > $1.avgRating }.prefix(10).map { $0 }
    }

    private var animeItems: [WatchItem] {
        db.catalogItems.filter { $0.category == "anime" }
    }

    private var movieItems: [WatchItem] {
        db.catalogItems.filter { $0.category == "movie" }
    }

    private var seriesItems: [WatchItem] {
        db.catalogItems.filter { $0.category == "series" }
    }

    private var novelaItems: [WatchItem] {
        db.catalogItems.filter { $0.category == "novela" }
    }

    private var heroItem: WatchItem? {
        pendingItems.first ?? movieItems.first ?? animeItems.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Hero Banner
                if let hero = heroItem {
                    heroBanner(hero)
                }

                VStack(alignment: .leading, spacing: 28) {
                    header
                    statsBar

                    if db.catalogItems.isEmpty {
                        ContentUnavailableView {
                            Label("Your shared catalog starts here", systemImage: "film.stack")
                        } description: {
                            Text("Add your first title, then create a watch list to start tracking together.")
                        } actions: {
                            Button("Open Catalog") { selectedTab = .catalog }
                                .buttonStyle(.borderedProminent)
                                .tint(SVTheme.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }

                    // Recently Viewed
                    if !recentlyViewedItems.isEmpty {
                        carouselRow(
                            title: "Recently Viewed",
                            icon: "clock.arrow.circlepath",
                            iconColor: SVTheme.accent,
                            items: recentlyViewedItems,
                            showWatchedBadge: true
                        )
                    }

                    // Pending to Watch
                    if !pendingItems.isEmpty {
                        carouselRow(
                            title: "Pending to Watch",
                            icon: "clock.fill",
                            iconColor: .orange,
                            items: pendingItems
                        )
                    }

                    // In Progress
                    if !inProgressItems.isEmpty {
                        carouselRow(
                            title: "In Progress",
                            icon: "play.circle.fill",
                            iconColor: .blue,
                            items: inProgressItems
                        )
                    }

                    // Already Watched
                    if !watchedItems.isEmpty {
                        carouselRow(
                            title: "Already Watched",
                            icon: "checkmark.circle.fill",
                            iconColor: SVTheme.success,
                            items: watchedItems,
                            showWatchedBadge: true
                        )
                    }

                    // Top Rated
                    if !topRated.isEmpty {
                        topRatedRow
                    }

                    // Anime
                    if !animeItems.isEmpty {
                        carouselRow(
                            title: "Anime",
                            icon: "sparkles.tv",
                            iconColor: SVTheme.anime,
                            items: animeItems
                        )
                    }

                    // Movies
                    if !movieItems.isEmpty {
                        carouselRow(
                            title: "Movies",
                            icon: "film",
                            iconColor: SVTheme.movie,
                            items: movieItems
                        )
                    }

                    // Series
                    if !seriesItems.isEmpty {
                        carouselRow(
                            title: "Series",
                            icon: "tv",
                            iconColor: SVTheme.series,
                            items: seriesItems
                        )
                    }

                    // Telenovelas
                    if !novelaItems.isEmpty {
                        carouselRow(
                            title: "Telenovelas",
                            icon: "theatermasks.fill",
                            iconColor: SVTheme.novela,
                            items: novelaItems
                        )
                    }

                    // Your Lists
                    if !db.lists.isEmpty {
                        listsSection
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
        .background(SVTheme.background)
        .task {
            guard let uid = UUID(uuidString: currentUserId) else { return }
            recentlyViewedItems = (try? await db.fetchRecentlyAccessed(userId: uid, limit: 10)) ?? []
        }
        .onChange(of: db.catalogItems.count) {
            guard let uid = UUID(uuidString: currentUserId) else { return }
            Task {
                recentlyViewedItems = (try? await db.fetchRecentlyAccessed(userId: uid, limit: 10)) ?? []
            }
        }
    }

    // MARK: - Hero Banner

    private func heroBanner(_ item: WatchItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let urlStr = item.imageURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        Color.clear
                            .frame(height: 380)
                            .overlay {
                                img.resizable()
                                    .aspectRatio(contentMode: .fill)
                            }
                            .clipped()
                    } else {
                        heroPlaceholder(item)
                    }
                }
            } else {
                heroPlaceholder(item)
            }

            LinearGradient(
                colors: [.clear, SVTheme.background.opacity(0.7), SVTheme.background],
                startPoint: .top, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: SVTheme.categoryIcon(item.category))
                    Text(SVTheme.categoryLabel(item.category))
                }
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(SVTheme.categoryColor(item.category))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                Text(item.title)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4)

                if let overview = item.overview {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(SVTheme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: 500, alignment: .leading)
                }

                if let year = item.year {
                    Text(String(year))
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                }
            }
            .padding(32)
        }
        .frame(height: 380)
        .clipped()
        .onTapGesture { selectedItem = item }
    }

    private func heroPlaceholder(_ item: WatchItem) -> some View {
        LinearGradient(
            colors: [SVTheme.categoryColor(item.category).opacity(0.4), SVTheme.background],
            startPoint: .topTrailing, endPoint: .bottomLeading
        )
        .frame(height: 380)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome back\(currentUser.map { ", \($0.name)" } ?? "")")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(SVTheme.textPrimary)
                Text("What are we watching next?")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
            }
            Spacer()

            Button {
                Task { try? await db.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.title3)
                    .foregroundStyle(SVTheme.textSecondary)
            }
            .buttonStyle(.plain)

            SettingsButton()
        }
        .padding(.top, 16)
    }

    // MARK: - Stats Bar

    private var statsBar: some View {
        HStack(spacing: 12) {
            statPill(icon: "checkmark.circle.fill", value: "\(watchedItems.count)", label: "Watched", color: SVTheme.success)
            statPill(icon: "star.fill", value: {
                let rated = db.catalogItems.filter { $0.avgRating > 0 }
                let avg = rated.isEmpty ? 0 : rated.map(\.avgRating).reduce(0, +) / Double(rated.count)
                return String(format: "%.1f", avg)
            }(), label: "Avg Rating", color: SVTheme.star)
            statPill(icon: "film.stack", value: "\(db.catalogItems.count)", label: "Total", color: SVTheme.movie)
            statPill(icon: "list.bullet.rectangle", value: "\(db.lists.count)", label: "Lists", color: SVTheme.accent)
        }
    }

    private func statPill(icon: String, value: String, label: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.headline.bold())
                    .foregroundStyle(SVTheme.textPrimary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(SVTheme.textMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(SVTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Carousel Row

    private func carouselRow(
        title: String,
        icon: String,
        iconColor: Color,
        items: [WatchItem],
        showWatchedBadge: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(SVTheme.textPrimary)
                Text("\(items.count)")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SVTheme.surface)
                    .clipShape(Capsule())
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(items) { item in
                        PosterCard(item: item, showWatchedBadge: showWatchedBadge)
                            .onTapGesture { selectedItem = item }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Top Rated Row

    private var topRatedRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .foregroundStyle(SVTheme.star)
                Text("Top Rated")
                    .font(.title3.bold())
                    .foregroundStyle(SVTheme.textPrimary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(topRated.enumerated()), id: \.element.id) { index, item in
                        TopRatedCard(item: item, rank: index + 1, avgScore: item.avgRating)
                            .onTapGesture { selectedItem = item }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Lists Section

    private var listsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle.fill")
                    .foregroundStyle(SVTheme.accent)
                Text("Your Lists")
                    .font(.title3.bold())
                    .foregroundStyle(SVTheme.textPrimary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(db.lists) { list in
                        Button {
                            selectedTab = .lists
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    Group {
                                        if let imageURL = list.imageURL, !imageURL.isEmpty, let url = URL(string: imageURL) {
                                            AsyncImage(url: url) { phase in
                                                switch phase {
                                                case .success(let image):
                                                    image.resizable().aspectRatio(contentMode: .fill)
                                                default:
                                                    listCoverPlaceholder
                                                }
                                            }
                                        } else {
                                            listCoverPlaceholder
                                        }
                                    }
                                    .frame(height: 90)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }

                                HStack {
                                    Text(list.name)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(SVTheme.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                    if !list.isActive {
                                        Text("Done")
                                            .font(.caption2)
                                            .foregroundStyle(SVTheme.success)
                                    }
                                }

                                if let desc = list.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.caption)
                                        .foregroundStyle(SVTheme.textMuted)
                                        .lineLimit(1)
                                }

                                Text("by \(list.createdByName ?? "Unknown") · \(list.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundStyle(SVTheme.textMuted)
                                    .lineLimit(1)

                                ProgressView(value: list.progress)
                                    .tint(SVTheme.accent)

                                Text("\(list.watchedItems)/\(list.totalItems) watched")
                                    .font(.caption2)
                                    .foregroundStyle(SVTheme.textMuted)
                            }
                            .padding(14)
                            .frame(width: 220)
                            .background(SVTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var listCoverPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [SVTheme.accent.opacity(0.35), SVTheme.card], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title3)
                .foregroundStyle(SVTheme.textMuted)
        }
    }
}

// MARK: - Poster Card

struct PosterCard: View {
    let item: WatchItem
    var showWatchedBadge: Bool = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let urlStr = item.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            case .failure:
                                posterPlaceholder
                            default:
                                ZStack { SVTheme.card; ProgressView().controlSize(.small) }
                            }
                        }
                    } else {
                        posterPlaceholder
                    }
                }
                .frame(width: 150, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .trailing, spacing: 4) {
                    Text(SVTheme.categoryLabel(item.category))
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(SVTheme.categoryColor(item.category).opacity(0.9))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3))

                    if showWatchedBadge || item.isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(SVTheme.success)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                    }
                }
                .padding(6)
            }
            .shadow(color: .black.opacity(isHovered ? 0.5 : 0.2), radius: isHovered ? 10 : 3)
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }

            Text(item.title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(SVTheme.textPrimary)
                .lineLimit(1)

            HStack(spacing: 4) {
                if let year = item.year {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundStyle(SVTheme.textMuted)
                }
                if item.avgRating > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(SVTheme.star)
                        Text(String(format: "%.1f", item.avgRating))
                            .font(.caption2)
                            .foregroundStyle(SVTheme.star)
                    }
                }
            }
        }
        .frame(width: 150)
    }

    private var posterPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [SVTheme.categoryColor(item.category).opacity(0.4), SVTheme.card],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 6) {
                Image(systemName: SVTheme.categoryIcon(item.category))
                    .font(.system(size: 28))
                    .foregroundStyle(SVTheme.textMuted)
                Text(item.title)
                    .font(.caption2)
                    .foregroundStyle(SVTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
            }
        }
    }
}

// MARK: - Top Rated Card

struct TopRatedCard: View {
    let item: WatchItem
    let rank: Int
    let avgScore: Double
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let urlStr = item.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: 180, height: 250)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 100)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(SVTheme.star)
                    Text(String(format: "%.1f", avgScore))
                        .font(.subheadline.bold())
                        .foregroundStyle(SVTheme.star)
                }

                Text(item.title)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(10)

            Text("#\(rank)")
                .font(.system(size: 44, weight: .black, design: .rounded))
                .foregroundStyle(.white.opacity(0.15))
                .padding(6)
        }
        .frame(width: 180, height: 250)
        .shadow(color: .black.opacity(isHovered ? 0.5 : 0.2), radius: isHovered ? 10 : 3)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [SVTheme.categoryColor(item.category).opacity(0.4), SVTheme.card], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: SVTheme.categoryIcon(item.category))
                .font(.largeTitle)
                .foregroundStyle(SVTheme.textMuted)
        }
    }
}

// MARK: - Settings Button

struct SettingsButton: View {
    @State private var showSettings = false

    var body: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.title3)
                .foregroundStyle(SVTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}
