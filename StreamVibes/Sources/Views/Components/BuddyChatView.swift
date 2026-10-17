import SwiftUI

// MARK: - Controller

@Observable
@MainActor
final class BuddyChatController {
    /// The drawer is mounted in the view tree.
    var isPresented: Bool = false
    /// The drawer is hidden visually behind the floating button.
    var isMinimized: Bool = false
    /// True while a buddy task is running. Drives the floating-button busy indicator.
    var isBusy: Bool = false
    /// Two width presets for the drawer.
    var isExpanded: Bool = false
    var currentItem: WatchItem? = nil

    var drawerWidth: CGFloat { isExpanded ? 560 : 400 }

    /// Cmd+K behaviour: cycle hidden → visible → hidden, restoring from minimized.
    func toggle() {
        if isPresented && !isMinimized {
            isPresented = false
            isMinimized = false
        } else {
            isPresented = true
            isMinimized = false
        }
    }

    func show() {
        isPresented = true
        isMinimized = false
    }

    func hide() {
        isPresented = false
        isMinimized = false
    }

    func minimize() {
        isMinimized = true
    }

    func restore() {
        isMinimized = false
        if !isPresented { isPresented = true }
    }

    func toggleExpanded() {
        isExpanded.toggle()
    }
}

// MARK: - Plan types

enum BuddyChatItemActionType: String, Sendable {
    // Broad
    case refreshAll = "refresh_all"
    // Focused field discovery
    case findTitle = "find_title"
    case findPoster = "find_poster"
    case findTrailer = "find_trailer"
    case findOverview = "find_overview"
    case findGenre = "find_genre"
    case findYear = "find_year"
    case findRatings = "find_ratings"
    case findPlatforms = "find_platforms"
    // Manual edits
    case setTitle = "set_title"
    case setYear = "set_year"
    case setGenre = "set_genre"
    case setOverview = "set_overview"
    case addPlatform = "add_platform"
    case removePlatform = "remove_platform"
    // Seasons / episodes
    case fetchSeasons = "fetch_seasons"
    case fetchEpisodes = "fetch_episodes"
    case fetchEpisode = "fetch_episode"
    case unknown = "unknown"
}

struct BuddyChatItemPlan: Sendable {
    var action: BuddyChatItemActionType
    var title: String?
    var platform: String?
    var year: Int?
    var genre: String?
    var overview: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var hint: String?
    var explanation: String
}

// MARK: - Message log

private struct BuddyChatMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case assistant
        case error
    }
    let id = UUID()
    let kind: Kind
    let text: String
}

// MARK: - View

struct BuddyChatView: View {
    @Environment(AIService.self) var ai
    @Environment(DatabaseService.self) var db
    @Environment(BuddyChatController.self) var buddy

    var onSelectItem: (WatchItem) -> Void

    @State private var input: String = ""
    @State private var messages: [BuddyChatMessage] = []
    @State private var isThinking: Bool = false
    @State private var suggestions: [AISearchResult] = []
    @State private var iconPulse: Bool = false
    @FocusState private var inputFocused: Bool

    private var contextItem: WatchItem? {
        if let current = buddy.currentItem {
            return db.catalogItems.first { $0.id == current.id } ?? current
        }
        return nil
    }

