import SwiftUI

struct ItemDetailPageView: View {
    @Environment(DatabaseService.self) var db
    @Environment(AIService.self) var ai
    @AppStorage("currentUserId") private var currentUserId = ""
    @AppStorage("aiProvider") private var aiProviderRaw = "none"
    let item: WatchItem
    var onBack: () -> Void
    var onNavigateToItem: ((WatchItem) -> Void)?

    @State private var ratings: [Rating] = []
    @State private var myScore: Double = 0
    @State private var myComment = ""
    @State private var isEditing = false
    @State private var showDeleteConfirm = false
    @State private var showDeleteFinalConfirm = false
    @State private var replyDrafts: [UUID: String] = [:]
    @State private var showEditItem = false
    @State private var isRefreshingMetadata = false
    @State private var metadataMessage: String?
    @State private var showTrailerModal = false
    @State private var comments: [ItemComment] = []
    @State private var newCommentDraft = ""
    @State private var showReviewComposer = false
    @State private var expandedReviewIds: Set<UUID> = []
    @State private var isLoadingData = true
    @State private var commentReplyDrafts: [UUID: String] = [:]
    @State private var openCommentReplyBoxes: Set<UUID> = []
    @State private var isCommentsSectionExpanded = true
    @State private var isOtherReviewsExpanded = false
    @State private var commentToDelete: ItemComment?
    @State private var showDeleteCommentConfirm = false
    @State private var expandedCommentTextIds: Set<UUID> = []
    @State private var showAllComments = false
    @State private var reviewFeedback: String?
    @State private var relatedItems: [WatchItem] = []
    @State private var recentlyAccessedItems: [WatchItem] = []
    @State private var itemSeasons: [ItemSeason] = []
    @State private var expandedSeasonIds: Set<UUID> = []
    @State private var seasonTrailerURL: String?
    @State private var showSeasonRanking = false
    @State private var episodesBySeason: [UUID: [ItemEpisode]] = [:]
    @State private var isLoadingEpisodes: [UUID: Bool] = [:]
    @State private var isFetchingEpisodesFromAI: [UUID: Bool] = [:]
    @State private var episodeFetchProgress: [UUID: String] = [:]
    @State private var episodeFetchTasks: [UUID: Task<Void, Never>] = [:]
    @State private var selectedEpisodeForDetail: ItemEpisode?
    @State private var selectedSeasonForDetail: ItemSeason?
    @State private var selectedSeasonForCompletion: ItemSeason?
    @State private var selectedSeasonCompletionMode: SeasonCompletionWizardView.CompletionMode = .finishNow
    @State private var selectedSeasonReviewMode: SeasonCompletionWizardView.ReviewMode = .skip
    @State private var episodeAvgRating: (avg: Double, count: Int)?
    @State private var toastMessage: String?
    @State private var aiRefreshNote = ""

    private var myRating: Rating? {
        guard let uid = UUID(uuidString: currentUserId) else { return nil }
        return ratings.first { $0.userId == uid }
    }

    private var partnerRatings: [Rating] {
        guard let uid = UUID(uuidString: currentUserId) else { return ratings }
        return ratings.filter { $0.userId != uid }
    }

