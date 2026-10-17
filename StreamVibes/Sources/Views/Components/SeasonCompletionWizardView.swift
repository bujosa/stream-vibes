import SwiftUI

struct SeasonCompletionWizardView: View {
    @Environment(DatabaseService.self) private var db
    @Environment(\.dismiss) private var dismiss
    @AppStorage("currentUserId") private var currentUserId = ""

    let season: ItemSeason
    let itemTitle: String
    var entryId: UUID? = nil
    var listId: UUID? = nil
    var preferredCompletionMode: CompletionMode? = nil
    var preferredReviewMode: ReviewMode? = nil
    var onCompleted: (() -> Void)? = nil

    @State private var episodes: [ItemEpisode] = []
    @State private var reviews: [SeasonReview] = []
    @State private var selectedEpisode: ItemEpisode?
    @State private var completionMode: CompletionMode = .finishNow
    @State private var reviewMode: ReviewMode = .skip
    @State private var seasonScore: Double = 0
    @State private var seasonComment = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var feedbackMessage: String?
    @State private var showCelebration = false

    enum CompletionMode: String, CaseIterable, Identifiable {
        case finishNow
        case keepProgress
        case removeFromList

        var id: String { rawValue }

        var title: String {
            switch self {
            case .finishNow: return "Finished It"
            case .keepProgress: return "Keep Progress"
            case .removeFromList: return "Remove Season"
            }
        }

        var subtitle: String {
            switch self {
            case .finishNow: return "Mark the remaining episodes as watched and close it beautifully."
            case .keepProgress: return "Leave it open exactly as it is, but save your notes if you want."
            case .removeFromList: return "Take this season out of the current list without forcing completion."
            }
        }

        var icon: String {
            switch self {
            case .finishNow: return "checkmark.seal.fill"
            case .keepProgress: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
            case .removeFromList: return "minus.circle.fill"
            }
        }
    }

    enum ReviewMode: String, CaseIterable, Identifiable {
        case season
        case episodes
        case skip

        var id: String { rawValue }

        var title: String {
            switch self {
            case .season: return "Season Review"
            case .episodes: return "Episode Gallery"
            case .skip: return "Skip For Now"
            }
        }
    }

    private var watchedCount: Int {
        episodes.filter { $0.isSelected && $0.isWatched }.count
    }

    private var selectedCount: Int {
        episodes.filter(\.isSelected).count
    }

    private var totalEpisodeCount: Int {
        episodes.count
    }

    private var hasPartialSelection: Bool {
        totalEpisodeCount > 0 && selectedCount > 0 && selectedCount < totalEpisodeCount
    }

    private var unselectedCount: Int {
        max(totalEpisodeCount - selectedCount, 0)
    }

    private var watchedEpisodes: [ItemEpisode] {
        episodes.filter(\.isWatched)
    }

    private var headerTitle: String {
        if completionMode == .removeFromList {
            return "Remove Season"
        }
        if completionMode == .finishNow && hasPartialSelection {
            return "Close Selected Episodes"
        }
        if completionMode == .keepProgress && reviewMode == .episodes {
            return "Episode Review"
        }
        if completionMode == .keepProgress && reviewMode == .season {
            return "Season Review"
        }
        return "Season Wrap-Up"
    }

    private var headerSubtitle: String {
        if completionMode == .removeFromList {
            return "Take this season out of the current list without faking progress or leaving messy state behind."
        }
        if completionMode == .finishNow && totalEpisodeCount > 0 && selectedCount == 0 {
            return "Choose at least one episode first. Once something is selected, you can close that progress cleanly."
        }
        if completionMode == .finishNow && hasPartialSelection {
            return "This flow will only close the episodes currently tracked in this season entry, leaving the rest untouched."
        }
        if completionMode == .keepProgress && reviewMode == .episodes {
            return "Browse the gallery, rate what matters, and leave this season open while you keep watching."
        }
        if completionMode == .keepProgress && reviewMode == .season {
            return "Leave one strong overall verdict without forcing the season closed right now."
        }
        return "Wrap it up with a clean recap, your rating, and a better finish than a plain checkbox."
    }