    private var aiEnabled: Bool {
        let raw = UserDefaults.standard.string(forKey: "aiProvider") ?? "none"
        return raw != "none"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider().background(SVTheme.border)

            messagesArea

            Divider().background(SVTheme.border)

            inputBar
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .frame(width: buddy.drawerWidth)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .background(SVTheme.surface.opacity(0.97))
        .overlay(alignment: .leading) {
            // Left edge separator so it visually docks to the side.
            Rectangle()
                .fill(SVTheme.border)
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 24, x: -8, y: 0)
        .opacity(buddy.isMinimized ? 0 : 1)
        .offset(x: buddy.isMinimized ? buddy.drawerWidth : 0)
        .allowsHitTesting(!buddy.isMinimized)
        .animation(.easeInOut(duration: 0.25), value: buddy.isMinimized)
        .animation(.easeInOut(duration: 0.2), value: buddy.drawerWidth)
        .onAppear {
            inputFocused = true
            iconPulse = true
        }
        .onChange(of: buddy.isMinimized) { _, minimized in
            if !minimized { inputFocused = true }
        }
        .onChange(of: isThinking) { _, value in
            buddy.isBusy = value
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [SVTheme.accent.opacity(0.6), SVTheme.accent.opacity(0.0)],
                            center: .center,
                            startRadius: 3,
                            endRadius: 22
                        )
                    )
                    .frame(width: 42, height: 42)
                    .scaleEffect(iconPulse ? 1.08 : 0.92)
                    .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: iconPulse)

                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SVTheme.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Buddy Chat")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(SVTheme.textPrimary)
                contextSubtitle
            }

            Spacer()

            HStack(spacing: 6) {
                headerIconButton(
                    systemName: buddy.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    help: buddy.isExpanded ? "Compact" : "Expand"
                ) {
                    buddy.toggleExpanded()
                }

                headerIconButton(systemName: "minus.circle", help: "Minimize") {
                    buddy.minimize()
                }

                headerIconButton(systemName: "xmark", help: "Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func headerIconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(SVTheme.textSecondary)
                .frame(width: 24, height: 24)
                .background(SVTheme.card)
                .clipShape(Circle())
                .overlay(Circle().stroke(SVTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var contextSubtitle: some View {
        if let item = contextItem {
            HStack(spacing: 6) {
                Image(systemName: SVTheme.categoryIcon(item.category))
                    .font(.caption2)
                    .foregroundStyle(SVTheme.categoryColor(item.category))
                Text("Editing")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
                Text(item.title)
                    .font(.caption.bold())
                    .foregroundStyle(SVTheme.textSecondary)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.caption2)
                    .foregroundStyle(SVTheme.accent)
                Text("Catalog mode")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
                Text("· ask to add anything")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textSecondary)
            }
        }
    }

    // MARK: - Messages area

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty && suggestions.isEmpty {
                        emptyState
                    }

                    ForEach(messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }

                    if !suggestions.isEmpty {
                        suggestionsList
                    }

                    if isThinking {
                        thinkingRow
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item = contextItem {
                Text("Try asking…")
                    .font(.caption.bold())
                    .foregroundStyle(SVTheme.textMuted)
                exampleChip("Find a better trailer")
                exampleChip("Add Netflix to platforms")
                exampleChip("Refresh everything for the \(item.year.map(String.init) ?? "original") version")
                if ItemCategory.categoryHasSeasons(item.category) {
                    exampleChip("Fetch the seasons")
                }
            } else {
                Text("Try asking…")
                    .font(.caption.bold())
                    .foregroundStyle(SVTheme.textMuted)
                exampleChip("Add Inception")
                exampleChip("Suggest some 80s sci-fi movies")
                exampleChip("Find a slow-burn anime like Mushishi")
            }
        }
        .padding(.top, 4)
    }

    private func exampleChip(_ text: String) -> some View {
        Button {
            input = text
            inputFocused = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.caption2)
                Text(text)
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(SVTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(SVTheme.card)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(SVTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func messageBubble(_ message: BuddyChatMessage) -> some View {
        HStack {
            if message.kind == .user { Spacer(minLength: 40) }

            HStack(alignment: .top, spacing: 10) {
                if message.kind != .user {
                    Image(systemName: message.kind == .error ? "exclamationmark.triangle.fill" : "sparkles")
                        .font(.caption)
                        .foregroundStyle(message.kind == .error ? .red : SVTheme.accent)
                        .padding(.top, 2)
                }
                Text(message.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(message.kind == .error ? Color.red : SVTheme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(message.kind == .user ? SVTheme.accent.opacity(0.22) : SVTheme.card)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(message.kind == .user ? SVTheme.accent.opacity(0.4) : SVTheme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if message.kind != .user { Spacer(minLength: 40) }
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(SVTheme.accent)
            Text("Thinking…")
                .font(.caption)
                .foregroundStyle(SVTheme.textMuted)
            Spacer()
        }
    }

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggestions")
                .font(.caption.bold())
                .foregroundStyle(SVTheme.textMuted)
                .padding(.top, 4)

            ForEach(suggestions) { result in
                BuddyChatSuggestionCard(result: result) {
                    Task { await addSuggestion(result) }
                }
            }
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 14))
                .foregroundStyle(SVTheme.textMuted)

            TextField(placeholderText, text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(SVTheme.textPrimary)
                .focused($inputFocused)
                .onSubmit { submit() }
                .disabled(isThinking)

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSubmit ? SVTheme.accent : SVTheme.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(SVTheme.card)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SVTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var placeholderText: String {
        contextItem == nil
            ? "Ask buddy to add or find something…"
            : "Ask buddy to fix or improve this item…"
    }

    private var canSubmit: Bool {
        !isThinking && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.18)) {
            buddy.hide()
        }
    }

    private func submit() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }
        guard aiEnabled else {
            messages.append(BuddyChatMessage(kind: .error, text: "Configure an AI provider in Settings to use Buddy Chat."))
            return
        }

        messages.append(BuddyChatMessage(kind: .user, text: trimmed))
        input = ""

        if let item = contextItem {
            Task { await runItemCommand(trimmed, item: item) }
        } else {
            Task { await runCatalogCommand(trimmed) }
        }
    }

    // MARK: - Catalog mode

    private func runCatalogCommand(_ query: String) async {
        isThinking = true
        suggestions = []
        defer { isThinking = false }

        let results = await ai.searchTitles(query: query)
        guard let results, !results.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "I couldn't find any matches for that. Try a different phrasing?"))
            return
        }
        suggestions = results
        messages.append(BuddyChatMessage(
            kind: .assistant,
            text: "Here are \(results.count) match\(results.count == 1 ? "" : "es"). Tap one to add it to the catalog."
        ))
    }

    private func addSuggestion(_ result: AISearchResult) async {
        if let existing = db.catalogItems.first(where: {
            $0.title.caseInsensitiveCompare(result.title) == .orderedSame &&
            $0.category == result.category &&
            $0.year == result.year
        }) {
            messages.append(BuddyChatMessage(
                kind: .assistant,
                text: "\"\(existing.title)\" is already in your catalog. Opening it now."
            ))
            suggestions = []
            buddy.hide()
            onSelectItem(existing)
            return
        }

        isThinking = true
        defer { isThinking = false }

        do {
            let newId = try await db.createItem(
                title: result.title,
                category: result.category,
                genre: result.genre,
                trailerURL: result.trailerURL,
                imageURL: result.imageURL,
                year: result.year,
                overview: result.overview,
                imdbRating: result.imdbRating,
                rottenTomatoesScore: result.rottenTomatoesScore,
                availablePlatforms: result.availablePlatforms
            )
            messages.append(BuddyChatMessage(
                kind: .assistant,
                text: "Added \"\(result.title)\" to the catalog."
            ))
            suggestions = []
            if let newItem = db.catalogItems.first(where: { $0.id == newId }) {
                buddy.hide()
                onSelectItem(newItem)
            }
        } catch {
            messages.append(BuddyChatMessage(kind: .error, text: "Couldn't add \"\(result.title)\": \(error.localizedDescription)"))
        }
    }

    // MARK: - Item mode

    private func runItemCommand(_ input: String, item: WatchItem) async {
        isThinking = true
        defer { isThinking = false }

        let seasonContext = await loadSeasonContext(for: item)

        guard let plans = await ai.interpretBuddyChatItemCommand(
            input: input,
            item: item,
            seasonContext: seasonContext
        ), !plans.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "I couldn't interpret that. Try rephrasing or be more specific."))
            return
        }

        // Show the plan summary up front so the user sees the chain of tool calls.
        if plans.count > 1 {
            let header = "I'll run \(plans.count) steps:"
            let bullets = plans.enumerated().map { "  \($0.offset + 1). \($0.element.explanation)" }.joined(separator: "\n")
            messages.append(BuddyChatMessage(kind: .assistant, text: "\(header)\n\(bullets)"))
        }

        for (index, plan) in plans.enumerated() {
            if plans.count > 1 {
                messages.append(BuddyChatMessage(
                    kind: .assistant,
                    text: "Step \(index + 1)/\(plans.count): \(plan.explanation)"
                ))
            } else if !plan.explanation.isEmpty {
                messages.append(BuddyChatMessage(kind: .assistant, text: plan.explanation))
            }

            // Always re-read the live item between steps so each action sees the latest state.
            let live = db.catalogItems.first { $0.id == item.id } ?? item

            switch plan.action {
            case .refreshAll:
                await performRefreshAll(item: live, hint: plan.hint)
            case .findTitle:
                await performFindTitle(item: live, hint: plan.hint)
            case .findPoster:
                await performFindPoster(item: live, hint: plan.hint)
            case .findTrailer:
                await performFindTrailer(item: live, hint: plan.hint)
            case .findOverview:
                await performFindOverview(item: live, hint: plan.hint)
            case .findGenre:
                await performFindGenre(item: live, hint: plan.hint)
            case .findYear:
                await performFindYear(item: live, hint: plan.hint)
            case .findRatings:
                await performFindRatings(item: live, hint: plan.hint)
            case .findPlatforms:
                await performFindPlatforms(item: live, hint: plan.hint)
            case .setTitle:
                await performSetTitle(item: live, title: plan.title)
            case .addPlatform:
                await performAddPlatform(item: live, name: plan.platform)
            case .removePlatform:
                await performRemovePlatform(item: live, name: plan.platform)
            case .setYear:
                await performSetYear(item: live, year: plan.year)
            case .setGenre:
                await performSetGenre(item: live, genre: plan.genre)
            case .setOverview:
                await performSetOverview(item: live, overview: plan.overview)
            case .fetchSeasons:
                await performFetchSeasons(item: live, hint: plan.hint)
            case .fetchEpisodes:
                await performFetchEpisodes(item: live, seasonNumber: plan.seasonNumber, hint: plan.hint)
            case .fetchEpisode:
                await performFetchSingleEpisode(
                    item: live,
                    seasonNumber: plan.seasonNumber,
                    episodeNumber: plan.episodeNumber,
                    hint: plan.hint
                )
            case .unknown:
                messages.append(BuddyChatMessage(
                    kind: .error,
                    text: "I'm not sure what to do with that. Try \"find a better trailer\", \"find the poster\", \"add Netflix\", or \"refresh everything\"."
                ))
            }
        }

        if plans.count > 1 {
            messages.append(BuddyChatMessage(kind: .assistant, text: "All \(plans.count) steps finished."))
        }
    }

    private func loadSeasonContext(for item: WatchItem) async -> [AIService.BuddyChatSeasonContext] {
        guard ItemCategory.categoryHasSeasons(item.category) else { return [] }
        guard let seasons = try? await db.fetchSeasons(for: item.id), !seasons.isEmpty else { return [] }

        var contexts: [AIService.BuddyChatSeasonContext] = []
        for season in seasons {
            let episodes = (try? await db.fetchEpisodes(for: season.id)) ?? []
            let existingNumbers = Set(episodes.map(\.episodeNumber))
            var missing: [Int] = []
            if let expected = season.episodeCount, expected > 0 {
                missing = (1...expected).filter { !existingNumbers.contains($0) }
            }
            contexts.append(
                AIService.BuddyChatSeasonContext(
                    seasonNumber: season.seasonNumber,
                    name: season.name,
                    expectedEpisodeCount: season.episodeCount,
                    existingEpisodeCount: episodes.count,
                    missingEpisodeNumbers: missing
                )
            )
        }
        return contexts
    }

    private func performRefreshAll(item: WatchItem, hint: String?) async {
        guard let result = await ai.autoFill(title: item.title, category: item.category, hint: hint) else {
            messages.append(BuddyChatMessage(kind: .error, text: "AI returned no data."))
            return
        }

        let newImage = result.imageURL ?? item.imageURL
        let newYear = result.year ?? item.year
        let newOverview = result.overview ?? item.overview
        let newTrailer = result.trailerURL ?? item.trailerURL
        let newGenre = result.genre ?? item.genre
        let newIMDb = result.imdbRating ?? item.imdbRating
        let newRotten = result.rottenTomatoesScore ?? item.rottenTomatoesScore
        let newPlatforms = PlatformAvailability.merged(
            preferred: result.availablePlatforms,
            fallback: item.availablePlatforms
        )

        do {
            try await db.updateItem(
                id: item.id,
                title: item.title,
                category: item.category,
                genre: newGenre,
                trailerURL: newTrailer,
                imageURL: newImage,
                year: newYear,
                overview: newOverview,
                imdbRating: newIMDb,
                rottenTomatoesScore: newRotten,
                availablePlatforms: newPlatforms
            )
            messages.append(BuddyChatMessage(kind: .assistant, text: "Updated \"\(item.title)\" with fresh metadata."))
        } catch {
            messages.append(BuddyChatMessage(kind: .error, text: "Couldn't save the updates: \(error.localizedDescription)"))
        }
    }

    private func performFindTitle(item: WatchItem, hint: String?) async {
        guard let newTitle = await ai.findOfficialTitle(title: item.title, category: item.category, hint: hint),
              !newTitle.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "I couldn't find a more official title."))
            return
        }
        if newTitle.caseInsensitiveCompare(item.title) == .orderedSame {
            messages.append(BuddyChatMessage(kind: .assistant, text: "The current title \"\(item.title)\" already matches the official one."))
            return
        }
        await saveItem(item, title: newTitle, message: "Title updated to \"\(newTitle)\".")
    }

    private func performFindPoster(item: WatchItem, hint: String?) async {
        guard let url = await ai.findPoster(title: item.title, category: item.category, hint: hint), !url.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "I couldn't find a better poster."))
            return
        }
        await saveItem(item, imageURL: url, message: "Saved a fresh poster.")
    }

    private func performFindTrailer(item: WatchItem, hint: String?) async {
        guard let url = await ai.findTrailer(title: item.title, category: item.category, hint: hint), !url.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "I couldn't find a different trailer right now."))
            return
        }
        await saveItem(item, trailerURL: url, message: "New trailer saved.")
    }

    private func performFindOverview(item: WatchItem, hint: String?) async {
        guard let overview = await ai.findOverview(title: item.title, category: item.category, hint: hint), !overview.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "I couldn't find a better overview."))
            return
        }
        await saveItem(item, overview: overview, message: "Overview rewritten.")
    }

    private func performFindGenre(item: WatchItem, hint: String?) async {
        guard let genre = await ai.findGenre(title: item.title, category: item.category, hint: hint), !genre.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "I couldn't pin down the genre."))
            return
        }
        await saveItem(item, genre: genre, message: "Genre set to \(genre).")
    }

    private func performFindYear(item: WatchItem, hint: String?) async {
        guard let year = await ai.findYear(title: item.title, category: item.category, hint: hint) else {
            messages.append(BuddyChatMessage(kind: .error, text: "I couldn't confirm the release year."))
            return
        }
        await saveItem(item, year: year, message: "Year set to \(year).")
    }

    private func performFindRatings(item: WatchItem, hint: String?) async {
        guard let ratings = await ai.findRatings(title: item.title, category: item.category, hint: hint),
              ratings.imdbRating != nil || ratings.rottenTomatoesScore != nil else {
            messages.append(BuddyChatMessage(kind: .error, text: "I couldn't find ratings for this title."))
            return
        }
        var parts: [String] = []
        if let imdb = ratings.imdbRating { parts.append(String(format: "IMDb %.1f", imdb)) }
        if let rt = ratings.rottenTomatoesScore { parts.append("Rotten Tomatoes \(rt)%") }
        let mergedImdb: Double? = ratings.imdbRating ?? item.imdbRating
        let mergedRt: Int? = ratings.rottenTomatoesScore ?? item.rottenTomatoesScore
        await saveItem(
            item,
            imdbRating: mergedImdb,
            rottenTomatoesScore: mergedRt,
            message: "Saved \(parts.joined(separator: ", "))."
        )
    }

    private func performFindPlatforms(item: WatchItem, hint: String?) async {
        guard let platforms = await ai.findPlatforms(
            title: item.title,
            category: item.category,
            hint: hint,
            knownPlatforms: item.availablePlatforms
        ), !platforms.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "I couldn't find any streaming services for this."))
            return
        }
        let added = platforms.filter { p in !item.availablePlatforms.contains { $0.platform == p.platform } }
        await saveItem(
            item,
            availablePlatforms: platforms,
            message: added.isEmpty
                ? "No new platforms found beyond what you already have."
                : "Added: \(added.map { $0.platform.label }.joined(separator: ", "))."
        )
    }

    private func performSetTitle(item: WatchItem, title: String?) async {
        guard let title, !title.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "Tell me what the title should be."))
            return
        }
        await saveItem(item, title: title, message: "Title set to \"\(title)\".")
    }

    /// Convenience: persist a partial update of a WatchItem and post a message.
    private func saveItem(
        _ item: WatchItem,
        title: String? = nil,
        genre: String?? = .none,
        trailerURL: String?? = .none,
        imageURL: String?? = .none,
        year: Int?? = .none,
        overview: String?? = .none,
        imdbRating: Double?? = .none,
        rottenTomatoesScore: Int?? = .none,
        availablePlatforms: [PlatformAvailability]? = nil,
        message: String
    ) async {
        do {
            try await db.updateItem(
                id: item.id,
                title: title ?? item.title,
                category: item.category,
                genre: genre ?? item.genre,
                trailerURL: trailerURL ?? item.trailerURL,
                imageURL: imageURL ?? item.imageURL,
                year: year ?? item.year,
                overview: overview ?? item.overview,
                imdbRating: imdbRating ?? item.imdbRating,
                rottenTomatoesScore: rottenTomatoesScore ?? item.rottenTomatoesScore,
                availablePlatforms: availablePlatforms ?? item.availablePlatforms
            )
            messages.append(BuddyChatMessage(kind: .assistant, text: message))
        } catch {
            messages.append(BuddyChatMessage(kind: .error, text: "Couldn't save: \(error.localizedDescription)"))
        }
    }

    private func performAddPlatform(item: WatchItem, name: String?) async {
        guard let name, !name.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "Tell me which platform you want to add."))
            return
        }
        let detected = StreamingPlatform.detect(name: name)
        let newEntry = PlatformAvailability(platform: detected, availability: "streaming", url: nil)
        if item.availablePlatforms.contains(where: { $0.platform == detected }) {
            messages.append(BuddyChatMessage(kind: .assistant, text: "\(detected.label) is already on this item."))
            return
        }
        let merged = PlatformAvailability.merged(preferred: item.availablePlatforms + [newEntry], fallback: [])
        do {
            try await db.updateItem(
                id: item.id,
                title: item.title,
                category: item.category,
                genre: item.genre,
                trailerURL: item.trailerURL,
                imageURL: item.imageURL,
                year: item.year,
                overview: item.overview,
                imdbRating: item.imdbRating,
                rottenTomatoesScore: item.rottenTomatoesScore,
                availablePlatforms: merged
            )
            messages.append(BuddyChatMessage(kind: .assistant, text: "Added \(detected.label)."))
        } catch {
            messages.append(BuddyChatMessage(kind: .error, text: "Couldn't add \(detected.label): \(error.localizedDescription)"))
        }
    }

    private func performRemovePlatform(item: WatchItem, name: String?) async {
        guard let name, !name.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "Tell me which platform you want to remove."))
            return
        }
        let detected = StreamingPlatform.detect(name: name)
        let updated = item.availablePlatforms.filter { $0.platform != detected }
        if updated.count == item.availablePlatforms.count {
            messages.append(BuddyChatMessage(kind: .assistant, text: "\(detected.label) wasn't on this item."))
            return
        }
        do {
            try await db.updateItem(
                id: item.id,
                title: item.title,
                category: item.category,
                genre: item.genre,
                trailerURL: item.trailerURL,
                imageURL: item.imageURL,
                year: item.year,
                overview: item.overview,
                imdbRating: item.imdbRating,
                rottenTomatoesScore: item.rottenTomatoesScore,
                availablePlatforms: updated
            )
            messages.append(BuddyChatMessage(kind: .assistant, text: "Removed \(detected.label)."))
        } catch {
            messages.append(BuddyChatMessage(kind: .error, text: "Couldn't remove \(detected.label): \(error.localizedDescription)"))
        }
    }

    private func performSetYear(item: WatchItem, year: Int?) async {
        guard let year else {
            messages.append(BuddyChatMessage(kind: .error, text: "Tell me which year to set."))
            return
        }
        do {
            try await db.updateItem(
                id: item.id,
                title: item.title,
                category: item.category,
                genre: item.genre,
                trailerURL: item.trailerURL,
                imageURL: item.imageURL,
                year: year,
                overview: item.overview,
                imdbRating: item.imdbRating,
                rottenTomatoesScore: item.rottenTomatoesScore,
                availablePlatforms: item.availablePlatforms
            )
            messages.append(BuddyChatMessage(kind: .assistant, text: "Year set to \(year)."))
        } catch {
            messages.append(BuddyChatMessage(kind: .error, text: "Couldn't update the year: \(error.localizedDescription)"))
        }
    }

    private func performSetGenre(item: WatchItem, genre: String?) async {
        guard let genre, !genre.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "Tell me which genre to set."))
            return
        }
        do {
            try await db.updateItem(
                id: item.id,
                title: item.title,
                category: item.category,
                genre: genre,
                trailerURL: item.trailerURL,
                imageURL: item.imageURL,
                year: item.year,
                overview: item.overview,
                imdbRating: item.imdbRating,
                rottenTomatoesScore: item.rottenTomatoesScore,
                availablePlatforms: item.availablePlatforms
            )
            messages.append(BuddyChatMessage(kind: .assistant, text: "Genre set to \(genre)."))
        } catch {
            messages.append(BuddyChatMessage(kind: .error, text: "Couldn't update the genre: \(error.localizedDescription)"))
        }
    }

    private func performSetOverview(item: WatchItem, overview: String?) async {
        guard let overview, !overview.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "Tell me what the overview should say."))
            return
        }
        do {
            try await db.updateItem(
                id: item.id,
                title: item.title,
                category: item.category,
                genre: item.genre,
                trailerURL: item.trailerURL,
                imageURL: item.imageURL,
                year: item.year,
                overview: overview,
                imdbRating: item.imdbRating,
                rottenTomatoesScore: item.rottenTomatoesScore,
                availablePlatforms: item.availablePlatforms
            )
            messages.append(BuddyChatMessage(kind: .assistant, text: "Overview updated."))
        } catch {
            messages.append(BuddyChatMessage(kind: .error, text: "Couldn't update the overview: \(error.localizedDescription)"))
        }
    }

    private func performFetchSeasons(item: WatchItem, hint: String?) async {
        guard ItemCategory.categoryHasSeasons(item.category) else {
            messages.append(BuddyChatMessage(kind: .error, text: "This item doesn't have seasons."))
            return
        }
        guard let seasons = await ai.fetchSeasonInfo(title: item.title, category: item.category, hint: hint), !seasons.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "I couldn't find season info."))
            return
        }
        do {
            try await db.createSeasons(itemId: item.id, seasons: seasons)
            try? await db.fetchCatalog()
            messages.append(BuddyChatMessage(kind: .assistant, text: "Saved \(seasons.count) season\(seasons.count == 1 ? "" : "s")."))
        } catch {
            messages.append(BuddyChatMessage(kind: .error, text: "Couldn't save the seasons: \(error.localizedDescription)"))
        }
    }

    private func performFetchEpisodes(item: WatchItem, seasonNumber: Int?, hint: String?) async {
        guard ItemCategory.categoryHasSeasons(item.category) else {
            messages.append(BuddyChatMessage(kind: .error, text: "This item doesn't have seasons."))
            return
        }
        guard let seasonNumber else {
            messages.append(BuddyChatMessage(kind: .error, text: "Tell me which season to fetch episodes for."))
            return
        }

        let storedSeasons = (try? await db.ensureSeasonScaffold(for: item)) ?? []
        guard let season = storedSeasons.first(where: { $0.seasonNumber == seasonNumber }) else {
            messages.append(BuddyChatMessage(kind: .error, text: "I don't have Season \(seasonNumber) saved yet. Try \"fetch the seasons\" first."))
            return
        }

        guard let episodes = await ai.fetchEpisodeInfo(
            title: item.title,
            category: item.category,
            seasonNumber: seasonNumber,
            hint: hint
        ), !episodes.isEmpty else {
            messages.append(BuddyChatMessage(kind: .error, text: "I couldn't find episode info for Season \(seasonNumber)."))
            return
        }

        let existing = (try? await db.fetchEpisodes(for: season.id)) ?? []
        let existingNumbers = Set(existing.map(\.episodeNumber))
        let missing = episodes.filter { !existingNumbers.contains($0.episodeNumber) }

        guard !missing.isEmpty else {
            messages.append(BuddyChatMessage(kind: .assistant, text: "Season \(seasonNumber) already has every episode."))
            return
        }

        do {
            try await db.createEpisodes(seasonId: season.id, itemId: item.id, episodes: missing)
            try? await db.syncSeasonAndItemStatus(seasonId: season.id)
            try? await db.fetchCatalog()
            messages.append(BuddyChatMessage(
                kind: .assistant,
                text: "Added \(missing.count) episode\(missing.count == 1 ? "" : "s") to Season \(seasonNumber)."
            ))
        } catch {
            messages.append(BuddyChatMessage(kind: .error, text: "Couldn't save episodes: \(error.localizedDescription)"))
        }
    }

    private func performFetchSingleEpisode(item: WatchItem, seasonNumber: Int?, episodeNumber: Int?, hint: String?) async {
        guard ItemCategory.categoryHasSeasons(item.category) else {
            messages.append(BuddyChatMessage(kind: .error, text: "This item doesn't have seasons."))
            return
        }
        guard let seasonNumber, let episodeNumber else {
            messages.append(BuddyChatMessage(kind: .error, text: "Tell me which season and episode you want."))
            return
        }

        let storedSeasons = (try? await db.ensureSeasonScaffold(for: item)) ?? []
        guard let season = storedSeasons.first(where: { $0.seasonNumber == seasonNumber }) else {
            messages.append(BuddyChatMessage(kind: .error, text: "I don't have Season \(seasonNumber) saved yet. Try \"fetch the seasons\" first."))
            return
        }

        let existing = (try? await db.fetchEpisodes(for: season.id)) ?? []
        if existing.contains(where: { $0.episodeNumber == episodeNumber }) {
            messages.append(BuddyChatMessage(kind: .assistant, text: "S\(seasonNumber)E\(episodeNumber) is already saved."))
            return
        }

        guard let episode = await ai.fetchSingleEpisodeInfo(
            title: item.title,
            category: item.category,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            hint: hint
        ) else {
            messages.append(BuddyChatMessage(kind: .error, text: "I couldn't find S\(seasonNumber)E\(episodeNumber)."))
            return
        }

        do {
            try await db.createEpisodes(seasonId: season.id, itemId: item.id, episodes: [episode])
            try? await db.syncSeasonAndItemStatus(seasonId: season.id)
            try? await db.fetchCatalog()
            let title = episode.title?.isEmpty == false ? " — \"\(episode.title ?? "")\"" : ""
            messages.append(BuddyChatMessage(kind: .assistant, text: "Added S\(seasonNumber)E\(episodeNumber)\(title)."))
        } catch {
            messages.append(BuddyChatMessage(kind: .error, text: "Couldn't save the episode: \(error.localizedDescription)"))
        }
    }
}