    private var allRatingsSorted: [Rating] {
        ratings.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var liveItem: WatchItem {
        db.catalogItems.first { $0.id == item.id } ?? item
    }

    private var currentUserUUID: UUID? {
        UUID(uuidString: currentUserId)
    }

    private var aiEnabled: Bool {
        aiProviderRaw != AIProvider.none.rawValue
    }

    private var visibleComments: [ItemComment] {
        if showAllComments || comments.count <= 2 {
            return comments
        }
        return Array(comments.prefix(2))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Hero header
                heroHeader

                // Content
                HStack(alignment: .top, spacing: 32) {
                    // Left column — main info
                    VStack(alignment: .leading, spacing: 24) {
                        metaInfo
                        externalMetadataSection
                        detailActionsSection
                        watchStatusSection

                        if let overview = liveItem.overview, !overview.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Overview")
                                    .font(.headline)
                                    .foregroundStyle(SVTheme.textPrimary)
                                Text(overview)
                                    .font(.body)
                                    .foregroundStyle(SVTheme.textSecondary)
                                    .lineSpacing(4)
                            }
                        }

                        if !itemSeasons.isEmpty {
                            seasonsSection
                        }

                        Divider().overlay(SVTheme.border)

                        myRatingSection
                        commentsSection

                        if !relatedItems.isEmpty {
                            relatedItemsSection
                        }

                        if !recentlyAccessedItems.isEmpty {
                            recentlyAccessedSection
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Right column — reviews
                    reviewsColumn
                }
                .padding(32)

                Spacer(minLength: 24)
            }
        }
        .background(SVTheme.background)
        .task {
            if let uid = UUID(uuidString: currentUserId) {
                try? await db.trackItemAccess(userId: uid, itemId: item.id)
            }
            await loadData()
        }
        .alert("Delete Item", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Continue", role: .destructive) {
                showDeleteFinalConfirm = true
            }
        } message: {
            Text("You are about to delete \"\(liveItem.title)\".")
        }
        .alert("Final Confirmation", isPresented: $showDeleteFinalConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete Permanently", role: .destructive) {
                Task {
                    try? await db.deleteItem(id: item.id)
                    onBack()
                }
            }
        } message: {
            Text("This action cannot be undone. All ratings and comments for this item will be removed.")
        }
        .alert("Delete Comment", isPresented: $showDeleteCommentConfirm) {
            Button("Cancel", role: .cancel) {
                commentToDelete = nil
            }
            Button("Delete", role: .destructive) {
                Task { await deleteSelectedComment() }
            }
        } message: {
            Text("This will remove your comment and its replies.")
        }
        .sheet(isPresented: $showEditItem) {
            EditItemDetailsView(item: liveItem) { updated in
                Task {
                    try? await db.updateItem(
                        id: updated.id,
                        title: updated.title,
                        category: updated.category,
                        genre: updated.genre,
                        trailerURL: updated.trailerURL,
                        imageURL: updated.imageURL,
                        year: updated.year,
                        overview: updated.overview,
                        imdbRating: updated.imdbRating,
                        rottenTomatoesScore: updated.rottenTomatoesScore,
                        availablePlatforms: updated.availablePlatforms
                    )
                }
            }
        }
        .sheet(item: $selectedSeasonForCompletion, onDismiss: {
            Task { await loadData() }
        }) { season in
            SeasonCompletionWizardView(
                season: season,
                itemTitle: liveItem.title,
                preferredCompletionMode: selectedSeasonCompletionMode,
                preferredReviewMode: selectedSeasonReviewMode,
                onCompleted: {
                    showToast("Season updated")
                    Task { await loadData() }
                }
            )
            .environment(db)
        }
        .overlay {
            if showTrailerModal, let trailerURL = liveItem.trailerURL, !trailerURL.isEmpty {
                TrailerModalView(urlString: trailerURL, title: liveItem.title) {
                    showTrailerModal = false
                }
                .transition(.opacity)
            }
            if let seasonTrailer = seasonTrailerURL {
                TrailerModalView(urlString: seasonTrailer, title: liveItem.title) {
                    seasonTrailerURL = nil
                }
                .transition(.opacity)
            }
        }
        .overlay {
            if let episode = selectedEpisodeForDetail {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { dismissEpisodeDetail() }

                    let season = selectedSeasonForDetail ?? itemSeasons.first { $0.id == episode.seasonId }
                    if let season {
                        EpisodeDetailView(episode: episode, season: season, itemTitle: liveItem.title, onAction: { message in
                            showToast(message)
                        })
                        .environment(db)
                        .frame(width: 860, height: 620)
                        .background(SVTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.5), radius: 20)
                    }
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let message = toastMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(SVTheme.success)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(SVTheme.textPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .background(SVTheme.surface.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.3), radius: 8)
                .padding(20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: toastMessage != nil)
    }

    private func dismissEpisodeDetail() {
        let seasonToRefresh = selectedSeasonForDetail
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedEpisodeForDetail = nil
            selectedSeasonForDetail = nil
        }
        guard let seasonToRefresh else { return }
        Task {
            episodesBySeason[seasonToRefresh.id] = (try? await db.fetchEpisodes(for: seasonToRefresh.id)) ?? []
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toastMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { toastMessage = nil }
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        ZStack(alignment: .bottomLeading) {
            if let urlStr = liveItem.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                            .frame(height: 320).clipped()
                    } else {
                        heroPlaceholder
                    }
                }
                .allowsHitTesting(false)
            } else {
                heroPlaceholder
            }

            LinearGradient(
                colors: [.clear, SVTheme.background.opacity(0.6), SVTheme.background],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 8) {
                // Back button
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                HStack(spacing: 8) {
                    // Category badge
                    HStack(spacing: 6) {
                        Image(systemName: SVTheme.categoryIcon(liveItem.category))
                        Text(SVTheme.categoryLabel(liveItem.category))
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SVTheme.categoryColor(liveItem.category))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    // Added by badge
                    if let addedByName = liveItem.addedByName {
                        HStack(spacing: 4) {
                            Image(systemName: "person.fill")
                            Text("Added by \(addedByName)")
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.2))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    if let trailerURL = liveItem.trailerURL, !trailerURL.isEmpty {
                        Button {
                            showTrailerModal = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.rectangle.fill")
                                Text("Watch Trailer")
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(SVTheme.accent.opacity(0.85))
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help(trailerURL)
                    }
                }

                Text(liveItem.title)
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
            .padding(32)
        }
        .frame(height: 320)
        .clipped()
    }

    private var heroPlaceholder: some View {
        LinearGradient(
            colors: [SVTheme.categoryColor(liveItem.category).opacity(0.4), SVTheme.background],
            startPoint: .topTrailing, endPoint: .bottomLeading
        )
        .frame(height: 320)
    }

    // MARK: - Meta Info

    private var metaInfo: some View {
        HStack(spacing: 16) {
            if let year = liveItem.year {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .foregroundStyle(SVTheme.textMuted)
                    Text(String(year))
                        .foregroundStyle(SVTheme.textSecondary)
                }
                .font(.subheadline)
            }

            if let genre = liveItem.genre, !genre.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "tag")
                        .foregroundStyle(SVTheme.textMuted)
                    Text(genre)
                        .foregroundStyle(SVTheme.textSecondary)
                }
                .font(.subheadline)
            }

            if liveItem.avgRating > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(SVTheme.star)
                    Text(String(format: "%.1f", liveItem.avgRating))
                        .font(.subheadline.bold())
                        .foregroundStyle(SVTheme.textPrimary)
                    Text("(\(liveItem.ratingCount) \(liveItem.ratingCount == 1 ? "rating" : "ratings"))")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                }
            }

            if liveItem.isWatched {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(SVTheme.success)
                    Text("Watched")
                        .foregroundStyle(SVTheme.success)
                }
                .font(.subheadline)
            }
        }
    }

    private var externalMetadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if liveItem.imdbRating != nil || liveItem.rottenTomatoesScore != nil {
                HStack(spacing: 10) {
                    if let imdbRating = liveItem.imdbRating {
                        HStack(spacing: 6) {
                            Image(systemName: "star.circle.fill")
                                .foregroundStyle(.yellow)
                            Text("IMDb \(String(format: "%.1f", imdbRating))/10")
                                .font(.subheadline.bold())
                                .foregroundStyle(SVTheme.textPrimary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(SVTheme.card)
                        .clipShape(Capsule())
                    }

                    if let rottenTomatoesScore = liveItem.rottenTomatoesScore {
                        HStack(spacing: 6) {
                            Image(systemName: "chart.bar.fill")
                                .foregroundStyle(.red)
                            Text("Tomatoes \(rottenTomatoesScore)%")
                                .font(.subheadline.bold())
                                .foregroundStyle(SVTheme.textPrimary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(SVTheme.card)
                        .clipShape(Capsule())
                    }
                }
            }

            if !liveItem.availablePlatforms.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Available On")
                        .font(.headline)
                        .foregroundStyle(SVTheme.textPrimary)
                    PlatformBadgeRow(platforms: liveItem.availablePlatforms)
                }
            }
        }
    }

    // MARK: - Detail Actions

    private var detailActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await refreshMetadataWithAI() }
                } label: {
                    HStack(spacing: 6) {
                        if isRefreshingMetadata {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("Refresh with AI")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(SVTheme.accent)
                .disabled(isRefreshingMetadata || !aiEnabled)

                Button {
                    showEditItem = true
                } label: {
                    Label("Edit details", systemImage: "pencil")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete Item", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }

            if aiEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI Note (optional)")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textSecondary)
                    TextField("e.g. Apple TV+, 2024 series, remake not original...", text: $aiRefreshNote, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...3)
                }
            }

            if !aiEnabled {
                Text("Enable AI in Settings to refresh metadata.")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            } else if isRefreshingMetadata, let progress = ai.progressMessage {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(progress)
                }
                .font(.caption)
                .foregroundStyle(SVTheme.accent)
            } else if let metadataMessage {
                Text(metadataMessage)
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            }

            if let error = ai.lastError, aiEnabled {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Watch Status

    private var watchStatusSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Watch Status")
                    .font(.headline)
                    .foregroundStyle(SVTheme.textPrimary)
                if liveItem.isWatched, let watchedAt = liveItem.watchedAt {
                    Text("Watched on \(watchedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                }
            }

            Spacer()

            Button {
                Task { try? await db.toggleItemWatched(itemId: item.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: liveItem.isWatched ? "checkmark.circle.fill" : "circle")
                    Text(liveItem.isWatched ? "Watched" : "Mark as Watched")
                }
                .font(.subheadline.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(liveItem.isWatched ? SVTheme.success : SVTheme.card)
        }
        .padding(16)
        .background(SVTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - My Rating

    private var myRatingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Rating")
                .font(.headline)
                .foregroundStyle(SVTheme.textPrimary)

            if isLoadingData {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                }
                .padding(14)
            } else if let existing = myRating, !isEditing {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Score")
                                .font(.caption)
                                .foregroundStyle(SVTheme.textMuted)
                            HStack(spacing: 10) {
                                ScoreBadge(score: existing.score, size: .title3)
                                RatingStarsView(score: existing.score)
                            }
                        }
                        Spacer()
                        Button("Edit") {
                            myScore = existing.score
                            myComment = existing.comment ?? ""
                            isEditing = true
                        }
                        .buttonStyle(.bordered)
                    }

                    if let comment = existing.comment, !comment.isEmpty {
                        Divider().overlay(SVTheme.border)
                        Text(comment)
                            .font(.body)
                            .foregroundStyle(SVTheme.textSecondary)
                            .lineSpacing(3)
                    }
                }
                .padding(14)
                .background(
                    LinearGradient(
                        colors: [SVTheme.card, SVTheme.surface],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if !showReviewComposer && !isEditing {
                Button {
                    showReviewComposer = true
                    isEditing = true
                } label: {
                    Label("Write your review", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            } else {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Score")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                        HStack(spacing: 12) {
                            Slider(value: $myScore, in: 0...10, step: 0.1)
                                .tint(SVTheme.accent)
                            ScoreBadge(score: myScore, size: .subheadline)
                        }
                        RatingStarsView(score: myScore)
                    }
                    .padding(14)
                    .background(
                        LinearGradient(
                            colors: [SVTheme.card, SVTheme.surface],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Review note (optional)")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                        TextEditor(text: $myComment)
                            .font(.body)
                            .frame(height: 110)
                            .padding(6)
                            .background(SVTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        HStack {
                            Button {
                                NSApp.orderFrontCharacterPalette(nil)
                            } label: {
                                Image(systemName: "face.smiling")
                                    .font(.caption)
                                    .foregroundStyle(SVTheme.textMuted)
                            }
                            .buttonStyle(.plain)
                            .help("Insert emoji")
                            Spacer()
                        }
                    }

                    HStack {
                        if isEditing {
                            Button("Cancel") {
                                myComment = myRating?.comment ?? ""
                                showReviewComposer = false
                                isEditing = false
                            }
                                .buttonStyle(.bordered)
                        }
                        Spacer()
                        Button("Save Review") {
                            Task {
                                guard let uid = UUID(uuidString: currentUserId) else {
                                    reviewFeedback = "Select a user first to post your review."
                                    isEditing = false
                                    return
                                }
                                let trimmedComment = myComment.trimmingCharacters(in: .whitespacesAndNewlines)
                                do {
                                    try await db.rateItem(
                                        itemId: item.id, userId: uid,
                                        score: myScore, comment: trimmedComment.isEmpty ? nil : trimmedComment
                                    )
                                    showReviewComposer = false
                                    isEditing = false
                                    await loadData()
                                    reviewFeedback = myRating != nil ? "Review saved." : "Review saved but could not reload. Try refreshing."
                                } catch {
                                    reviewFeedback = "Could not save review. Please try again."
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SVTheme.accent)
                        .disabled(myScore == 0)
                    }
                }
                .padding(16)
                .background(SVTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if let reviewFeedback {
                Text(reviewFeedback)
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            }
        }
    }

    // MARK: - Reviews Column (right side)

    private var reviewsColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Reviews")
                    .font(.headline)
                    .foregroundStyle(SVTheme.textPrimary)

                if let mine = myRating, !isEditing, !showReviewComposer {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(SVTheme.success)
                        Text("Your review synced")
                            .font(.caption.bold())
                            .foregroundStyle(SVTheme.textSecondary)
                        Text("· \(mine.updatedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(SVTheme.textMuted)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(SVTheme.success.opacity(0.12))
                    .clipShape(Capsule())
                }
            }

            myReviewCard

            otherReviewsSection
        }
        .frame(width: 300)
    }

    @ViewBuilder
    private var myReviewCard: some View {
        if isEditing || showReviewComposer {
            reviewCardContent(
                userName: myRating?.userName ?? "You",
                score: myScore,
                comment: myComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : myComment,
                badgeLabel: "Preview",
                badgeColor: SVTheme.anime,
                borderDashed: true
            )
            .animation(.easeInOut(duration: 0.2), value: myScore)
            .animation(.easeInOut(duration: 0.2), value: myComment)
        } else if let mine = myRating {
            reviewCardContent(
                userName: mine.userName ?? "You",
                score: mine.score,
                comment: mine.comment,
                badgeLabel: "You",
                badgeColor: SVTheme.accent,
                borderDashed: false
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "star.bubble")
                    .font(.system(size: 28))
                    .foregroundStyle(SVTheme.textMuted)
                Text("You haven't reviewed this yet")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                Text("Use \"Your Rating\" on the left to write a review")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(SVTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func reviewCardContent(userName: String, score: Double, comment: String?, badgeLabel: String, badgeColor: Color, borderDashed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(SVTheme.accent.opacity(0.25))
                    Text(String(userName.prefix(1)).uppercased())
                        .font(.headline.bold())
                        .foregroundStyle(SVTheme.accent)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(userName)
                            .font(.subheadline.bold())
                            .foregroundStyle(SVTheme.textPrimary)
                        Text(badgeLabel)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badgeColor.opacity(0.2))
                            .foregroundStyle(badgeColor)
                            .clipShape(Capsule())
                    }
                    RatingStarsView(score: score)
                }

                Spacer()
                ScoreBadge(score: score, size: .subheadline)
            }

            if let note = comment, !note.isEmpty {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(SVTheme.textSecondary)
                    .lineSpacing(3)
                    .padding(.leading, 46)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(SVTheme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            badgeColor.opacity(0.3),
                            style: StrokeStyle(lineWidth: 1, dash: borderDashed ? [6, 4] : [])
                        )
                )
        )
    }

    @ViewBuilder
    private var otherReviewsSection: some View {
        if !partnerRatings.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isOtherReviewsExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text("Other Reviews (\(partnerRatings.count))")
                            .font(.subheadline.bold())
                            .foregroundStyle(SVTheme.textPrimary)
                        Spacer()
                        Image(systemName: isOtherReviewsExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.bold())
                            .foregroundStyle(SVTheme.textMuted)
                    }
                }
                .buttonStyle(.plain)

                if isOtherReviewsExpanded {
                    ForEach(partnerRatings.sorted { $0.updatedAt > $1.updatedAt }) { rating in
                        reviewAccordionCard(rating)
                    }
                }
            }
        } else if myRating != nil {
            Text("No other reviews yet")
                .font(.caption)
                .foregroundStyle(SVTheme.textMuted)
        }
    }

    private func commentBox(text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(SVTheme.textSecondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SVTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Comments (\(comments.count))")
                    .font(.headline)
                    .foregroundStyle(SVTheme.textPrimary)
                Spacer()
                Button {
                    isCommentsSectionExpanded.toggle()
                } label: {
                    Label(
                        isCommentsSectionExpanded ? "Hide" : "Show",
                        systemImage: isCommentsSectionExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption.bold())
                }
                .buttonStyle(.plain)
                .foregroundStyle(SVTheme.textMuted)
            }

            if isCommentsSectionExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add comment")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)

                    TextEditor(text: $newCommentDraft)
                        .font(.body)
                        .frame(height: 90)
                        .padding(6)
                        .background(SVTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    HStack {
                        Button {
                            NSApp.orderFrontCharacterPalette(nil)
                        } label: {
                            Image(systemName: "face.smiling")
                                .font(.body)
                                .foregroundStyle(SVTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                        .help("Insert emoji")

                        Spacer()
                        Button("Post Comment") {
                            Task { await submitItemComment() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SVTheme.accent)
                        .disabled(newCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if comments.isEmpty {
                            Text("No comments yet")
                                .font(.caption)
                                .foregroundStyle(SVTheme.textMuted)
                        } else {
                            ForEach(visibleComments) { comment in
                                commentCard(comment)
                            }
                            if comments.count > 2 {
                                Button(showAllComments ? "See less comments" : "See more comments (\(comments.count - 2))") {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showAllComments.toggle()
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.caption.bold())
                                .foregroundStyle(SVTheme.accent)
                                .padding(.horizontal, 4)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 420)
                .padding(10)
                .background(SVTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func commentCard(_ comment: ItemComment) -> some View {
        let isExpanded = expandedCommentTextIds.contains(comment.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Text(comment.userName ?? "Unknown")
                        .font(.caption.bold())
                        .foregroundStyle(SVTheme.textPrimary)
                    if comment.userId == currentUserUUID {
                        Text("You")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(SVTheme.accent.opacity(0.2))
                            .foregroundStyle(SVTheme.accent)
                            .clipShape(Capsule())
                    }
                }
                Spacer()
                Text(comment.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(SVTheme.textMuted)
                if comment.userId == currentUserUUID {
                    Button(role: .destructive) {
                        commentToDelete = comment
                        showDeleteCommentConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(0.9))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(comment.message)
                    .font(.body)
                    .foregroundStyle(SVTheme.textSecondary)
                    .lineLimit(isExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if comment.message.count > 120 {
                    Button(isExpanded ? "See less" : "See more") {
                        if isExpanded {
                            expandedCommentTextIds.remove(comment.id)
                        } else {
                            expandedCommentTextIds.insert(comment.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(SVTheme.accent)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SVTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Button {
                    Task { await toggleCommentLike(comment) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: comment.isLikedByCurrentUser ? "hand.thumbsup.fill" : "hand.thumbsup")
                        Text("\(comment.likeCount)")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(comment.isLikedByCurrentUser ? SVTheme.accent : SVTheme.textMuted)

                Button {
                    if openCommentReplyBoxes.contains(comment.id) {
                        openCommentReplyBoxes.remove(comment.id)
                    } else {
                        openCommentReplyBoxes.insert(comment.id)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowshape.turn.up.left")
                        Text("Reply")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(SVTheme.textMuted)
                .lineLimit(1)

                Spacer()

                Menu {
                    ForEach(["👍", "❤️", "🔥", "😂", "😮", "😢"], id: \.self) { emoji in
                        let current = comment.reactions.first { $0.emoji == emoji }
                        Button {
                            Task { await toggleCommentReaction(comment, emoji: emoji) }
                        } label: {
                            HStack {
                                Text(emoji)
                                if let count = current?.count, count > 0 {
                                    Text("\(count)")
                                        .foregroundStyle(SVTheme.textMuted)
                                }
                            }
                        }
                    }
                } label: {
                    Label("React", systemImage: "face.smiling")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            let activeReactions = comment.reactions
                .filter { $0.count > 0 }
                .sorted { $0.emoji < $1.emoji }
            if !activeReactions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(activeReactions) { reaction in
                            HStack(spacing: 4) {
                                Text(reaction.emoji)
                                Text("\(reaction.count)")
                                    .font(.caption2.bold())
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(reaction.isMine ? SVTheme.accent.opacity(0.2) : SVTheme.surface)
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            if !comment.replies.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(comment.replies) { reply in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption2)
                                .foregroundStyle(SVTheme.textMuted)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(reply.userName ?? "Unknown")
                                        .font(.caption.bold())
                                        .foregroundStyle(SVTheme.textPrimary)
                                    if reply.userId == currentUserUUID {
                                        Text("You")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(SVTheme.accent.opacity(0.2))
                                            .foregroundStyle(SVTheme.accent)
                                            .clipShape(Capsule())
                                    }
                                    Spacer(minLength: 0)
                                }
                                Text(reply.message)
                                    .font(.caption)
                                    .foregroundStyle(SVTheme.textSecondary)
                                Text(reply.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(SVTheme.textMuted)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SVTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.leading, 8)
            }

            if openCommentReplyBoxes.contains(comment.id) {
                HStack(spacing: 8) {
                    TextField("Reply to \(comment.userName ?? "comment")...", text: Binding(
                        get: { commentReplyDrafts[comment.id] ?? "" },
                        set: { commentReplyDrafts[comment.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Button("Send") {
                        Task { await submitCommentReply(for: comment) }
                    }
                    .buttonStyle(.bordered)
                    .disabled((commentReplyDrafts[comment.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.leading, 8)
            }
        }
        .padding(10)
        .background(SVTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Reviews Card

    private func reviewAccordionCard(_ rating: Rating) -> some View {
        let isExpanded = expandedReviewIds.contains(rating.id)
        let relatedComments = comments.filter { $0.userId == rating.userId }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(SVTheme.accent.opacity(0.2))
                    Text(String((rating.userName ?? "?").prefix(1)).uppercased())
                        .font(.headline.bold())
                        .foregroundStyle(SVTheme.accent)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rating.userName ?? "Unknown")
                        .font(.subheadline.bold())
                        .foregroundStyle(SVTheme.textPrimary)

                    RatingStarsView(score: rating.score)
                }

                Spacer()

                ScoreBadge(score: rating.score, size: .subheadline)

                Button {
                    if isExpanded {
                        expandedReviewIds.remove(rating.id)
                    } else {
                        expandedReviewIds.insert(rating.id)
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(SVTheme.textMuted)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                if let reviewNote = rating.comment, !reviewNote.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Review")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                        commentBox(text: reviewNote)
                    }
                    .padding(.leading, 46)
                }

                if !relatedComments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Comments by \(rating.userName ?? "Unknown")")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                        ForEach(relatedComments) { comment in
                            commentBox(text: comment.message)
                        }
                    }
                    .padding(.leading, 46)
                }
            }

            HStack {
                Button {
                    Task { await toggleLike(for: rating) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: rating.isLikedByCurrentUser ? "hand.thumbsup.fill" : "hand.thumbsup")
                        Text("\(rating.likeCount)")
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(rating.isLikedByCurrentUser ? SVTheme.accent : SVTheme.textMuted)

                Spacer()
            }
            .padding(.leading, 46)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(rating.replies) { reply in
                    HStack(alignment: .top, spacing: 6) {
                        Text(reply.userName ?? "Unknown")
                            .font(.caption.bold())
                            .foregroundStyle(SVTheme.textPrimary)
                        Text(reply.message)
                            .font(.caption)
                            .foregroundStyle(SVTheme.textSecondary)
                    }
                }

                HStack(spacing: 8) {
                    TextField("Reply...", text: Binding(
                        get: { replyDrafts[rating.id] ?? "" },
                        set: { replyDrafts[rating.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Button("Send") {
                        Task { await addReply(for: rating) }
                    }
                    .buttonStyle(.bordered)
                    .disabled((replyDrafts[rating.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.leading, 46)
        }
        .padding(14)
        .background(SVTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Seasons

    private var seasonsSection: some View {
        let rankedSeasons: [ItemSeason] = showSeasonRanking
            ? itemSeasons.sorted { ($0.ranking ?? Int.max) < ($1.ranking ?? Int.max) }
            : itemSeasons

        return VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(SVTheme.border)

            HStack {
                Text("Seasons (\(itemSeasons.count))")
                    .font(.headline)
                    .foregroundStyle(SVTheme.textPrimary)

                if let epAvg = episodeAvgRating, epAvg.count > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(SVTheme.star)
                        Text(String(format: "%.1f", epAvg.avg))
                            .bold()
                        Text("episode avg")
                            .foregroundStyle(SVTheme.textMuted)
                        Text("(\(epAvg.count))")
                            .foregroundStyle(SVTheme.textMuted)
                    }
                    .font(.caption)
                }

                Spacer()

                if aiEnabled {
                    Button {
                        Task { await refreshSeasonsFromAI() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text("Refresh")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if itemSeasons.count > 1 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSeasonRanking.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showSeasonRanking ? "number" : "trophy")
                            Text(showSeasonRanking ? "Order" : "Ranking")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            LazyVStack(spacing: 8) {
                ForEach(rankedSeasons) { season in
                    seasonCard(season)
                }
            }
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }

    private func refreshSeasonsFromAI() async {
        guard let seasons = await ai.fetchSeasonInfo(
            title: liveItem.title,
            category: liveItem.category,
            hint: aiRefreshNote
        ) else { return }
        try? await db.createSeasons(itemId: liveItem.id, seasons: seasons)
        itemSeasons = (try? await db.ensureSeasonScaffold(for: liveItem)) ?? []
        metadataMessage = "Refreshing all seasons and episodes..."
        let addedEpisodes = await syncEpisodesFromAI(for: itemSeasons)
        itemSeasons = (try? await db.ensureSeasonScaffold(for: liveItem)) ?? []
        episodeAvgRating = try? await db.fetchEpisodeAverageRating(for: liveItem.id)
        metadataMessage = addedEpisodes > 0
            ? "Seasons refreshed and \(addedEpisodes) episodes synced from AI."
            : "Seasons refreshed. Episodes were already up to date."
    }

    private func seasonCard(_ season: ItemSeason) -> some View {
        let isExpanded = expandedSeasonIds.contains(season.id)
        let episodes = episodesBySeason[season.id] ?? []
        let selectedEpisodes = episodes.filter(\.isSelected)
        let watchedSelected = selectedEpisodes.filter(\.isWatched).count

        return VStack(alignment: .leading, spacing: 0) {
            // Header row (always visible)
            HStack(spacing: 12) {
                // Ranking badge
                if showSeasonRanking {
                    Menu {
                        ForEach(1...itemSeasons.count, id: \.self) { rank in
                            Button("#\(rank)") {
                                Task {
                                    try? await db.updateSeasonRanking(seasonId: season.id, ranking: rank)
                                    itemSeasons = (try? await db.fetchSeasons(for: liveItem.id)) ?? []
                                }
                            }
                        }
                        Button("Clear") {
                            Task {
                                try? await db.updateSeasonRanking(seasonId: season.id, ranking: nil)
                                itemSeasons = (try? await db.fetchSeasons(for: liveItem.id)) ?? []
                            }
                        }
                    } label: {
                        Text(season.ranking != nil ? "#\(season.ranking!)" : "-")
                            .font(.caption.bold().monospaced())
                            .frame(width: 28, height: 28)
                            .background(rankingColor(season.ranking))
                            .foregroundStyle(.white)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                // Season poster thumbnail
                ZStack(alignment: .topTrailing) {
                    seasonThumbnail(season)
                        .frame(width: 50, height: 70)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    if season.isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(SVTheme.success)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                            .padding(3)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let ranking = season.ranking, !showSeasonRanking {
                            Text("#\(ranking)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(rankingColor(ranking).opacity(0.2))
                                .foregroundStyle(rankingColor(ranking))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        Text("Season \(season.seasonNumber)")
                            .font(.subheadline.bold())
                            .foregroundStyle(SVTheme.textPrimary)
                        if let name = season.name, !name.isEmpty {
                            Text("- \(name)")
                                .font(.subheadline)
                                .foregroundStyle(SVTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    HStack(spacing: 8) {
                        if let year = season.year {
                            Label(String(year), systemImage: "calendar")
                        }
                        if let eps = season.episodeCount {
                            Label("\(eps) episodes", systemImage: "play.rectangle")
                        }
                        if season.ratingCount > 0 {
                            Label(String(format: "%.1f · %d", season.avgRating, season.ratingCount), systemImage: "star.fill")
                                .foregroundStyle(SVTheme.star)
                        }
                        if !episodes.isEmpty {
                            Text("\(watchedSelected)/\(selectedEpisodes.count)")
                                .foregroundStyle(SVTheme.accent)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
                }

                Spacer()

                // Episode batch menu
                if !episodes.isEmpty {
                    Menu {
                        Button("Mark all selected watched") {
                            Task {
                                try? await db.markAllEpisodesWatched(seasonId: season.id, watched: true)
                                episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
                                itemSeasons = (try? await db.fetchSeasons(for: liveItem.id)) ?? []
                            }
                        }
                        Button("Mark all unwatched") {
                            Task {
                                try? await db.markAllEpisodesWatched(seasonId: season.id, watched: false)
                                episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
                                itemSeasons = (try? await db.fetchSeasons(for: liveItem.id)) ?? []
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    Task {
                        try? await db.toggleSeasonWatched(seasonId: season.id)
                        itemSeasons = (try? await db.fetchSeasons(for: liveItem.id)) ?? []
                        episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
                    }
                } label: {
                    Image(systemName: season.isWatched ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(season.isWatched ? SVTheme.success : SVTheme.textMuted)
                }
                .buttonStyle(.plain)
                .help(season.isWatched ? "Mark as unwatched" : "Mark as watched")

                if let trailerURL = season.trailerURL, !trailerURL.isEmpty {
                    Button {
                        seasonTrailerURL = trailerURL
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(SVTheme.accent.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Watch trailer")
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.bold())
                    .foregroundStyle(SVTheme.textMuted)
            }
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded {
                    expandedSeasonIds.remove(season.id)
                    episodesBySeason[season.id] = nil
                } else {
                    for otherSeasonId in expandedSeasonIds where otherSeasonId != season.id {
                        episodesBySeason[otherSeasonId] = nil
                    }
                    expandedSeasonIds = [season.id]
                    if episodesBySeason[season.id] == nil {
                        Task { await loadEpisodes(for: season) }
                    }
                }
            }

            // Expanded detail
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().overlay(SVTheme.border)

                    HStack(alignment: .top, spacing: 14) {
                        // Larger poster
                        if season.imageURL != nil {
                            seasonThumbnail(season)
                                .frame(width: 100, height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            if let overview = season.overview, !overview.isEmpty {
                                Text(overview)
                                    .font(.callout)
                                    .foregroundStyle(SVTheme.textSecondary)
                                    .lineSpacing(3)
                            }

                            HStack(spacing: 10) {
                                if let year = season.year {
                                    Label(String(year), systemImage: "calendar")
                                }
                                if let eps = season.episodeCount {
                                    Label("\(eps) episodes", systemImage: "play.rectangle")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)

                            if season.isWatched {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(SVTheme.success)
                                    Text("Watched")
                                        .foregroundStyle(SVTheme.success)
                                    if let watchedAt = season.watchedAt {
                                        Text("on \(watchedAt.formatted(date: .abbreviated, time: .omitted))")
                                            .foregroundStyle(SVTheme.textMuted)
                                    }
                                }
                                .font(.caption)
                            }

                            if let trailerURL = season.trailerURL, !trailerURL.isEmpty {
                                Button {
                                    seasonTrailerURL = trailerURL
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "play.rectangle.fill")
                                        Text("Watch Trailer")
                                    }
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(SVTheme.accent.opacity(0.85))
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                            }

                            HStack(spacing: 8) {
                                Button {
                                    selectedSeasonCompletionMode = .finishNow
                                    selectedSeasonReviewMode = .skip
                                    selectedSeasonForCompletion = season
                                } label: {
                                    Label("Close Progress", systemImage: "party.popper")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(SVTheme.success)

                                Button {
                                    selectedSeasonCompletionMode = .keepProgress
                                    selectedSeasonReviewMode = .episodes
                                    selectedSeasonForCompletion = season
                                } label: {
                                    Label("Episode Gallery", systemImage: "square.grid.3x2")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    // Episodes section
                    episodesSection(for: season)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(SVTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func rankingColor(_ ranking: Int?) -> Color {
        switch ranking {
        case 1: return .yellow
        case 2: return .gray
        case 3: return .orange
        default: return SVTheme.textMuted
        }
    }

    @ViewBuilder
    private func episodesSection(for season: ItemSeason) -> some View {
        let episodes = episodesBySeason[season.id] ?? []
        let isFetching = isFetchingEpisodesFromAI[season.id] == true
        let progress = episodeFetchProgress[season.id]

        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(SVTheme.border)

            HStack {
                Text("Episodes")
                    .font(.caption.bold())
                    .foregroundStyle(SVTheme.textPrimary)

                if !episodes.isEmpty {
                    let selected = episodes.filter(\.isSelected)
                    let watched = selected.filter(\.isWatched).count
                    Text("\(watched)/\(selected.count)")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(SVTheme.accent.opacity(0.15))
                        .foregroundStyle(SVTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Spacer()

                if aiEnabled && !isFetching {
                    Button {
                        let task = Task { await fetchEpisodesFromAI(for: season) }
                        episodeFetchTasks[season.id] = task
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text(episodes.isEmpty ? "Fetch Episodes" : "Fetch Missing")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // Fetch progress banner
            if isFetching, let progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(SVTheme.textSecondary)
                    Spacer()
                    Button {
                        episodeFetchTasks[season.id]?.cancel()
                        episodeFetchTasks[season.id] = nil
                        isFetchingEpisodesFromAI[season.id] = false
                        episodeFetchProgress[season.id] = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(SVTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel fetch")
                }
                .padding(8)
                .background(SVTheme.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if isLoadingEpisodes[season.id] == true {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                }
            } else if episodes.isEmpty && !isFetching {
                Text("No episodes loaded yet")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(episodes) { episode in
                        episodeRow(episode, in: season)
                    }
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
        }
    }

    private func episodeRow(_ episode: ItemEpisode, in season: ItemSeason) -> some View {
        let hasInfo = episode.title != nil || episode.overview != nil

        return HStack(spacing: 10) {
            // Selection toggle
            Button {
                Task {
                    try? await db.toggleEpisodeSelected(episodeId: episode.id)
                    episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
                }
            } label: {
                Image(systemName: episode.isSelected ? "checkmark.square.fill" : "square")
                    .font(.caption)
                    .foregroundStyle(episode.isSelected ? SVTheme.accent : SVTheme.textMuted)
            }
            .buttonStyle(.plain)
            .help(episode.isSelected ? "Deselect episode" : "Select episode")

            Text("E\(episode.episodeNumber)")
                .font(.caption.bold().monospaced())
                .foregroundStyle(SVTheme.textMuted)
                .frame(width: 28, alignment: .leading)

            // Episode info (clickable area — opens detail)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let title = episode.title, !title.isEmpty {
                        Text(title)
                            .font(.caption.bold())
                            .foregroundStyle(episode.isSelected ? SVTheme.textPrimary : SVTheme.textMuted)
                            .lineLimit(1)
                    }
                    if episode.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(SVTheme.star)
                    }
                }
                HStack(spacing: 6) {
                    if let airDate = episode.airDate, !airDate.isEmpty {
                        Text(airDate)
                    }
                    if let runtime = episode.runtimeMinutes {
                        Text("\(runtime)m")
                    }
                    if episode.ratingCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill").foregroundStyle(SVTheme.star)
                            Text(String(format: "%.1f", episode.avgRating))
                        }
                    }
                }
                .font(.caption2)
                .foregroundStyle(SVTheme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.25)) {
                    selectedSeasonForDetail = season
                    selectedEpisodeForDetail = episode
                }
            }

            Spacer()

            // Fetch individual episode info if missing
            if !hasInfo && aiEnabled {
                Button {
                    Task { await fetchSingleEpisodeFromAI(episode, in: season) }
                } label: {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(SVTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Fetch episode info")
            }

            // Favorite toggle
            Button {
                Task {
                    let wasFavorite = episode.isFavorite
                    try? await db.toggleEpisodeFavorite(episodeId: episode.id)
                    episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
                    let name = episode.title ?? "E\(episode.episodeNumber)"
                    showToast(wasFavorite ? "'\(name)' removed from favorites" : "'\(name)' added to favorites")
                }
            } label: {
                Image(systemName: episode.isFavorite ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(episode.isFavorite ? SVTheme.star : SVTheme.textMuted.opacity(0.5))
            }
            .buttonStyle(.plain)

            if episode.isSelected {
                Button {
                    Task {
                        try? await db.toggleEpisodeWatched(episodeId: episode.id)
                        episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
                        itemSeasons = (try? await db.fetchSeasons(for: liveItem.id)) ?? []
                    }
                } label: {
                    Image(systemName: episode.isWatched ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(episode.isWatched ? SVTheme.success : SVTheme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(episode.isWatched && episode.isSelected ? SVTheme.success.opacity(0.05) : Color.clear)
        )
        .opacity(episode.isSelected ? 1 : 0.5)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func loadEpisodes(for season: ItemSeason) async {
        isLoadingEpisodes[season.id] = true
        episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
        isLoadingEpisodes[season.id] = false
    }

    private func fetchEpisodesFromAI(for season: ItemSeason) async {
        isFetchingEpisodesFromAI[season.id] = true
        episodeFetchProgress[season.id] = "Asking AI for episode info..."

        defer {
            isFetchingEpisodesFromAI[season.id] = false
            episodeFetchProgress[season.id] = nil
            episodeFetchTasks[season.id] = nil
        }

        // Check for cancellation
        guard !Task.isCancelled else { return }

        guard let aiEpisodes = await ai.fetchEpisodeInfo(
            title: liveItem.title,
            category: liveItem.category,
            seasonNumber: season.seasonNumber,
            hint: aiRefreshNote,
            trackAsJob: true
        ) else {
            episodeFetchProgress[season.id] = "AI could not fetch episodes"
            try? await Task.sleep(for: .seconds(2))
            return
        }

        guard !Task.isCancelled else { return }

        // Filter out already existing episodes
        let existing = episodesBySeason[season.id] ?? []
        let existingNumbers = Set(existing.map(\.episodeNumber))
        let newEpisodes = aiEpisodes.filter { !existingNumbers.contains($0.episodeNumber) }

        if newEpisodes.isEmpty {
            episodeFetchProgress[season.id] = "All episodes already loaded"
            try? await Task.sleep(for: .seconds(1.5))
            return
        }

        episodeFetchProgress[season.id] = "Saving 0/\(newEpisodes.count) episodes..."

        // Insert one by one while keeping the UI refresh batched.
        for (index, ep) in newEpisodes.enumerated() {
            guard !Task.isCancelled else { return }

            episodeFetchProgress[season.id] = "Saving \(index + 1)/\(newEpisodes.count): \(ep.title ?? "E\(ep.episodeNumber)")..."

            _ = try? await db.createEpisode(
                seasonId: season.id, itemId: liveItem.id,
                episodeNumber: ep.episodeNumber,
                title: ep.title, overview: ep.overview,
                imageURL: nil, airDate: ep.airDate,
                runtimeMinutes: ep.runtimeMinutes
            )
        }

        // Sync season watched status (new episodes are unwatched → season may no longer be complete)
        try? await db.syncSeasonAndItemStatus(seasonId: season.id)
        try? await db.fetchCatalog()
        episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []

        episodeFetchProgress[season.id] = "Done! \(newEpisodes.count) episodes added"
        try? await Task.sleep(for: .seconds(1.5))
    }

    private func fetchSingleEpisodeFromAI(_ episode: ItemEpisode, in season: ItemSeason) async {
        guard let match = await ai.fetchSingleEpisodeInfo(
            title: liveItem.title,
            category: liveItem.category,
            seasonNumber: season.seasonNumber,
            episodeNumber: episode.episodeNumber,
            hint: aiRefreshNote
        ) else { return }

        _ = try? await db.createEpisode(
            seasonId: season.id, itemId: liveItem.id,
            episodeNumber: match.episodeNumber,
            title: match.title, overview: match.overview,
            imageURL: nil, airDate: match.airDate,
            runtimeMinutes: match.runtimeMinutes
        )
        episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
    }

    @ViewBuilder
    private func seasonThumbnail(_ season: ItemSeason) -> some View {
        if let urlStr = season.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else if case .failure = phase {
                    seasonPlaceholder(season)
                } else {
                    ZStack {
                        SVTheme.surface
                        ProgressView().controlSize(.small)
                    }
                }
            }
        } else {
            seasonPlaceholder(season)
        }
    }

    private func seasonPlaceholder(_ season: ItemSeason) -> some View {
        ZStack {
            LinearGradient(
                colors: [SVTheme.accent.opacity(0.3), SVTheme.surface],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Text("S\(season.seasonNumber)")
                .font(.subheadline.bold())
                .foregroundStyle(SVTheme.textMuted)
        }
    }

    // MARK: - Related Items

    private var relatedItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(SVTheme.border)

            Text("Related")
                .font(.headline)
                .foregroundStyle(SVTheme.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(relatedItems) { related in
                        relatedItemCard(related)
                    }
                }
            }
        }
    }

    // MARK: - Recently Accessed

    private var recentlyAccessedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(SVTheme.border)

            Text("Recently Viewed")
                .font(.headline)
                .foregroundStyle(SVTheme.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(recentlyAccessedItems) { recentItem in
                        relatedItemCard(recentItem)
                    }
                }
            }
        }
    }

    private func relatedItemCard(_ item: WatchItem) -> some View {
        Button {
            onNavigateToItem?(item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let urlStr = item.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                relatedPlaceholder(item)
                            }
                        }
                    } else {
                        relatedPlaceholder(item)
                    }
                }
                .frame(width: 120, height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(item.title)
                    .font(.caption.bold())
                    .foregroundStyle(SVTheme.textPrimary)
                    .lineLimit(2)
                    .frame(width: 120, alignment: .leading)

                HStack(spacing: 4) {
                    Text(SVTheme.categoryLabel(item.category))
                        .font(.caption2)
                        .foregroundStyle(SVTheme.categoryColor(item.category))
                    if let year = item.year {
                        Text(String(year))
                            .font(.caption2)
                            .foregroundStyle(SVTheme.textMuted)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func relatedPlaceholder(_ item: WatchItem) -> some View {
        ZStack {
            SVTheme.categoryColor(item.category).opacity(0.3)
            Image(systemName: SVTheme.categoryIcon(item.category))
                .font(.title3)
                .foregroundStyle(SVTheme.textMuted)
        }
    }

    // MARK: - Data

    private func loadData() async {
        do {
            ratings = try await db.fetchRatings(for: item.id, currentUserId: currentUserUUID)
        } catch {
            if ratings.isEmpty {
                reviewFeedback = "Could not load ratings: \(error.localizedDescription)"
            }
        }
        comments = (try? await db.fetchItemComments(for: item.id, currentUserId: currentUserUUID)) ?? []
        relatedItems = (try? await db.fetchRelatedItems(for: liveItem)) ?? []
        recentlyAccessedItems = (try? await db.fetchRecentlyAccessed(
            userId: currentUserUUID ?? UUID(),
            excludeItemId: liveItem.id
        )) ?? []
        if ItemCategory.categoryHasSeasons(liveItem.category) {
            itemSeasons = (try? await db.ensureSeasonScaffold(for: liveItem)) ?? []
            episodeAvgRating = try? await db.fetchEpisodeAverageRating(for: liveItem.id)
        } else {
            itemSeasons = []
            episodeAvgRating = nil
        }
        // Only reset editing state if the user is NOT actively composing
        if !isEditing && !showReviewComposer {
            if let existing = myRating {
                myScore = existing.score
                myComment = existing.comment ?? ""
            } else {
                myScore = 0
                myComment = ""
            }
        }
        if comments.count <= 2 {
            showAllComments = true
        }
        isLoadingData = false
    }

    private func toggleLike(for rating: Rating) async {
        guard let uid = currentUserUUID else { return }
        try? await db.toggleRatingLike(ratingId: rating.id, userId: uid)
        await loadData()
    }

    private func addReply(for rating: Rating) async {
        guard let uid = currentUserUUID else { return }
        let draft = (replyDrafts[rating.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        try? await db.addRatingReply(ratingId: rating.id, userId: uid, message: draft)
        replyDrafts[rating.id] = ""
        await loadData()
    }

    private func refreshMetadataWithAI() async {
        guard aiEnabled else { return }
        withAnimation(.easeOut(duration: 0.3)) { isRefreshingMetadata = true }
        metadataMessage = nil
        defer { withAnimation(.easeOut(duration: 0.3)) { isRefreshingMetadata = false } }

        guard let result = await ai.autoFill(title: liveItem.title, category: liveItem.category, hint: aiRefreshNote) else {
            metadataMessage = "AI returned no data."
            return
        }

        let newImage = result.imageURL ?? liveItem.imageURL
        let newYear = result.year ?? liveItem.year
        let newOverview = result.overview ?? liveItem.overview
        let newTrailer = result.trailerURL ?? liveItem.trailerURL
        let newGenre = result.genre ?? liveItem.genre
        let newIMDbRating = result.imdbRating ?? liveItem.imdbRating
        let newRottenTomatoes = result.rottenTomatoesScore ?? liveItem.rottenTomatoesScore
        let newPlatforms = PlatformAvailability.merged(
            preferred: result.availablePlatforms,
            fallback: liveItem.availablePlatforms
        )

        try? await db.updateItem(
            id: liveItem.id,
            title: liveItem.title,
            category: liveItem.category,
            genre: newGenre,
            trailerURL: newTrailer,
            imageURL: newImage,
            year: newYear,
            overview: newOverview,
            imdbRating: newIMDbRating,
            rottenTomatoesScore: newRottenTomatoes,
            availablePlatforms: newPlatforms
        )

        // Save seasons if AI found any
        var seasonMsg = ""
        if ItemCategory.categoryHasSeasons(liveItem.category) {
            if let seasons = result.seasons, !seasons.isEmpty {
                try? await db.createSeasons(itemId: liveItem.id, seasons: seasons)
            }
            itemSeasons = (try? await db.ensureSeasonScaffold(for: liveItem)) ?? []
        }

        if !itemSeasons.isEmpty {
            metadataMessage = "Refreshing seasons and episodes from AI..."
            let addedEpisodes = await syncEpisodesFromAI(for: itemSeasons)
            itemSeasons = (try? await db.ensureSeasonScaffold(for: liveItem)) ?? []
            episodeAvgRating = try? await db.fetchEpisodeAverageRating(for: liveItem.id)
            // Re-fetch catalog so totalSeasons/watchedSeasons and watchStatus update
            try? await db.fetchCatalog()
            let savedSeasonCount = result.seasons?.count ?? itemSeasons.count
            seasonMsg = " (\(savedSeasonCount) seasons saved, \(addedEpisodes) episodes synced)"
        }

        metadataMessage = "Details refreshed from AI.\(seasonMsg)"
    }

    private func syncEpisodesFromAI(for seasons: [ItemSeason]) async -> Int {
        guard !seasons.isEmpty else { return 0 }

        var addedEpisodes = 0

        for (index, season) in seasons.enumerated() {
            metadataMessage = "Fetching episodes \(index + 1)/\(seasons.count): Season \(season.seasonNumber)..."

            guard let aiEpisodes = await ai.fetchEpisodeInfo(
                title: liveItem.title,
                category: liveItem.category,
                seasonNumber: season.seasonNumber,
                hint: aiRefreshNote
            ), !aiEpisodes.isEmpty else {
                continue
            }

            let existingEpisodes = (try? await db.fetchEpisodes(for: season.id)) ?? []
            let existingNumbers = Set(existingEpisodes.map(\.episodeNumber))
            let newEpisodes = aiEpisodes.filter { !existingNumbers.contains($0.episodeNumber) }

            if !newEpisodes.isEmpty {
                try? await db.createEpisodes(seasonId: season.id, itemId: liveItem.id, episodes: newEpisodes)
                try? await db.syncSeasonAndItemStatus(seasonId: season.id)
                addedEpisodes += newEpisodes.count
            }

            episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
        }

        try? await db.fetchCatalog()
        return addedEpisodes
    }

    private func submitItemComment() async {
        guard let uid = currentUserUUID else { return }
        let trimmed = newCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? await db.addItemComment(itemId: item.id, userId: uid, message: trimmed)
        newCommentDraft = ""
        await loadData()
    }

    private func toggleCommentLike(_ comment: ItemComment) async {
        guard let uid = currentUserUUID else { return }
        try? await db.toggleItemCommentLike(commentId: comment.id, userId: uid)
        await loadData()
    }

    private func toggleCommentReaction(_ comment: ItemComment, emoji: String) async {
        guard let uid = currentUserUUID else { return }
        try? await db.toggleItemCommentReaction(commentId: comment.id, userId: uid, emoji: emoji)
        await loadData()
    }

    private func submitCommentReply(for comment: ItemComment) async {
        guard let uid = currentUserUUID else { return }
        let trimmed = (commentReplyDrafts[comment.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? await db.addItemCommentReply(commentId: comment.id, userId: uid, message: trimmed)
        commentReplyDrafts[comment.id] = ""
        await loadData()
    }

    private func deleteSelectedComment() async {
        guard let uid = currentUserUUID, let comment = commentToDelete else { return }
        try? await db.deleteItemComment(commentId: comment.id, userId: uid)
        commentToDelete = nil
        await loadData()
    }
}

struct EditItemDetailsView: View {
    @Environment(\.dismiss) var dismiss
    let item: WatchItem
    var onSave: (WatchItem) -> Void

    @State private var title = ""
    @State private var selectedCategory: ItemCategory = .movie
    @State private var genre = ""
    @State private var trailerURL = ""
    @State private var imageURL = ""
    @State private var yearText = ""
    @State private var overview = ""
    @State private var imdbRatingText = ""
    @State private var rottenTomatoesText = ""
    @State private var availablePlatforms: [PlatformAvailability] = []

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Edit Item")
                    .font(.title3.bold())
                    .foregroundStyle(SVTheme.textPrimary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Category")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                Picker("Category", selection: $selectedCategory) {
                    ForEach(ItemCategory.allCases) { cat in
                        Label(cat.label, systemImage: cat.icon).tag(cat)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Genre (optional)")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                TextField("Genre", text: $genre)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Image URL (optional)")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                TextField("https://...", text: $imageURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }

            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Year (optional)")
                        .font(.subheadline)
                        .foregroundStyle(SVTheme.textSecondary)
                    TextField("2024", text: $yearText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                Spacer()
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("IMDb Rating (optional)")
                        .font(.subheadline)
                        .foregroundStyle(SVTheme.textSecondary)
                    TextField("8.7", text: $imdbRatingText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Rotten Tomatoes % (optional)")
                        .font(.subheadline)
                        .foregroundStyle(SVTheme.textSecondary)
                    TextField("94", text: $rottenTomatoesText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }

                Spacer()
            }

            PlatformSelectionSection(platforms: $availablePlatforms)

            VStack(alignment: .leading, spacing: 6) {
                Text("Overview (optional)")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                TextEditor(text: $overview)
                    .frame(height: 100)
                    .padding(6)
                    .background(SVTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Trailer URL (optional)")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                TextField("https://...", text: $trailerURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedGenre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedTrailerURL = trailerURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedImageURL = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedOverview = overview.trimmingCharacters(in: .whitespacesAndNewlines)

                    var updated = item
                    updated.title = trimmedTitle
                    updated.category = selectedCategory.rawValue
                    updated.genre = trimmedGenre.isEmpty ? nil : trimmedGenre
                    updated.trailerURL = trimmedTrailerURL.isEmpty ? nil : trimmedTrailerURL
                    updated.imageURL = trimmedImageURL.isEmpty ? nil : trimmedImageURL
                    updated.year = Int(yearText)
                    updated.overview = trimmedOverview.isEmpty ? nil : trimmedOverview
                    updated.imdbRating = Double(imdbRatingText)
                    updated.rottenTomatoesScore = Int(rottenTomatoesText)
                    updated.availablePlatforms = availablePlatforms
                    onSave(updated)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(SVTheme.accent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(SVTheme.surface)
        .onAppear {
            title = item.title
            selectedCategory = ItemCategory(rawValue: item.category) ?? .movie
            genre = item.genre ?? ""
            trailerURL = item.trailerURL ?? ""
            imageURL = item.imageURL ?? ""
            yearText = item.year.map(String.init) ?? ""
            overview = item.overview ?? ""
            imdbRatingText = item.imdbRating.map { String(format: "%.1f", $0) } ?? ""
            rottenTomatoesText = item.rottenTomatoesScore.map(String.init) ?? ""
            availablePlatforms = item.availablePlatforms
        }
    }
}
