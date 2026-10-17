import SwiftUI

struct EpisodeDetailView: View {
    @Environment(DatabaseService.self) var db
    @AppStorage("currentUserId") private var currentUserId = ""
    let episode: ItemEpisode
    let season: ItemSeason
    let itemTitle: String

    @State private var ratings: [EpisodeRating] = []
    @State private var comments: [EpisodeComment] = []
    @State private var myScore: Double = 0
    @State private var myComment = ""
    @State private var showReviewComposer = false
    @State private var isEditing = false
    @State private var reviewFeedback: String?
    @State private var newCommentDraft = ""
    @State private var isCommentsSectionExpanded = true
    @State private var showAllComments = false
    @State private var expandedCommentTextIds: Set<UUID> = []
    @State private var openCommentReplyBoxes: Set<UUID> = []
    @State private var commentReplyDrafts: [UUID: String] = [:]
    @State private var expandedReviewIds: Set<UUID> = []
    @State private var replyDrafts: [UUID: String] = [:]
    @State private var isFavorite: Bool
    @State private var commentToDelete: EpisodeComment?
    @State private var showDeleteCommentConfirm = false
    @State private var isOtherReviewsExpanded = false

    var onAction: ((String) -> Void)?

    init(episode: ItemEpisode, season: ItemSeason, itemTitle: String, onAction: ((String) -> Void)? = nil) {
        self.episode = episode
        self.season = season
        self.itemTitle = itemTitle
        self.onAction = onAction
        _isFavorite = State(initialValue: episode.isFavorite)
    }

    private var currentUserUUID: UUID? { UUID(uuidString: currentUserId) }

    private var myRating: EpisodeRating? {
        guard let uid = currentUserUUID else { return nil }
        return ratings.first { $0.userId == uid }
    }

    private var partnerRatings: [EpisodeRating] {
        guard let uid = currentUserUUID else { return ratings }
        return ratings.filter { $0.userId != uid }
    }