// MARK: - Suggestion card

private struct BuddyChatSuggestionCard: View {
    let result: AISearchResult
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Group {
                    if let urlStr = result.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
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
                .frame(width: 50, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(SVTheme.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(SVTheme.categoryLabel(result.category))
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(SVTheme.categoryColor(result.category).opacity(0.2))
                            .foregroundStyle(SVTheme.categoryColor(result.category))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        if let year = result.year {
                            Text(String(year))
                                .font(.caption)
                                .foregroundStyle(SVTheme.textMuted)
                        }
                        if let g = result.genre {
                            Text(g)
                                .font(.caption)
                                .foregroundStyle(SVTheme.textMuted)
                                .lineLimit(1)
                        }
                    }
                    if let o = result.overview {
                        Text(o)
                            .font(.caption)
                            .foregroundStyle(SVTheme.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(SVTheme.accent)
            }
            .padding(10)
            .background(SVTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SVTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var placeholder: some View {
        ZStack {
            SVTheme.categoryColor(result.category).opacity(0.2)
            Image(systemName: SVTheme.categoryIcon(result.category))
                .font(.caption)
                .foregroundStyle(SVTheme.textMuted)
        }
    }
}

// MARK: - Floating button

struct BuddyChatFloatingButton: View {
    @Environment(BuddyChatController.self) var buddy
    @State private var pulse: Bool = false

    var body: some View {
        Button {
            buddy.restore()
        } label: {
            ZStack {
                // Pulse halo when busy
                Circle()
                    .fill(SVTheme.accent.opacity(buddy.isBusy ? 0.35 : 0.0))
                    .frame(width: 70, height: 70)
                    .scaleEffect(pulse ? 1.18 : 0.9)
                    .opacity(pulse ? 0 : 1)
                    .animation(
                        buddy.isBusy
                            ? .easeOut(duration: 1.2).repeatForever(autoreverses: false)
                            : .default,
                        value: pulse
                    )

                Circle()
                    .fill(SVTheme.surface)
                    .frame(width: 52, height: 52)
                    .overlay(Circle().stroke(SVTheme.accent.opacity(0.65), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)

                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(SVTheme.accent)

                if buddy.isBusy {
                    Circle()
                        .trim(from: 0, to: 0.75)
                        .stroke(SVTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 58, height: 58)
                        .rotationEffect(.degrees(pulse ? 360 : 0))
                        .animation(
                            .linear(duration: 1.2).repeatForever(autoreverses: false),
                            value: pulse
                        )
                }
            }
            .frame(width: 70, height: 70)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(20)
        .help(buddy.isBusy ? "Buddy is working… click to expand" : "Open buddy chat")
        .onAppear { pulse = true }
    }
}