    private var finishNowSubtitle: String {
        if totalEpisodeCount > 0 && selectedCount == 0 {
            return "Pick the episodes you want to track first, then come back here to close them properly."
        }
        if hasPartialSelection {
            return "Mark the remaining selected episodes as watched and leave every unselected episode untouched."
        }
        return CompletionMode.finishNow.subtitle
    }

    private var primaryActionTitle: String {
        switch completionMode {
        case .finishNow: return hasPartialSelection ? "Close Selected Episodes" : "Close Season"
        case .keepProgress: return "Save Progress"
        case .removeFromList: return "Remove From List"
        }
    }

    private var canSave: Bool {
        guard !isSaving else { return false }
        if completionMode == .removeFromList {
            return entryId != nil && listId != nil
        }
        if completionMode == .finishNow && totalEpisodeCount > 0 && selectedCount == 0 {
            return false
        }
        if reviewMode == .season {
            return seasonScore > 0
        }
        return true
    }

    init(
        season: ItemSeason,
        itemTitle: String,
        entryId: UUID? = nil,
        listId: UUID? = nil,
        preferredCompletionMode: CompletionMode? = nil,
        preferredReviewMode: ReviewMode? = nil,
        onCompleted: (() -> Void)? = nil
    ) {
        self.season = season
        self.itemTitle = itemTitle
        self.entryId = entryId
        self.listId = listId
        self.preferredCompletionMode = preferredCompletionMode
        self.preferredReviewMode = preferredReviewMode
        self.onCompleted = onCompleted
        _completionMode = State(initialValue: preferredCompletionMode ?? .finishNow)
        _reviewMode = State(initialValue: preferredReviewMode ?? .skip)
        _seasonScore = State(initialValue: 0)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header

                Divider().overlay(SVTheme.border)

                Group {
                    if isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Preparing your season flow...")
                                .font(.callout)
                                .foregroundStyle(SVTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                recapSection
                                completionSection
                                reviewSection
                            }
                            .padding(24)
                        }
                    }
                }

                Divider().overlay(SVTheme.border)

                footer
            }
            .frame(minWidth: 860, idealWidth: 920, minHeight: 680, idealHeight: 760)
            .background(SVTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            if showCelebration {
                CelebrationConfettiView()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .task { await loadData() }
        .sheet(item: $selectedEpisode, onDismiss: {
            feedbackMessage = "Episode notes refreshed. You can keep reviewing or finish the season when you're ready."
            Task { await loadData() }
        }) { episode in
            EpisodeDetailView(episode: episode, season: season, itemTitle: itemTitle)
                .environment(db)
                .frame(width: 860, height: 620)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(headerTitle)
                    .font(.title2.bold())
                    .foregroundStyle(SVTheme.textPrimary)

                HStack(spacing: 8) {
                    Text(itemTitle)
                        .font(.headline)
                        .foregroundStyle(SVTheme.textPrimary)
                    Text("Season \(season.seasonNumber)")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(SVTheme.accent.opacity(0.16))
                        .foregroundStyle(SVTheme.accent)
                        .clipShape(Capsule())
                }

                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(SVTheme.textSecondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(SVTheme.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
        }
        .padding(24)
    }

    private var recapSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recap")
                        .font(.headline)
                        .foregroundStyle(SVTheme.textPrimary)
                    Text("Decide whether you finished it, leave your take, or jump episode by episode.")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textSecondary)
                }

                Spacer()

                if season.ratingCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(SVTheme.star)
                        Text(String(format: "%.1f", season.avgRating))
                            .bold()
                        Text("from \(season.ratingCount)")
                            .foregroundStyle(SVTheme.textMuted)
                    }
                    .font(.caption)
                }
            }

            HStack(spacing: 12) {
                recapMetric(icon: "play.rectangle.fill", title: "Selected", value: "\(selectedCount)")
                recapMetric(icon: "checkmark.circle.fill", title: "Watched", value: "\(watchedCount)")
                recapMetric(icon: "star.fill", title: "Season Rating", value: season.ratingCount > 0 ? String(format: "%.1f", season.avgRating) : "None")
            }

            if hasPartialSelection {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .font(.title3)
                        .foregroundStyle(SVTheme.accent)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("This season is tracking selected episodes only.")
                            .font(.subheadline.bold())
                            .foregroundStyle(SVTheme.textPrimary)
                        Text("\(selectedCount) of \(totalEpisodeCount) episodes are included. Closing now will only affect those selected episodes, and \(unselectedCount) episode\(unselectedCount == 1 ? "" : "s") will stay untouched.")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textSecondary)
                    }
                }
                .padding(14)
                .background(SVTheme.accent.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            if totalEpisodeCount > 0 && selectedCount == 0 {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(SVTheme.star)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("No tracked episodes yet.")
                            .font(.subheadline.bold())
                            .foregroundStyle(SVTheme.textPrimary)
                        Text("You can still leave notes or ratings, but closing is disabled until at least one episode is selected for this season.")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textSecondary)
                    }
                }
                .padding(14)
                .background(SVTheme.star.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            if !episodes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Episode Gallery")
                            .font(.subheadline.bold())
                            .foregroundStyle(SVTheme.textPrimary)
                        Spacer()
                        Text("\(watchedCount)/\(selectedCount) watched")
                            .font(.caption.bold())
                            .foregroundStyle(SVTheme.accent)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(episodes) { episode in
                                episodeCapsule(episode)
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [SVTheme.card, SVTheme.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func recapMetric(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(SVTheme.accent)
                .frame(width: 34, height: 34)
                .background(SVTheme.accent.opacity(0.14))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
                Text(value)
                    .font(.headline.bold())
                    .foregroundStyle(SVTheme.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(SVTheme.surface.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func episodeCapsule(_ episode: ItemEpisode) -> some View {
        Button {
            selectedEpisode = episode
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("E\(episode.episodeNumber)")
                        .font(.caption.bold().monospaced())
                    Spacer()
                    Image(systemName: episode.isWatched ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(episode.isWatched ? SVTheme.success : SVTheme.textMuted)
                }

                Text(episode.title?.isEmpty == false ? episode.title! : "Episode \(episode.episodeNumber)")
                    .font(.caption.bold())
                    .foregroundStyle(SVTheme.textPrimary)
                    .lineLimit(2)

                if episode.ratingCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                        Text(String(format: "%.1f", episode.avgRating))
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(SVTheme.star)
                } else {
                    Text(episode.isWatched ? "Tap to rate" : "Not watched yet")
                        .font(.caption2)
                        .foregroundStyle(SVTheme.textMuted)
                }
            }
            .padding(12)
            .frame(width: 150, height: 110, alignment: .topLeading)
            .background(episode.isWatched ? SVTheme.success.opacity(0.08) : SVTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(episode.isWatched ? SVTheme.success.opacity(0.28) : SVTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var completionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How Do You Want To Wrap It?")
                .font(.headline)
                .foregroundStyle(SVTheme.textPrimary)

            HStack(spacing: 12) {
                ForEach(availableCompletionModes) { mode in
                    completionCard(mode)
                }
            }
        }
    }

    private var availableCompletionModes: [CompletionMode] {
        entryId != nil && listId != nil ? CompletionMode.allCases : CompletionMode.allCases.filter { $0 != .removeFromList }
    }

    private func completionCard(_ mode: CompletionMode) -> some View {
        let isSelected = completionMode == mode

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                completionMode = mode
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: mode.icon)
                    .font(.title2)
                    .foregroundStyle(isSelected ? .white : SVTheme.accent)

                Text(mode.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(isSelected ? .white : SVTheme.textPrimary)

                Text(mode == .finishNow ? finishNowSubtitle : mode.subtitle)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.88) : SVTheme.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
            .padding(16)
            .background(isSelected ? SVTheme.accent : SVTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? SVTheme.accent.opacity(0.85) : SVTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Flow")
                .font(.headline)
                .foregroundStyle(SVTheme.textPrimary)

            Picker("Review Mode", selection: $reviewMode) {
                ForEach(ReviewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch reviewMode {
            case .season:
                seasonReviewSection
            case .episodes:
                episodeGallerySection
            case .skip:
                skipReviewSection
            }
        }
    }

    private var seasonReviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title2)
                    .foregroundStyle(SVTheme.accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text("General Season Review")
                        .font(.subheadline.bold())
                        .foregroundStyle(SVTheme.textPrimary)
                    Text("Skip episode-by-episode scoring and leave one strong season verdict instead.")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textSecondary)
                }
            }

            HStack(spacing: 12) {
                Slider(value: $seasonScore, in: 0...10, step: 0.5)
                    .tint(SVTheme.accent)
                ScoreBadge(score: seasonScore, size: .subheadline)
            }

            if seasonScore > 0 {
                RatingStarsView(score: seasonScore)
            } else {
                Text("Choose a score only if you want to leave a season verdict.")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Comment")
                    .font(.caption.bold())
                    .foregroundStyle(SVTheme.textSecondary)
                TextEditor(text: $seasonComment)
                    .frame(height: 120)
                    .padding(8)
                    .background(SVTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(18)
        .background(SVTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var episodeGallerySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.3x2.fill")
                    .font(.title2)
                    .foregroundStyle(SVTheme.anime)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Rate Episodes In Gallery")
                        .font(.subheadline.bold())
                        .foregroundStyle(SVTheme.textPrimary)
                    Text("Tap any episode card to open its detail modal, score it, comment it, or skip it.")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textSecondary)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 12)], spacing: 12) {
                ForEach(episodes) { episode in
                    episodeGalleryCard(episode)
                }
            }
        }
        .padding(18)
        .background(SVTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func episodeGalleryCard(_ episode: ItemEpisode) -> some View {
        Button {
            selectedEpisode = episode
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("E\(episode.episodeNumber)")
                        .font(.caption.bold().monospaced())
                        .foregroundStyle(SVTheme.textMuted)
                    Spacer()
                    if episode.isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(SVTheme.success)
                    }
                }

                Text(episode.title?.isEmpty == false ? episode.title! : "Episode \(episode.episodeNumber)")
                    .font(.subheadline.bold())
                    .foregroundStyle(SVTheme.textPrimary)
                    .lineLimit(2)

                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(SVTheme.textSecondary)
                        .lineLimit(3)
                }

                Spacer(minLength: 0)

                HStack {
                    if episode.ratingCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                            Text(String(format: "%.1f", episode.avgRating))
                        }
                        .font(.caption2.bold())
                        .foregroundStyle(SVTheme.star)
                    } else {
                        Text(episode.isWatched ? "Tap to rate" : "Tap to inspect")
                            .font(.caption2)
                            .foregroundStyle(SVTheme.textMuted)
                    }

                    Spacer()
                    if let runtime = episode.runtimeMinutes {
                        Text("\(runtime)m")
                            .font(.caption2)
                            .foregroundStyle(SVTheme.textMuted)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .padding(14)
            .background(episode.isWatched ? SVTheme.success.opacity(0.06) : SVTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(episode.isWatched ? SVTheme.success.opacity(0.22) : SVTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var skipReviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No problem. You can close the season now and come back for ratings or comments later.")
                .font(.callout)
                .foregroundStyle(SVTheme.textSecondary)

            Text("If you want more detail later, the episode gallery and season review stay available from the detail views.")
                .font(.caption)
                .foregroundStyle(SVTheme.textMuted)
        }
        .padding(18)
        .background(SVTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let feedbackMessage {
                Text(feedbackMessage)
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            }

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .disabled(isSaving)

            Button {
                Task { await saveAndCloseSeason() }
            } label: {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: completionMode == .finishNow ? "party.popper.fill" : "checkmark.circle.fill")
                    }
                    Text(primaryActionTitle)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(completionMode == .finishNow ? SVTheme.success : SVTheme.accent)
            .disabled(!canSave)
        }
        .padding(20)
    }

    private func loadData() async {
        isLoading = true
        episodes = (try? await db.fetchEpisodes(for: season.id)) ?? []
        reviews = (try? await db.fetchSeasonReviews(for: season.id)) ?? []

        if let currentUserId = UUID(uuidString: currentUserId),
           let mine = reviews.first(where: { $0.userId == currentUserId }) {
            seasonScore = mine.score
            seasonComment = mine.comment ?? ""
            if preferredReviewMode == nil {
                reviewMode = .season
            }
        }

        isLoading = false
    }

    private func saveAndCloseSeason() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            if let userId = UUID(uuidString: currentUserId), reviewMode == .season, seasonScore > 0 {
                let trimmedComment = seasonComment.trimmingCharacters(in: .whitespacesAndNewlines)
                try await db.rateSeason(
                    seasonId: season.id,
                    userId: userId,
                    score: seasonScore,
                    comment: trimmedComment.isEmpty ? nil : trimmedComment
                )
            }

            switch completionMode {
            case .finishNow:
                try await db.markAllEpisodesWatched(seasonId: season.id, watched: true)
                showCelebration = true
                feedbackMessage = "Season closed beautifully."
                onCompleted?()
                try? await Task.sleep(for: .seconds(1.25))
                dismiss()

            case .keepProgress:
                try await db.syncSeasonAndItemStatus(seasonId: season.id)
                feedbackMessage = "Season progress saved. You can keep rating episodes later."
                onCompleted?()
                dismiss()

            case .removeFromList:
                if let entryId, let listId {
                    try await db.removeEntry(entryId: entryId, listId: listId)
                    feedbackMessage = "Season removed from the list."
                    onCompleted?()
                    dismiss()
                }
            }
        } catch {
            feedbackMessage = "Couldn't finish this season flow right now."
        }
    }
}

