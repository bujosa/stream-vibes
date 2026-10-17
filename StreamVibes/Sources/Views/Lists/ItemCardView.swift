import SwiftUI

struct ItemCardView: View {
    @Environment(DatabaseService.self) var db
    @AppStorage("currentUserId") private var currentUserId = ""
    let entry: ListEntry
    let listId: UUID
    @State private var isHovered = false
    @State private var showRemoveConfirm = false
    @State private var showEpisodeEditor = false
    @State private var showQuickReview = false
    @State private var showSeasonCompletionWizard = false
    @State private var pendingSeasonWizardAfterEpisodeEditor = false

    // Episode state
    @State private var episodes: [ItemEpisode] = []
    @State private var isLoadingEpisodes = false

    // Quick review state
    @State private var reviewScore: Double = 0
    @State private var reviewComment = ""
    @State private var existingRating: Rating?

    private var item: WatchItem? { entry.item }
    private var hasSeason: Bool { entry.seasonId != nil }

    private var watchedCount: Int { episodes.filter(\.isWatched).count }
    private var totalEpisodes: Int { episodes.count }
    private var watchProgress: Double {
        guard totalEpisodes > 0 else { return 0 }
        return Double(watchedCount) / Double(totalEpisodes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Poster
            ZStack {
                Color.clear
                    .frame(height: 250)
                    .overlay { posterImage }
                    .clipped()

                // Category badge (top-right)
                VStack(alignment: .trailing, spacing: 4) {
                    if let item {
                        Text(SVTheme.categoryLabel(item.category))
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(SVTheme.categoryColor(item.category).opacity(0.9))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                // Hover actions (top-left)
                if isHovered {
                    VStack(spacing: 6) {
                        hoverButton("xmark", color: .white.opacity(0.15)) {
                            showRemoveConfirm = true
                        }
                        if hasSeason {
                            hoverButton("list.bullet", color: .white.opacity(0.15)) {
                                showEpisodeEditor = true
                                loadEpisodes()
                            }
                            hoverButton("party.popper", color: SVTheme.success.opacity(0.24)) {
                                openSeasonWizard()
                            }
                        }
                        hoverButton("star", color: .white.opacity(0.15)) {
                            showQuickReview = true
                            loadRating()
                        }
                    }
                    .padding(8)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                // Bottom gradient with quick watched button
                if isHovered, let item, !hasSeason {
                    VStack {
                        Spacer()
                        Button {
                            Task { try? await db.toggleItemWatched(itemId: item.id) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: item.isWatched ? "eye.slash" : "eye")
                                    .font(.caption2)
                                Text(item.isWatched ? "Unwatched" : "Watched")
                                    .font(.caption2.bold())
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(.black.opacity(0.6))
                            .background(.ultraThinMaterial)
                        }
                        .buttonStyle(.plain)
                    }
                    .transition(.opacity)
                }
            }

            // Info section
            VStack(alignment: .leading, spacing: 6) {
                Text(item?.title ?? "Unknown")
                    .font(.subheadline.bold())
                    .foregroundStyle(SVTheme.textPrimary)
                    .lineLimit(2)

                // Season badge + watched status
                HStack(spacing: 6) {
                    if let season = entry.season {
                        Text("S\(season.seasonNumber)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(SVTheme.accent.opacity(0.2))
                            .foregroundStyle(SVTheme.accent)
                            .clipShape(Capsule())
                    }

                    if let year = item?.year {
                        Text(String(year))
                            .font(.caption2)
                            .foregroundStyle(SVTheme.textMuted)
                    }

                    if let season = entry.season, season.ratingCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                            Text(String(format: "%.1f", season.avgRating))
                                .font(.caption2.bold())
                        }
                        .foregroundStyle(SVTheme.star)
                    }

                    Spacer()

                    if let rating = existingRating {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                            Text(String(format: "%.1f", rating.score))
                                .font(.caption2.bold())
                        }
                        .foregroundStyle(SVTheme.star)
                    }
                }

                // Episode progress (for season entries)
                if hasSeason && totalEpisodes > 0 {
                    VStack(alignment: .leading, spacing: 3) {
                        // Progress bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(SVTheme.surface)
                                    .frame(height: 4)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(watchProgress >= 1 ? SVTheme.success : SVTheme.accent)
                                    .frame(width: geo.size.width * watchProgress, height: 4)
                            }
                        }
                        .frame(height: 4)

                        HStack {
                            Text("\(watchedCount)/\(totalEpisodes) episodes")
                                .font(.system(size: 10))
                                .foregroundStyle(SVTheme.textMuted)
                            Spacer()
                            if watchProgress >= 1 {
                                Text("Complete")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(SVTheme.success)
                            } else if watchedCount > 0 {
                                Text("\(Int(watchProgress * 100))%")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(SVTheme.accent)
                            }
                        }
                    }
                } else {
                    // Simple watched status for movies
                    if item?.isWatched == true {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                            Text("Watched")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(SVTheme.success)
                    } else {
                        Text("To watch")
                            .font(.system(size: 10))
                            .foregroundStyle(SVTheme.textMuted)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SVTheme.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: SVTheme.cardCornerRadius))
        .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 12 : 4)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.2), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            loadRating()
            if hasSeason { loadEpisodesQuietly() }
        }
        .contextMenu {
            if let item {
                Button(item.isWatched ? "Mark as Unwatched" : "Mark as Watched") {
                    Task { try? await db.toggleItemWatched(itemId: item.id) }
                }
            }
            if hasSeason {
                Button("Edit Episodes") {
                    showEpisodeEditor = true
                    loadEpisodes()
                }
                Button("Close Season") {
                    openSeasonWizard()
                }
            }
            Button("Quick Review") {
                showQuickReview = true
                loadRating()
            }
            Divider()
            Button("Remove from List", role: .destructive) {
                Task { try? await db.removeEntry(entryId: entry.id, listId: listId) }
            }
        }
        .alert("Remove from List", isPresented: $showRemoveConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                Task { try? await db.removeEntry(entryId: entry.id, listId: listId) }
            }
        } message: {
            Text("Are you sure you want to remove \"\(item?.title ?? "this item")\" from the list?")
        }
        .sheet(isPresented: $showEpisodeEditor) {
            episodeEditorSheet
        }
        .sheet(isPresented: $showSeasonCompletionWizard) {
            if let season = entry.season {
                SeasonCompletionWizardView(
                    season: season,
                    itemTitle: item?.title ?? "Unknown",
                    entryId: entry.id,
                    listId: listId,
                    preferredCompletionMode: .finishNow,
                    preferredReviewMode: .skip,
                    onCompleted: {
                        Task { try? await db.fetchEntries(for: listId) }
                        loadEpisodesQuietly()
                        loadRating()
                    }
                )
                .environment(db)
            }
        }
        .popover(isPresented: $showQuickReview, arrowEdge: .trailing) {
            quickReviewPopover
        }
    }

    // MARK: - Hover Button

    private func hoverButton(_ icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(color)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Episode Editor

    private var episodeEditorSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Episodes")
                        .font(.title3.bold())
                        .foregroundStyle(SVTheme.textPrimary)
                    Text(item?.title ?? "")
                        .font(.headline)
                        .foregroundStyle(SVTheme.textPrimary)
                        .lineLimit(2)
                    if let season = entry.season {
                        Text("Season \(season.seasonNumber)")
                            .font(.subheadline)
                            .foregroundStyle(SVTheme.textSecondary)
                    }
                }
                Spacer()
                Button("Done") {
                    showEpisodeEditor = false
                }
                .buttonStyle(.bordered)
                if hasSeason {
                    Button {
                        openSeasonWizard(fromEpisodeEditor: true)
                    } label: {
                        Label("Close Season", systemImage: "party.popper")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SVTheme.success)
                }
                if !episodes.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(watchedCount)/\(totalEpisodes)")
                            .font(.headline.bold())
                            .foregroundStyle(SVTheme.accent)
                        Text("watched")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                    }
                }
            }

            if totalEpisodes > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(SVTheme.surface)
                            .frame(height: 8)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(watchProgress >= 1 ? SVTheme.success : SVTheme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .leading) {
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(watchProgress >= 1 ? SVTheme.success : SVTheme.accent)
                                        .frame(width: geo.size.width * watchProgress, height: 8)
                                }
                            }
                    }
                    Text("Click any episode row to mark it watched or unwatched from this view.")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                }
            }

            if !episodes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Actions")
                        .font(.caption.bold())
                        .foregroundStyle(SVTheme.textSecondary)
                    HStack(spacing: 8) {
                    quickSelectButton("All Watched") {
                        markAllWatched(true)
                    }
                    quickSelectButton("All Unwatched") {
                        markAllWatched(false)
                    }
                    quickSelectButton("1st Half") {
                        markFirstHalfWatched()
                    }
                        quickSelectButton("2nd Half") {
                            markSecondHalfWatched()
                        }
                    }
                }
            }

            Divider().overlay(SVTheme.border)

            if isLoadingEpisodes {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                }
            } else if episodes.isEmpty {
                Text("No episodes available")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(episodes) { episode in
                            episodeRow(episode)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 760, minHeight: 520, idealHeight: 620)
        .background(SVTheme.surface)
        .onDisappear {
            if pendingSeasonWizardAfterEpisodeEditor {
                pendingSeasonWizardAfterEpisodeEditor = false
                showSeasonCompletionWizard = true
            }
        }
    }

    private func episodeRow(_ episode: ItemEpisode) -> some View {
        Button {
            Task { @MainActor in
                try? await db.toggleEpisodeWatched(episodeId: episode.id)
                guard let seasonId = entry.seasonId else { return }
                episodes = (try? await db.fetchEpisodes(for: seasonId)) ?? []
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: episode.isWatched ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(episode.isWatched ? SVTheme.success : SVTheme.textMuted.opacity(0.4))

                Text("\(episode.episodeNumber)")
                    .font(.subheadline.bold().monospaced())
                    .foregroundStyle(SVTheme.textMuted)
                    .frame(width: 28, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    Text((episode.title?.isEmpty == false ? episode.title! : "Episode \(episode.episodeNumber)"))
                        .font(.subheadline)
                        .foregroundStyle(episode.isWatched ? SVTheme.textSecondary : SVTheme.textPrimary)
                        .lineLimit(1)
                        .strikethrough(episode.isWatched, color: SVTheme.textMuted.opacity(0.3))

                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if episode.isWatched {
                    Text("Watched")
                        .font(.caption.bold())
                        .foregroundStyle(SVTheme.success)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(SVTheme.success.opacity(0.12))
                        .clipShape(Capsule())
                }

                if let runtime = episode.runtimeMinutes {
                    Text("\(runtime)m")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
            .background(episode.isWatched ? SVTheme.success.opacity(0.07) : SVTheme.card.opacity(0.65))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(episode.isWatched ? SVTheme.success.opacity(0.3) : SVTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func quickSelectButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(SVTheme.card)
                .foregroundStyle(SVTheme.textSecondary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(SVTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quick Review Popover

    private var quickReviewPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Review")
                .font(.subheadline.bold())
                .foregroundStyle(SVTheme.textPrimary)

            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(SVTheme.star)
                Slider(value: $reviewScore, in: 0...10, step: 0.5)
                    .tint(SVTheme.accent)
                Text(String(format: "%.1f", reviewScore))
                    .font(.subheadline.bold())
                    .foregroundStyle(scoreColor)
                    .frame(width: 32)
            }

            TextField("Comment (optional)", text: $reviewComment)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            HStack {
                if existingRating != nil {
                    Text("Updating")
                        .font(.caption2)
                        .foregroundStyle(SVTheme.textMuted)
                }
                Spacer()
                Button("Save") {
                    Task {
                        guard let itemId = item?.id,
                              let uid = UUID(uuidString: currentUserId) else { return }
                        let trimmed = reviewComment.trimmingCharacters(in: .whitespacesAndNewlines)
                        try? await db.rateItem(
                            itemId: itemId, userId: uid,
                            score: reviewScore, comment: trimmed.isEmpty ? nil : trimmed
                        )
                        await loadRatingAsync()
                        showQuickReview = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(SVTheme.accent)
                .controlSize(.small)
                .disabled(reviewScore == 0)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(SVTheme.surface)
    }

    private var scoreColor: Color {
        if reviewScore >= 8 { return SVTheme.success }
        if reviewScore >= 6 { return SVTheme.star }
        if reviewScore >= 4 { return .orange }
        return .red
    }

    // MARK: - Quick Actions

    private func markAllWatched(_ watched: Bool) {
        guard let seasonId = entry.seasonId else { return }
        Task { @MainActor in
            try? await db.markAllEpisodesWatched(seasonId: seasonId, watched: watched)
            episodes = (try? await db.fetchEpisodes(for: seasonId)) ?? []
        }
    }

    private func markFirstHalfWatched() {
        guard let seasonId = entry.seasonId else { return }
        let currentEpisodes = episodes.sorted { $0.episodeNumber < $1.episodeNumber }
        let half = currentEpisodes.count / 2
        Task { @MainActor in
            // First mark all unwatched, then mark first half watched
            try? await db.markAllEpisodesWatched(seasonId: seasonId, watched: false)
            for i in 0..<half {
                let ep = currentEpisodes[i]
                if !ep.isWatched {
                    try? await db.toggleEpisodeWatched(episodeId: ep.id)
                }
            }
            episodes = (try? await db.fetchEpisodes(for: seasonId)) ?? []
        }
    }

    private func markSecondHalfWatched() {
        guard let seasonId = entry.seasonId else { return }
        let currentEpisodes = episodes.sorted { $0.episodeNumber < $1.episodeNumber }
        let half = currentEpisodes.count / 2
        Task { @MainActor in
            try? await db.markAllEpisodesWatched(seasonId: seasonId, watched: false)
            for i in half..<currentEpisodes.count {
                let ep = currentEpisodes[i]
                if !ep.isWatched {
                    try? await db.toggleEpisodeWatched(episodeId: ep.id)
                }
            }
            episodes = (try? await db.fetchEpisodes(for: seasonId)) ?? []
        }
    }

    private func openSeasonWizard(fromEpisodeEditor: Bool = false) {
        loadEpisodes()
        if fromEpisodeEditor {
            pendingSeasonWizardAfterEpisodeEditor = true
            showEpisodeEditor = false
        } else {
            showSeasonCompletionWizard = true
        }
    }

    // MARK: - Data Loading

    private func loadEpisodes() {
        guard let seasonId = entry.seasonId else { return }
        isLoadingEpisodes = true
        Task { @MainActor in
            episodes = (try? await db.fetchEpisodes(for: seasonId)) ?? []
            isLoadingEpisodes = false
        }
    }

    private func loadEpisodesQuietly() {
        guard let seasonId = entry.seasonId else { return }
        Task { @MainActor in
            episodes = (try? await db.fetchEpisodes(for: seasonId)) ?? []
        }
    }

    private func loadRating() {
        guard let itemId = item?.id, let uid = UUID(uuidString: currentUserId) else { return }
        Task {
            let ratings = (try? await db.fetchRatings(for: itemId, currentUserId: uid)) ?? []
            if let mine = ratings.first(where: { $0.userId == uid }) {
                existingRating = mine
                reviewScore = mine.score
                reviewComment = mine.comment ?? ""
            }
        }
    }

    private func loadRatingAsync() async {
        guard let itemId = item?.id, let uid = UUID(uuidString: currentUserId) else { return }
        let ratings = (try? await db.fetchRatings(for: itemId, currentUserId: uid)) ?? []
        if let mine = ratings.first(where: { $0.userId == uid }) {
            existingRating = mine
        }
    }

    // MARK: - Images

    @ViewBuilder
    private var posterImage: some View {
        if let urlStr = item?.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    placeholderImage
                default:
                    ZStack {
                        SVTheme.card
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        } else {
            placeholderImage
        }
    }

    private var placeholderImage: some View {
        ZStack {
            LinearGradient(
                colors: [
                    SVTheme.categoryColor(item?.category ?? "movie").opacity(0.4),
                    SVTheme.surface
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 8) {
                Image(systemName: SVTheme.categoryIcon(item?.category ?? "movie"))
                    .font(.system(size: 36))
                    .foregroundStyle(SVTheme.textMuted)

                Text(item?.title ?? "")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
            }
        }
    }
}
