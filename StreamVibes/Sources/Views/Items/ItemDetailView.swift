import SwiftUI

// MARK: - Item Detail Sheet (catalog-centric)

struct ItemDetailSheet: View {
    @Environment(DatabaseService.self) var db
    @Environment(\.dismiss) var dismiss
    @AppStorage("currentUserId") private var currentUserId = ""
    let item: WatchItem

    @State private var ratings: [Rating] = []
    @State private var myScore: Double = 0
    @State private var myComment = ""
    @State private var isEditing = false

    private var myRating: Rating? {
        guard let uid = UUID(uuidString: currentUserId) else { return nil }
        return ratings.first { $0.userId == uid }
    }

    private var partnerRatings: [Rating] {
        guard let uid = UUID(uuidString: currentUserId) else { return ratings }
        return ratings.filter { $0.userId != uid }
    }

    private var liveItem: WatchItem {
        db.catalogItems.first { $0.id == item.id } ?? item
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header image
            ZStack(alignment: .bottomLeading) {
                if let urlStr = liveItem.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fill)
                                .frame(height: 220).clipped()
                        } else {
                            headerPlaceholder
                        }
                    }
                } else {
                    headerPlaceholder
                }

                LinearGradient(colors: [.clear, SVTheme.surface], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: SVTheme.categoryIcon(liveItem.category))
                        Text(SVTheme.categoryLabel(liveItem.category))
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(SVTheme.categoryColor(liveItem.category))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text(liveItem.title)
                        .font(.title.bold())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                }
                .padding(20)
            }
            .frame(height: 220)
            .clipped()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Meta info
                    HStack(spacing: 12) {
                        if let year = liveItem.year {
                            Text(String(year))
                                .font(.subheadline)
                                .foregroundStyle(SVTheme.textMuted)
                        }

                        if liveItem.avgRating > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(SVTheme.star)
                                Text(String(format: "%.1f", liveItem.avgRating))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(SVTheme.textPrimary)
                                Text("(\(liveItem.ratingCount))")
                                    .font(.caption)
                                    .foregroundStyle(SVTheme.textMuted)
                            }
                        }
                    }

                    // Watch status toggle
                    watchStatusSection

                    // Overview
                    if let overview = liveItem.overview, !overview.isEmpty {
                        Divider().overlay(SVTheme.border)
                        Text(overview)
                            .font(.body)
                            .foregroundStyle(SVTheme.textSecondary)
                    }

                    Divider().overlay(SVTheme.border)

                    // Your rating
                    myRatingSection

                    // Partner ratings
                    if !partnerRatings.isEmpty {
                        Divider().overlay(SVTheme.border)
                        partnerRatingsSection
                    }
                }
                .padding(20)
            }

            // Close
            HStack {
                Button("Delete Item", role: .destructive) {
                    Task {
                        try? await db.deleteItem(id: item.id)
                        dismiss()
                    }
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)

                Spacer()

                Button("Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(SVTheme.accent)
            }
            .padding(16)
        }
        .frame(minWidth: 500, minHeight: 600)
        .background(SVTheme.surface)
        .task {
            await loadRatings()
        }
    }

    private var headerPlaceholder: some View {
        LinearGradient(
            colors: [SVTheme.categoryColor(liveItem.category).opacity(0.3), SVTheme.surface],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .frame(height: 220)
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
    }

    // MARK: - My Rating

    private var myRatingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Rating")
                .font(.headline)
                .foregroundStyle(SVTheme.textPrimary)

            if let existing = myRating, !isEditing {
                HStack {
                    RatingDisplay(score: existing.score)
                    Spacer()
                    Button("Edit") {
                        myScore = existing.score
                        myComment = existing.comment ?? ""
                        isEditing = true
                    }
                    .buttonStyle(.bordered)
                }
                if let comment = existing.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.body)
                        .foregroundStyle(SVTheme.textSecondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SVTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } else {
                VStack(spacing: 12) {
                    HStack {
                        Text("Score:")
                            .foregroundStyle(SVTheme.textSecondary)
                        Slider(value: $myScore, in: 0...10, step: 0.1)
                            .tint(SVTheme.accent)
                        Text(String(format: "%.1f", myScore))
                            .font(.title3.bold())
                            .foregroundStyle(SVTheme.star)
                            .frame(width: 40)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Comment (optional)")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                        TextField("Write your comment...", text: $myComment)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        if isEditing {
                            Button("Cancel") { isEditing = false }
                                .buttonStyle(.bordered)
                        }
                        Spacer()
                        Button("Save Rating") {
                            Task {
                                guard let uid = UUID(uuidString: currentUserId) else { return }
                                let trimmedComment = myComment.trimmingCharacters(in: .whitespacesAndNewlines)
                                try? await db.rateItem(
                                    itemId: item.id, userId: uid,
                                    score: myScore, comment: trimmedComment.isEmpty ? nil : trimmedComment
                                )
                                isEditing = false
                                await loadRatings()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SVTheme.accent)
                        .disabled(myScore == 0)
                    }
                }
            }
        }
    }

    // MARK: - Partner Ratings

    private var partnerRatingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Partner Ratings")
                .font(.headline)
                .foregroundStyle(SVTheme.textPrimary)

            ForEach(partnerRatings) { rating in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rating.userName ?? "Unknown")
                            .font(.subheadline.bold())
                            .foregroundStyle(SVTheme.textPrimary)
                        if let comment = rating.comment, !comment.isEmpty {
                            Text(comment)
                                .font(.caption)
                                .foregroundStyle(SVTheme.textSecondary)
                        }
                    }
                    Spacer()
                    RatingDisplay(score: rating.score)
                }
                .padding(10)
                .background(SVTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func loadRatings() async {
        ratings = (try? await db.fetchRatings(for: item.id)) ?? []
        if let existing = myRating {
            myScore = existing.score
            myComment = existing.comment ?? ""
        }
    }
}

// MARK: - Rating Display

struct RatingDisplay: View {
    let score: Double

    var color: Color {
        if score >= 8 { return SVTheme.success }
        if score >= 6 { return SVTheme.star }
        if score >= 4 { return .orange }
        return .red
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .foregroundStyle(color)
            Text(String(format: "%.1f", score))
                .font(.headline.bold())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