private struct CelebrationConfettiView: View {
    private let colors: [Color] = [
        .yellow, .orange, .pink, .green, .blue, SVTheme.accent, SVTheme.success
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<28, id: \.self) { index in
                    ConfettiPiece(
                        color: colors[index % colors.count],
                        delay: Double(index) * 0.02,
                        startX: CGFloat((index * 37) % 100) / 100 * geo.size.width,
                        travelX: CGFloat(((index * 23) % 80) - 40),
                        size: CGFloat(8 + (index % 6) * 2)
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ConfettiPiece: View {
    let color: Color
    let delay: Double
    let startX: CGFloat
    let travelX: CGFloat
    let size: CGFloat

    @State private var offsetY: CGFloat = -40
    @State private var offsetX: CGFloat = 0
    @State private var rotation: Double = 0
    @State private var opacity: Double = 1

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: size * 0.5, height: size)
            .rotationEffect(.degrees(rotation))
            .offset(x: startX + offsetX, y: offsetY)
            .opacity(opacity)
            .onAppear {
                offsetY = -40
                offsetX = 0
                rotation = 0
                opacity = 1

                withAnimation(.easeIn(duration: 0.8).delay(delay)) {
                    offsetY = 460
                    offsetX = travelX
                    rotation = 420
                }

                withAnimation(.easeOut(duration: 1.1).delay(delay + 0.3)) {
                    opacity = 0
                }
            }
    }
}