    private var visibleComments: [EpisodeComment] {
        if showAllComments || comments.count <= 2 { return comments }
        return Array(comments.prefix(2))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                episodeHeader

                // Two-column layout
                HStack(alignment: .top, spacing: 20) {
                    // Left column: rating + comments
                    VStack(alignment: .leading, spacing: 16) {
                        ratingSection
                        commentsSection
                    }
                    .frame(maxWidth: .infinity)

                    // Right column: other reviews
                    reviewsColumn
                        .frame(width: 300)
                }
            }
            .padding(24)
        }
        .background(SVTheme.background)
        .task { await loadData() }
        .alert("Delete Comment", isPresented: $showDeleteCommentConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let comment = commentToDelete, let uid = currentUserUUID {
                    Task {
                        try? await db.deleteEpisodeComment(commentId: comment.id, userId: uid)
                        await loadData()
                    }
                }
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Header

    private var episodeHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Season \(season.seasonNumber)")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)

                    HStack(spacing: 8) {
                        Text("E\(episode.episodeNumber)")
                            .font(.title2.bold().monospaced())
                            .foregroundStyle(SVTheme.accent)

                        if let title = episode.title, !title.isEmpty {
                            Text(title)
                                .font(.title2.bold())
                                .foregroundStyle(SVTheme.textPrimary)
                        }
                    }

                    Text(itemTitle)
                        .font(.subheadline)
                        .foregroundStyle(SVTheme.textSecondary)
                }

                Spacer()

                Button {
                    Task {
                        try? await db.toggleEpisodeFavorite(episodeId: episode.id)
                        isFavorite.toggle()
                        let name = episode.title ?? "E\(episode.episodeNumber)"
                        onAction?(isFavorite ? "'\(name)' added to favorites" : "'\(name)' removed from favorites")
                    }
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.title2)
                        .foregroundStyle(isFavorite ? SVTheme.star : SVTheme.textMuted)
                }
                .buttonStyle(.plain)
                .help(isFavorite ? "Remove from favorites" : "Mark as favorite")
            }

            HStack(spacing: 12) {
                if let airDate = episode.airDate, !airDate.isEmpty {
                    Label(airDate, systemImage: "calendar")
                }
                if let runtime = episode.runtimeMinutes {
                    Label("\(runtime) min", systemImage: "clock")
                }
                if episode.ratingCount > 0 {
                    HStack(spacing: 4) {
                        RatingStarsView(score: episode.avgRating)
                        Text("(\(episode.ratingCount))")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(SVTheme.textMuted)

            if let overview = episode.overview, !overview.isEmpty {
                Text(overview)
                    .font(.body)
                    .foregroundStyle(SVTheme.textSecondary)
                    .lineSpacing(4)
                    .padding(.top, 4)
            }
        }
        .padding(20)
        .background(SVTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Rating Section

    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Rating")
                .font(.headline)
                .foregroundStyle(SVTheme.textPrimary)

            if let rating = myRating, !showReviewComposer {
                // Show existing rating
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        RatingStarsView(score: rating.score)
                        ScoreBadge(score: rating.score, size: .caption)
                        Spacer()
                        Button("Edit") {
                            myScore = rating.score
                            myComment = rating.comment ?? ""
                            showReviewComposer = true
                            isEditing = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if let comment = rating.comment, !comment.isEmpty {
                        Text(comment)
                            .font(.callout)
                            .foregroundStyle(SVTheme.textSecondary)
                    }
                }
                .padding(14)
                .background(SVTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if !showReviewComposer {
                Button {
                    showReviewComposer = true
                    myScore = 5
                } label: {
                    Label("Write your review", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
            }

            if showReviewComposer {
                reviewComposer
            }

            if let feedback = reviewFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            }
        }
        .padding(16)
        .background(SVTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var reviewComposer: some View {
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
                LinearGradient(colors: [SVTheme.card, SVTheme.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Text("Review note (optional)")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
                TextEditor(text: $myComment)
                    .font(.body)
                    .frame(height: 90)
                    .padding(6)
                    .background(SVTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    Button { NSApp.orderFrontCharacterPalette(nil) } label: {
                        Image(systemName: "face.smiling").font(.caption).foregroundStyle(SVTheme.textMuted)
                    }
                    .buttonStyle(.plain)
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
                        guard let uid = currentUserUUID else {
                            reviewFeedback = "Select a user first."
                            return
                        }
                        let trimmed = myComment.trimmingCharacters(in: .whitespacesAndNewlines)
                        do {
                            try await db.rateEpisode(episodeId: episode.id, userId: uid, score: myScore, comment: trimmed.isEmpty ? nil : trimmed)
                            showReviewComposer = false
                            isEditing = false
                            await loadData()
                            reviewFeedback = "Review saved."
                            let name = episode.title ?? "E\(episode.episodeNumber)"
                            onAction?("Review saved for '\(name)'")
                        } catch {
                            reviewFeedback = "Could not save review."
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

    // MARK: - Reviews Column

    private var reviewsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reviews")
                .font(.headline)
                .foregroundStyle(SVTheme.textPrimary)

            if ratings.isEmpty {
                Text("No reviews yet")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            } else {
                // My review card
                if let rating = myRating {
                    reviewCard(rating, isMe: true)
                }

                // Other reviews
                if !partnerRatings.isEmpty {
                    DisclosureGroup(isExpanded: $isOtherReviewsExpanded) {
                        ForEach(partnerRatings) { rating in
                            reviewCard(rating, isMe: false)
                        }
                    } label: {
                        Text("Other Reviews (\(partnerRatings.count))")
                            .font(.caption.bold())
                            .foregroundStyle(SVTheme.textMuted)
                    }
                }
            }
        }
        .padding(16)
        .background(SVTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func reviewCard(_ rating: EpisodeRating, isMe: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(SVTheme.accent.opacity(0.3))
                    .frame(width: 28, height: 28)
                    .overlay(Text(String((rating.userName ?? "?").prefix(1))).font(.caption.bold()).foregroundStyle(SVTheme.accent))

                Text(rating.userName ?? "Unknown")
                    .font(.caption.bold())
                    .foregroundStyle(SVTheme.textPrimary)

                if isMe {
                    Text("You")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SVTheme.accent.opacity(0.2))
                        .foregroundStyle(SVTheme.accent)
                        .clipShape(Capsule())
                }

                Spacer()
                ScoreBadge(score: rating.score, size: .caption2)
            }

            RatingStarsView(score: rating.score)

            if let comment = rating.comment, !comment.isEmpty {
                Text(comment)
                    .font(.caption)
                    .foregroundStyle(SVTheme.textSecondary)
            }

            // Like + Reply
            HStack(spacing: 10) {
                Button {
                    Task {
                        guard let uid = currentUserUUID else { return }
                        try? await db.toggleEpisodeRatingLike(ratingId: rating.id, userId: uid)
                        await loadData()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: rating.isLikedByCurrentUser ? "hand.thumbsup.fill" : "hand.thumbsup")
                        Text("\(rating.likeCount)")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(rating.isLikedByCurrentUser ? SVTheme.accent : SVTheme.textMuted)

                Button {
                    if expandedReviewIds.contains(rating.id) {
                        expandedReviewIds.remove(rating.id)
                    } else {
                        expandedReviewIds.insert(rating.id)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrowshape.turn.up.left")
                        Text("Reply")
                    }
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(SVTheme.textMuted)
            }

            // Replies
            if !rating.replies.isEmpty {
                ForEach(rating.replies) { reply in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(SVTheme.textMuted).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reply.userName ?? "Unknown").font(.caption2.bold()).foregroundStyle(SVTheme.textPrimary)
                            Text(reply.message).font(.caption2).foregroundStyle(SVTheme.textSecondary)
                        }
                    }
                    .padding(6)
                    .background(SVTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            // Reply box
            if expandedReviewIds.contains(rating.id) {
                HStack(spacing: 8) {
                    TextField("Reply...", text: Binding(
                        get: { replyDrafts[rating.id] ?? "" },
                        set: { replyDrafts[rating.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    Button("Send") {
                        Task {
                            guard let uid = currentUserUUID else { return }
                            let msg = (replyDrafts[rating.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !msg.isEmpty else { return }
                            try? await db.addEpisodeRatingReply(ratingId: rating.id, userId: uid, message: msg)
                            replyDrafts[rating.id] = ""
                            await loadData()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled((replyDrafts[rating.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(10)
        .background(SVTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Comments Section

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
                    Label(isCommentsSectionExpanded ? "Hide" : "Show",
                          systemImage: isCommentsSectionExpanded ? "chevron.up" : "chevron.down")
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
                        .frame(height: 80)
                        .padding(6)
                        .background(SVTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    HStack {
                        Button { NSApp.orderFrontCharacterPalette(nil) } label: {
                            Image(systemName: "face.smiling").font(.body).foregroundStyle(SVTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button("Post Comment") {
                            Task { await submitComment() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SVTheme.accent)
                        .disabled(newCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

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
                            withAnimation(.easeInOut(duration: 0.2)) { showAllComments.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.caption.bold())
                        .foregroundStyle(SVTheme.accent)
                    }
                }
            }
        }
        .padding(16)
        .background(SVTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func commentCard(_ comment: EpisodeComment) -> some View {
        let isExpanded = expandedCommentTextIds.contains(comment.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Text(comment.userName ?? "Unknown").font(.caption.bold()).foregroundStyle(SVTheme.textPrimary)
                    if comment.userId == currentUserUUID {
                        Text("You").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(SVTheme.accent.opacity(0.2)).foregroundStyle(SVTheme.accent).clipShape(Capsule())
                    }
                }
                Spacer()
                Text(comment.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(SVTheme.textMuted)
                if comment.userId == currentUserUUID {
                    Button(role: .destructive) {
                        commentToDelete = comment
                        showDeleteCommentConfirm = true
                    } label: {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(0.9))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(comment.message).font(.body).foregroundStyle(SVTheme.textSecondary)
                    .lineLimit(isExpanded ? nil : 3).frame(maxWidth: .infinity, alignment: .leading)
                if comment.message.count > 120 {
                    Button(isExpanded ? "See less" : "See more") {
                        if isExpanded { expandedCommentTextIds.remove(comment.id) } else { expandedCommentTextIds.insert(comment.id) }
                    }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(SVTheme.accent)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(SVTheme.card).clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Button {
                    Task {
                        guard let uid = currentUserUUID else { return }
                        try? await db.toggleEpisodeCommentLike(commentId: comment.id, userId: uid)
                        await loadData()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: comment.isLikedByCurrentUser ? "hand.thumbsup.fill" : "hand.thumbsup")
                        Text("\(comment.likeCount)")
                    }
                }
                .buttonStyle(.plain).font(.caption)
                .foregroundStyle(comment.isLikedByCurrentUser ? SVTheme.accent : SVTheme.textMuted)

                Button {
                    if openCommentReplyBoxes.contains(comment.id) { openCommentReplyBoxes.remove(comment.id) }
                    else { openCommentReplyBoxes.insert(comment.id) }
                } label: {
                    HStack(spacing: 4) { Image(systemName: "arrowshape.turn.up.left"); Text("Reply") }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(SVTheme.textMuted)

                Spacer()

                Menu {
                    ForEach(["👍", "❤️", "🔥", "😂", "😮", "😢"], id: \.self) { emoji in
                        let current = comment.reactions.first { $0.emoji == emoji }
                        Button {
                            Task {
                                guard let uid = currentUserUUID else { return }
                                try? await db.toggleEpisodeCommentReaction(commentId: comment.id, userId: uid, emoji: emoji)
                                await loadData()
                            }
                        } label: {
                            HStack {
                                Text(emoji)
                                if let count = current?.count, count > 0 { Text("\(count)").foregroundStyle(SVTheme.textMuted) }
                            }
                        }
                    }
                } label: {
                    Label("React", systemImage: "face.smiling").font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }

            // Active reactions
            let activeReactions = comment.reactions.filter { $0.count > 0 }.sorted { $0.emoji < $1.emoji }
            if !activeReactions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(activeReactions) { reaction in
                            HStack(spacing: 4) { Text(reaction.emoji); Text("\(reaction.count)").font(.caption2.bold()) }
                                .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(reaction.isMine ? SVTheme.accent.opacity(0.2) : SVTheme.surface)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            // Replies
            if !comment.replies.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(comment.replies) { reply in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(SVTheme.textMuted).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(reply.userName ?? "Unknown").font(.caption.bold()).foregroundStyle(SVTheme.textPrimary)
                                    if reply.userId == currentUserUUID {
                                        Text("You").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(SVTheme.accent.opacity(0.2)).foregroundStyle(SVTheme.accent).clipShape(Capsule())
                                    }
                                    Spacer(minLength: 0)
                                }
                                Text(reply.message).font(.caption).foregroundStyle(SVTheme.textSecondary)
                                Text(reply.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(SVTheme.textMuted)
                            }
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(SVTheme.surface).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.leading, 8)
            }

            // Reply box
            if openCommentReplyBoxes.contains(comment.id) {
                HStack(spacing: 8) {
                    TextField("Reply to \(comment.userName ?? "comment")...", text: Binding(
                        get: { commentReplyDrafts[comment.id] ?? "" },
                        set: { commentReplyDrafts[comment.id] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        Task {
                            guard let uid = currentUserUUID else { return }
                            let msg = (commentReplyDrafts[comment.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !msg.isEmpty else { return }
                            try? await db.addEpisodeCommentReply(commentId: comment.id, userId: uid, message: msg)
                            commentReplyDrafts[comment.id] = ""
                            await loadData()
                        }
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

    // MARK: - Actions

    private func loadData() async {
        let uid = currentUserUUID
        ratings = (try? await db.fetchEpisodeRatings(for: episode.id, currentUserId: uid)) ?? []
        comments = (try? await db.fetchEpisodeComments(for: episode.id, currentUserId: uid)) ?? []
    }

    private func submitComment() async {
        guard let uid = currentUserUUID else { return }
        let msg = newCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        try? await db.addEpisodeComment(episodeId: episode.id, userId: uid, message: msg)
        newCommentDraft = ""
        await loadData()
    }
}
