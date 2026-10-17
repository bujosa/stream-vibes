import SwiftUI

struct AddItemView: View {
    @Environment(DatabaseService.self) var db
    @Environment(AIService.self) var ai
    @Environment(\.dismiss) var dismiss
    let listId: UUID
    @AppStorage("aiProvider") private var aiProviderRaw = "none"

    @State private var title = ""
    @State private var category: ItemCategory = .movie
    @State private var sourceURL = ""
    @State private var imageURL = ""
    @State private var yearText = ""
    @State private var genre = ""
    @State private var overview = ""
    @State private var trailerURL = ""
    @State private var imdbRatingText = ""
    @State private var rottenTomatoesText = ""
    @State private var availablePlatforms: [PlatformAvailability] = []
    @State private var searchQuery = ""
    @State private var searchResults: [WatchItem] = []
    @State private var isSearching = false
    @State private var mode: AddMode = .new
    @State private var aiStatusMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedItemForSeason: WatchItem?
    @State private var availableSeasons: [ItemSeason] = []
    @State private var isLoadingSeasons = false
    @State private var pendingSeasons: [AISeasonResult] = []

    // Episode picker (season expansion)
    @State private var expandedSeasonIds: Set<UUID> = []
    @State private var episodesBySeason: [UUID: [ItemEpisode]] = [:]
    @State private var isLoadingEpisodes: [UUID: Bool] = [:]
    @State private var episodeLoadMessages: [UUID: String] = [:]

    // Duplicate detection
    @State private var duplicateMatches: [WatchItem] = []
    @State private var duplicateCheckTask: Task<Void, Never>?
    @State private var dismissedDuplicateIds: Set<UUID> = []

    // AI search (new item mode)
    @State private var aiSearchResults: [AISearchResult] = []
    @State private var aiSearchPerformed = false
    @State private var previouslyShownTitles: [String] = []
    @State private var isAISearchingNew = false
    @State private var isAIAutofilling = false
    @State private var isImportingFromSource = false
    @State private var isSavingNewItem = false
    @State private var isAddingSelection = false
    @State private var aiNote = ""
    @State private var showAdvancedMetadata = false
    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false

    // AI search (existing item mode)
    @State private var existingAIResults: [AISearchResult] = []
    @State private var isAISearchingExisting = false
    @State private var activeExistingAIResultId: UUID?

    private var aiEnabled: Bool {
        aiProviderRaw != AIProvider.none.rawValue
    }

    private var combinedAIHint: String? {
        let trimmedNote = aiNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSource = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)

        var parts: [String] = []
        if !trimmedNote.isEmpty {
            parts.append(trimmedNote)
        }
        if !trimmedSource.isEmpty {
            parts.append("Source link: \(trimmedSource)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private var hasSourceLink: Bool {
        !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum AddMode: String, CaseIterable {
        case new = "New Item"
        case existing = "Existing Item"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Item")
                    .font(.title2.bold())
                    .foregroundStyle(SVTheme.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(SVTheme.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider().overlay(SVTheme.border)

            // Mode picker
            Picker("Mode", selection: $mode) {
                ForEach(AddMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ScrollView {
                if mode == .existing {
                    existingItemView
                } else {
                    newItemForm
                }
            }
            .padding(20)
        }
        .frame(minWidth: 480, minHeight: 500)
        .background(SVTheme.surface)
        .overlay(alignment: .bottomLeading) {
            if let feedbackMessage {
                HStack(spacing: 8) {
                    Image(systemName: feedbackIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(feedbackIsError ? .red : SVTheme.success)
                    Text(feedbackMessage)
                        .font(.caption)
                        .foregroundStyle(SVTheme.textPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .background(SVTheme.surface.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.3), radius: 8)
                .padding(20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: feedbackMessage != nil)
    }

    // MARK: - Existing Item Search

    private var listEntries: [ListEntry] {
        db.currentEntries.filter { $0.listId == listId }
    }

    private var fullyAddedItemIds: Set<UUID> {
        Set(listEntries.filter { $0.seasonId == nil }.map(\.itemId))
    }

    private var addedSeasonIds: Set<UUID> {
        Set(listEntries.compactMap(\.seasonId))
    }

    private func hasAnyEntry(for itemId: UUID) -> Bool {
        listEntries.contains { $0.itemId == itemId }
    }

    private var displayedItems: [WatchItem] {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Array(db.catalogItems.prefix(20))
        }
        return searchResults
    }

    private var existingItemView: some View {
        VStack(spacing: 16) {
            if let item = selectedItemForSeason {
                seasonPickerSection(item: item)
            } else {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(SVTheme.textMuted)
                    TextField("Search existing items...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .onChange(of: searchQuery) { _, newValue in
                            debouncedSearch(query: newValue)
                        }
                }
                .padding(10)
                .background(SVTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if aiEnabled {
                    aiNoteField(
                        title: "AI Note (optional)",
                        placeholder: "e.g. Apple TV+, 2024 sci-fi series, anime not movie..."
                    )
                    existingAdvancedSearchSection
                }

                if isSearching {
                    ProgressView()
                        .padding()
                } else if isLoadingSeasons {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading seasons...")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                    }
                    .padding()
                } else {
                    let items = displayedItems
                    if items.isEmpty && !searchQuery.isEmpty {
                        if isAISearchingExisting {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Searching with AI...")
                                    .font(.caption)
                                    .foregroundStyle(SVTheme.textMuted)
                            }
                            .padding()
                        } else if !existingAIResults.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Not in your catalog — found by AI:")
                                    .font(.caption)
                                    .foregroundStyle(SVTheme.textMuted)

                                ForEach(existingAIResults) { result in
                                    aiExistingResultCard(result)
                                }
                            }
                        } else {
                            Text("No items found. Try a different search or add a new item.")
                                .font(.caption)
                                .foregroundStyle(SVTheme.textMuted)
                                .padding()
                        }
                    } else {
                        ForEach(items) { item in
                            searchResultRow(item)
                        }
                    }
                }
            }
        }
    }

    private func searchResultRow(_ item: WatchItem) -> some View {
        let canChooseSeason = ItemCategory.categoryHasSeasons(item.category)
        let alreadyAdded = canChooseSeason ? fullyAddedItemIds.contains(item.id) : hasAnyEntry(for: item.id)

        return Button {
            if canChooseSeason {
                Task {
                    isLoadingSeasons = true
                    availableSeasons = (try? await db.ensureSeasonScaffold(for: item)) ?? []
                    isLoadingSeasons = false
                    selectedItemForSeason = item
                }
            } else {
                Task {
                    await addCatalogItemToList(itemId: item.id, successMessage: "\"\(item.title)\" added to the list.")
                }
            }
        } label: {
            HStack(spacing: 12) {
                // Thumbnail
                Group {
                    if let urlStr = item.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                thumbnailPlaceholder(item)
                            }
                        }
                    } else {
                        thumbnailPlaceholder(item)
                    }
                }
                .frame(width: 50, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(SVTheme.textPrimary)
                    HStack(spacing: 6) {
                        Text(SVTheme.categoryLabel(item.category))
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(SVTheme.categoryColor(item.category).opacity(0.2))
                            .foregroundStyle(SVTheme.categoryColor(item.category))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        if let year = item.year {
                            Text(String(year))
                                .font(.caption)
                                .foregroundStyle(SVTheme.textMuted)
                        }
                    }
                }

                Spacer()

                if alreadyAdded {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                        Text("Added")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(SVTheme.textMuted)
                } else if canChooseSeason && hasAnyEntry(for: item.id) {
                    Text("Choose season")
                        .font(.caption.bold())
                        .foregroundStyle(SVTheme.accent)
                } else {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SVTheme.accent)
                        .frame(width: 28, height: 28)
                        .background(SVTheme.accent.opacity(0.15))
                        .clipShape(Circle())
                }
            }
            .padding(10)
            .background(SVTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded || isAddingSelection)
        .opacity(alreadyAdded ? 0.6 : 1)
    }

    // MARK: - Season Picker

    private func seasonPickerSection(item: WatchItem) -> some View {
        let hasEntriesForItem = hasAnyEntry(for: item.id)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    selectedItemForSeason = nil
                    availableSeasons = []
                    expandedSeasonIds = []
                    episodesBySeason = [:]
                    isLoadingEpisodes = [:]
                    episodeLoadMessages = [:]
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back to search")
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SVTheme.accent)
                Spacer()
            }

            Text("Select Season for \(item.title)")
                .font(.subheadline.bold())
                .foregroundStyle(SVTheme.textPrimary)

            Text("Add the full season right away, or open one and keep only the episodes you want selected.")
                .font(.caption)
                .foregroundStyle(SVTheme.textMuted)

            ForEach(availableSeasons) { season in
                seasonPickerCard(season, item: item, isAlreadyAdded: addedSeasonIds.contains(season.id))
            }

            Button {
                Task {
                    await addCatalogItemToList(itemId: item.id, successMessage: "\"\(item.title)\" added without selecting a season.")
                }
            } label: {
                Text("Add without specific season")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            }
            .buttonStyle(.plain)
            .disabled(hasEntriesForItem)
            .opacity(hasEntriesForItem ? 0.5 : 1)
        }
    }

    private func seasonPickerCard(_ season: ItemSeason, item: WatchItem, isAlreadyAdded: Bool) -> some View {
        let isExpanded = expandedSeasonIds.contains(season.id)

        return VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 10) {
                // Season number badge
                Text("\(season.seasonNumber)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(SVTheme.accent.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Season \(season.seasonNumber)")
                            .font(.subheadline.bold())
                            .foregroundStyle(SVTheme.textPrimary)
                        if let year = season.year {
                            Text(String(year))
                                .font(.caption2)
                                .foregroundStyle(SVTheme.textMuted)
                        }
                    }
                    HStack(spacing: 6) {
                        if let name = season.name, !name.isEmpty {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(SVTheme.textSecondary)
                                .lineLimit(1)
                        }
                        if let eps = season.episodeCount {
                            Text("\(eps) eps")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(SVTheme.surface)
                                .foregroundStyle(SVTheme.textMuted)
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.bold())
                    .foregroundStyle(SVTheme.textMuted)
                    .frame(width: 20)

                Button {
                    Task {
                        await addSeasonEntryToList(item: item, season: season, successMessage: "\"\(item.title)\" Season \(season.seasonNumber) added to the list.")
                    }
                } label: {
                    Group {
                        if isAlreadyAdded {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SVTheme.textMuted)
                                .frame(width: 26, height: 26)
                                .background(SVTheme.surface)
                                .clipShape(Circle())
                        } else {
                            Image(systemName: "plus")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SVTheme.accent)
                                .frame(width: 26, height: 26)
                                .background(SVTheme.accent.opacity(0.15))
                                .clipShape(Circle())
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isAlreadyAdded || isAddingSelection)
            }
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedSeasonIds.remove(season.id)
                    } else {
                        expandedSeasonIds.insert(season.id)
                        if episodesBySeason[season.id] == nil {
                            Task { await loadEpisodesForPicker(season, item: item) }
                        }
                    }
                }
            }

            // Expanded episodes
            if isExpanded {
                episodePickerSection(for: season, item: item, isAlreadyAdded: isAlreadyAdded)
            }
        }
        .background(SVTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isAlreadyAdded ? 0.75 : 1)
    }

    // MARK: - Episode Picker

    @ViewBuilder
    private func episodePickerSection(for season: ItemSeason, item: WatchItem, isAlreadyAdded: Bool) -> some View {
        let episodes = episodesBySeason[season.id] ?? []
        let selectedEpisodes = episodes.filter(\.isSelected)

        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(SVTheme.border)

            HStack {
                Text("Episodes")
                    .font(.caption.bold())
                    .foregroundStyle(SVTheme.textPrimary)
                if !episodes.isEmpty {
                    let selected = episodes.filter(\.isSelected)
                    Text("\(selected.count)/\(episodes.count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SVTheme.accent.opacity(0.15))
                        .foregroundStyle(SVTheme.accent)
                        .clipShape(Capsule())
                }
                Spacer()
            }

            if !episodes.isEmpty {
                // Quick action buttons
                HStack(spacing: 6) {
                    episodeQuickButton("All") {
                        Task {
                            for ep in episodes where !ep.isSelected {
                                try? await db.toggleEpisodeSelected(episodeId: ep.id)
                            }
                            episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
                        }
                    }
                    episodeQuickButton("None") {
                        Task {
                            for ep in episodes where ep.isSelected {
                                try? await db.toggleEpisodeSelected(episodeId: ep.id)
                            }
                            episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
                        }
                    }
                    episodeQuickButton("1st Half") {
                        Task {
                            let half = episodes.count / 2
                            for (i, ep) in episodes.enumerated() {
                                let shouldBeSelected = i < half
                                if ep.isSelected != shouldBeSelected {
                                    try? await db.toggleEpisodeSelected(episodeId: ep.id)
                                }
                            }
                            episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
                        }
                    }
                    episodeQuickButton("2nd Half") {
                        Task {
                            let half = episodes.count / 2
                            for (i, ep) in episodes.enumerated() {
                                let shouldBeSelected = i >= half
                                if ep.isSelected != shouldBeSelected {
                                    try? await db.toggleEpisodeSelected(episodeId: ep.id)
                                }
                            }
                            episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    Task { await addSeasonToList(item: item, season: season, forceSelectAllEpisodes: true) }
                } label: {
                    Label("Add Full Season", systemImage: "plus.circle.fill")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(SVTheme.accent)
                .disabled(isAlreadyAdded || isLoadingEpisodes[season.id] == true)

                if !episodes.isEmpty {
                    Button {
                        Task { await addSeasonToList(item: item, season: season, forceSelectAllEpisodes: false) }
                    } label: {
                        Label("Add Selected Episodes", systemImage: "checklist")
                            .font(.caption.bold())
                    }
                    .buttonStyle(.bordered)
                    .disabled(isAlreadyAdded || selectedEpisodes.isEmpty || isLoadingEpisodes[season.id] == true)
                }
            }

            if isLoadingEpisodes[season.id] == true {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(episodeLoadMessages[season.id] ?? "Loading episodes...")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                }
                .padding(.vertical, 4)
            } else if episodes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No episodes loaded yet for this season.")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)

                    if aiEnabled {
                        Button {
                            Task { await loadEpisodesForPicker(season, item: item, forceRefreshFromAI: true) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                Text("Fetch Episodes with AI")
                            }
                            .font(.caption.bold())
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            } else {
                ForEach(episodes) { episode in
                    episodePickerRow(episode, in: season)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func episodePickerRow(_ episode: ItemEpisode, in season: ItemSeason) -> some View {
        Button {
            Task {
                try? await db.toggleEpisodeSelected(episodeId: episode.id)
                episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: episode.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(episode.isSelected ? SVTheme.accent : SVTheme.textMuted.opacity(0.5))

                Text("\(episode.episodeNumber)")
                    .font(.caption.bold().monospaced())
                    .foregroundStyle(SVTheme.textMuted)
                    .frame(width: 20, alignment: .trailing)

                if let title = episode.title, !title.isEmpty {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(episode.isSelected ? SVTheme.textPrimary : SVTheme.textMuted)
                        .lineLimit(1)
                }

                Spacer()

                if let runtime = episode.runtimeMinutes {
                    Text("\(runtime)m")
                        .font(.caption2)
                        .foregroundStyle(SVTheme.textMuted)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(episode.isSelected ? SVTheme.accent.opacity(0.05) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .opacity(episode.isSelected ? 1 : 0.5)
    }

    private func loadEpisodesForPicker(_ season: ItemSeason, item: WatchItem, forceRefreshFromAI: Bool = false) async {
        isLoadingEpisodes[season.id] = true
        episodeLoadMessages[season.id] = "Loading episodes..."
        var episodes = (try? await db.fetchEpisodes(for: season.id)) ?? []

        if (episodes.isEmpty || forceRefreshFromAI), aiEnabled {
            episodeLoadMessages[season.id] = "Fetching episodes from AI..."
            if let aiEpisodes = await ai.fetchEpisodeInfo(
                title: item.title,
                category: item.category,
                seasonNumber: season.seasonNumber,
                hint: combinedAIHint
            ), !aiEpisodes.isEmpty {
                try? await db.createEpisodes(seasonId: season.id, itemId: item.id, episodes: aiEpisodes)
                try? await db.syncSeasonAndItemStatus(seasonId: season.id)
                episodes = (try? await db.fetchEpisodes(for: season.id)) ?? []
            }
        }

        episodesBySeason[season.id] = episodes
        episodeLoadMessages[season.id] = nil
        isLoadingEpisodes[season.id] = false
    }

    private func addSeasonToList(item: WatchItem, season: ItemSeason, forceSelectAllEpisodes: Bool) async {
        isAddingSelection = true
        defer { isAddingSelection = false }

        if forceSelectAllEpisodes {
            let episodes = episodesBySeason[season.id] ?? []
            if episodes.isEmpty {
                await loadEpisodesForPicker(season, item: item)
            }

            let refreshedEpisodes = episodesBySeason[season.id] ?? []
            for episode in refreshedEpisodes where !episode.isSelected {
                try? await db.toggleEpisodeSelected(episodeId: episode.id)
            }
            if !refreshedEpisodes.isEmpty {
                episodesBySeason[season.id] = (try? await db.fetchEpisodes(for: season.id)) ?? []
            }
        }

        do {
            try await db.addItemToList(listId: listId, itemId: item.id, seasonId: season.id)
            showFeedback("\"\(item.title)\" Season \(season.seasonNumber) added to the list.")
            await dismissAfterFeedback()
        } catch {
            showFeedback("Couldn't add the selected episodes right now. \(error.localizedDescription)", isError: true)
        }
    }

    private func episodeQuickButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(SVTheme.surface)
                .foregroundStyle(SVTheme.textSecondary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(SVTheme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func thumbnailPlaceholder(_ item: WatchItem) -> some View {
        ZStack {
            SVTheme.categoryColor(item.category).opacity(0.2)
            Image(systemName: SVTheme.categoryIcon(item.category))
                .font(.caption)
                .foregroundStyle(SVTheme.textMuted)
        }
    }

    // MARK: - New Item Form

    private var newItemForm: some View {
        VStack(spacing: 16) {
            // Title
            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                TextField("e.g. Attack on Titan, Inception...", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: title) { _, newValue in
                        checkForDuplicates(title: newValue)
                        aiSearchResults = []
                        aiSearchPerformed = false
                        previouslyShownTitles = []
                    }
            }

            // Duplicate warning
            duplicateWarningSection

            // Category
            VStack(alignment: .leading, spacing: 6) {
                Text("Category")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                Picker("Category", selection: $category) {
                    ForEach(ItemCategory.allCases) { cat in
                        Label(cat.label, systemImage: cat.icon).tag(cat)
                    }
                }
                .pickerStyle(.segmented)
            }

            if aiEnabled {
                aiNoteField(
                    title: "AI Note (optional)",
                    placeholder: "e.g. Apple TV+, remake, anime adaptation, not the movie..."
                )
            }

            // AI Search section
            if aiEnabled {
                aiSearchSection
            }

            // AI Autofill section
            if aiEnabled {
                aiAutofillSection
            }

            // Image URL
            VStack(alignment: .leading, spacing: 6) {
                Text("Image URL (optional)")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                TextField("https://...", text: $imageURL)
                    .textFieldStyle(.roundedBorder)

                if let url = URL(string: imageURL), !imageURL.isEmpty {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().aspectRatio(contentMode: .fit)
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }

            // Year & Genre
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Year (optional)")
                        .font(.subheadline)
                        .foregroundStyle(SVTheme.textSecondary)
                    TextField("2024", text: $yearText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Genre (optional)")
                        .font(.subheadline)
                        .foregroundStyle(SVTheme.textSecondary)
                    TextField("e.g. Action, Drama, Sci-Fi...", text: $genre)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Overview
            VStack(alignment: .leading, spacing: 6) {
                Text("Overview (optional)")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                TextEditor(text: $overview)
                    .font(.body)
                    .frame(height: 80)
                    .padding(4)
                    .background(SVTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Trailer URL
            VStack(alignment: .leading, spacing: 6) {
                Text("Trailer URL (optional)")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                TextField("https://...", text: $trailerURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            DisclosureGroup(isExpanded: $showAdvancedMetadata) {
                VStack(alignment: .leading, spacing: 12) {
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
                }
                .padding(.top, 8)
            } label: {
                Text("Advanced Metadata")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textPrimary)
            }

            // Pending seasons indicator
            if !pendingSeasons.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "tv.inset.filled")
                        .foregroundStyle(SVTheme.accent)
                    Text("\(pendingSeasons.count) season\(pendingSeasons.count == 1 ? "" : "s") found by AI")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textSecondary)
                }
            }

            // Add button
            Button {
                Task {
                    await saveNewItem()
                }
            } label: {
                HStack {
                    if isSavingNewItem {
                        ProgressView().controlSize(.small)
                    }
                    Text(isSavingNewItem ? "Saving..." : "Add to List")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(SVTheme.accent)
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSavingNewItem || isAddingSelection)
        }
    }

    // MARK: - Duplicate Warning

    @ViewBuilder
    private var duplicateWarningSection: some View {
        let visibleDuplicates = duplicateMatches.filter { !dismissedDuplicateIds.contains($0.id) }
        if !visibleDuplicates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Similar item\(visibleDuplicates.count == 1 ? "" : "s") already in catalog")
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
                }

                ForEach(visibleDuplicates) { match in
                    HStack(spacing: 10) {
                        Group {
                            if let urlStr = match.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                                AsyncImage(url: url) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        thumbnailPlaceholder(match)
                                    }
                                }
                            } else {
                                thumbnailPlaceholder(match)
                            }
                        }
                        .frame(width: 40, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.title)
                                .font(.caption.bold())
                                .foregroundStyle(SVTheme.textPrimary)
                            HStack(spacing: 4) {
                                Text(SVTheme.categoryLabel(match.category))
                                    .font(.caption2)
                                    .foregroundStyle(SVTheme.categoryColor(match.category))
                                if let year = match.year {
                                    Text(String(year))
                                        .font(.caption2)
                                        .foregroundStyle(SVTheme.textMuted)
                                }
                            }
                        }

                        Spacer()

                        Button {
                            dismissedDuplicateIds.insert(match.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(SVTheme.textMuted)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss warning")
                    }
                    .padding(8)
                    .background(.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Text("You can still add a new item if needed.")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            }
            .padding(12)
            .background(.orange.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - AI Search Section

    private var aiSearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            advancedSearchCard(
                heading: "Advanced Search",
                subtitle: "Search outside your catalog with text, a source link, or both.",
                preferredText: title,
                actionTitle: aiSearchPerformed ? "Search Again" : "Find Suggestions",
                actionIcon: "globe",
                isLoadingAction: isAISearchingNew,
                onPrimaryAction: { triggerAdvancedSuggestionSearch() },
                onUseDetectedTitle: {
                    if let detected = derivedTitleFromSourceURL {
                        title = detected
                    }
                },
                extraAction: {
                    if hasSourceLink {
                        Button {
                            Task { await importFromSourceLink() }
                        } label: {
                            HStack(spacing: 4) {
                                if isImportingFromSource {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "link.badge.plus")
                                }
                                Text(isImportingFromSource ? "Importing..." : "Import Details")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isImportingFromSource)
                    }
                }
            )

            if isAISearchingNew, let progress = ai.progressMessage, !aiSearchPerformed {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(progress)
                }
                .font(.caption)
                .foregroundStyle(SVTheme.accent)
            } else if isImportingFromSource {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Investigating source link...")
                }
                .font(.caption)
                .foregroundStyle(SVTheme.accent)
            }

            if !aiSearchResults.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select a title to autofill the form:")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)

                    ForEach(aiSearchResults) { result in
                        aiSearchResultCard(result)
                    }

                    Button {
                        triggerAdvancedSuggestionSearch(showDifferent: true)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Not what I'm looking for")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SVTheme.accent)
                    .disabled(isAISearchingNew)
                }
            } else if aiSearchPerformed && !isAISearchingNew {
                Text("No results found. Try a different title.")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            }
        }
    }

    // MARK: - AI Autofill Section

    private var aiAutofillSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI Autofill")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                Spacer()
                Button {
                    triggerAIAutofill()
                } label: {
                    HStack(spacing: 6) {
                        if isAIAutofilling {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("Complete with AI")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(SVTheme.accent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAIAutofilling || isImportingFromSource)
            }

            if !aiNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Using note: \(aiNote)")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            }

            if isAIAutofilling, let progress = ai.progressMessage {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(progress)
                }
                .font(.caption)
                .foregroundStyle(SVTheme.accent)
            } else if let aiStatusMessage {
                Text(aiStatusMessage)
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            }

            if let error = ai.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - AI Search Result Card

    private func aiNoteField(title: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(SVTheme.textSecondary)
            TextField(placeholder, text: $aiNote, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Text("This helps AI disambiguate the exact title, platform, remake, version, or timeframe.")
                .font(.caption2)
                .foregroundStyle(SVTheme.textMuted)
        }
    }

    private var existingAdvancedSearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            advancedSearchCard(
                heading: "Advanced Search",
                subtitle: "Try harder searches with text or a pasted link when the catalog has no match.",
                preferredText: searchQuery,
                actionTitle: isAISearchingExisting ? "Searching..." : "Search Outside Catalog",
                actionIcon: "globe",
                isLoadingAction: isAISearchingExisting,
                onPrimaryAction: { Task { await runExistingAdvancedSearch() } },
                onUseDetectedTitle: {
                    if let detected = derivedTitleFromSourceURL {
                        searchQuery = detected
                    }
                },
                extraAction: {
                    EmptyView()
                }
            )
        }
    }

    @ViewBuilder
    private func advancedSearchCard<ExtraAction: View>(
        heading: String,
        subtitle: String,
        preferredText: String,
        actionTitle: String,
        actionIcon: String,
        isLoadingAction: Bool,
        onPrimaryAction: @escaping () -> Void,
        onUseDetectedTitle: @escaping () -> Void,
        @ViewBuilder extraAction: () -> ExtraAction
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(heading)
                        .font(.subheadline.bold())
                        .foregroundStyle(SVTheme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                }
                Spacer()
                HStack(spacing: 6) {
                    searchStatusChip(
                        label: preferredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No Text" : "Text Ready",
                        systemImage: "text.cursor",
                        isActive: !preferredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    searchStatusChip(
                        label: hasSourceLink ? "Link Ready" : "No Link",
                        systemImage: "link",
                        isActive: hasSourceLink
                    )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("Paste Apple TV+, Netflix, IMDb, Wikipedia, Crunchyroll...", text: $sourceURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                if let detected = derivedTitleFromSourceURL {
                    HStack(spacing: 8) {
                        Label("Detected from link: \(detected)", systemImage: "sparkles.rectangle.stack")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textSecondary)
                        Spacer()
                        Button("Use Detected Title") {
                            onUseDetectedTitle()
                        }
                        .buttonStyle(.plain)
                        .font(.caption.bold())
                        .foregroundStyle(SVTheme.accent)
                    }
                } else {
                    Text("Paste a link if the title is hard to find manually. We use the URL as extra search context.")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                }
            }

            HStack(spacing: 10) {
                Button(action: onPrimaryAction) {
                    HStack(spacing: 6) {
                        if isLoadingAction {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: actionIcon)
                        }
                        Text(actionTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(SVTheme.accent)
                .disabled((advancedSearchSeed(preferredText: preferredText) == nil) || isLoadingAction || isImportingFromSource)

                extraAction()
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
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SVTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func searchStatusChip(label: String, systemImage: String, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(label)
        }
        .font(.caption2.bold())
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isActive ? SVTheme.accent.opacity(0.16) : SVTheme.surfaceLight)
        .foregroundStyle(isActive ? SVTheme.accentLight : SVTheme.textMuted)
        .clipShape(Capsule())
    }

    private func aiSearchResultCard(_ result: AISearchResult) -> some View {
        Button {
            applyAISearchResult(result)
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let urlStr = result.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                aiResultPlaceholder(result)
                            }
                        }
                    } else {
                        aiResultPlaceholder(result)
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

                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(SVTheme.accent)
            }
            .padding(10)
            .background(SVTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func aiResultPlaceholder(_ result: AISearchResult) -> some View {
        ZStack {
            SVTheme.categoryColor(result.category).opacity(0.2)
            Image(systemName: SVTheme.categoryIcon(result.category))
                .font(.caption)
                .foregroundStyle(SVTheme.textMuted)
        }
    }

    // MARK: - AI Existing Result Card

    private func aiExistingResultCard(_ result: AISearchResult) -> some View {
        let isPreparing = activeExistingAIResultId == result.id

        return Button {
            Task { await createAndAddFromAI(result) }
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let urlStr = result.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                aiResultPlaceholder(result)
                            }
                        }
                    } else {
                        aiResultPlaceholder(result)
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

                Group {
                    if isPreparing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(SVTheme.accent)
                            .frame(width: 28, height: 28)
                            .background(SVTheme.accent.opacity(0.15))
                            .clipShape(Circle())
                    }
                }
            }
            .padding(10)
            .background(SVTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isPreparing || activeExistingAIResultId != nil)
    }

    private func createAndAddFromAI(_ result: AISearchResult) async {
        activeExistingAIResultId = result.id
        defer { activeExistingAIResultId = nil }

        let metadata = await ai.autoFill(title: result.title, category: result.category, hint: combinedAIHint)
        if ai.lastOperationWasCancelled { return }

        let seasons = metadata?.seasons
        let titleToUse = result.title
        let categoryToUse = result.category
        let imageToUse = metadata?.imageURL ?? result.imageURL
        let yearToUse = metadata?.year ?? result.year
        let overviewToUse = metadata?.overview ?? result.overview
        let genreToUse = metadata?.genre ?? result.genre
        let trailerToUse = metadata?.trailerURL ?? result.trailerURL
        let imdbToUse = metadata?.imdbRating ?? result.imdbRating
        let tomatoesToUse = metadata?.rottenTomatoesScore ?? result.rottenTomatoesScore
        let platformsToUse = PlatformAvailability.merged(
            preferred: metadata?.availablePlatforms ?? [],
            fallback: result.availablePlatforms
        )

        do {
            let item: WatchItem
            if let existing = matchingCatalogItem(title: titleToUse, category: categoryToUse, year: yearToUse) {
                try await db.updateItem(
                    id: existing.id,
                    title: titleToUse,
                    category: categoryToUse,
                    genre: genreToUse ?? existing.genre,
                    trailerURL: trailerToUse ?? existing.trailerURL,
                    imageURL: imageToUse ?? existing.imageURL,
                    year: yearToUse ?? existing.year,
                    overview: overviewToUse ?? existing.overview,
                    imdbRating: imdbToUse ?? existing.imdbRating,
                    rottenTomatoesScore: tomatoesToUse ?? existing.rottenTomatoesScore,
                    availablePlatforms: PlatformAvailability.merged(
                        preferred: platformsToUse,
                        fallback: existing.availablePlatforms
                    )
                )
                item = db.catalogItems.first { $0.id == existing.id } ?? existing
            } else {
                let itemId = try await db.createItem(
                    title: titleToUse,
                    category: categoryToUse,
                    genre: genreToUse,
                    trailerURL: trailerToUse,
                    imageURL: imageToUse,
                    year: yearToUse,
                    overview: overviewToUse,
                    imdbRating: imdbToUse,
                    rottenTomatoesScore: tomatoesToUse,
                    availablePlatforms: platformsToUse
                )
                item = db.catalogItems.first { $0.id == itemId }
                    ?? WatchItem(
                        id: itemId,
                        title: titleToUse,
                        imageURL: imageToUse,
                        category: categoryToUse,
                        genre: genreToUse,
                        trailerURL: trailerToUse,
                        year: yearToUse,
                        overview: overviewToUse,
                        createdAt: Date(),
                        imdbRating: imdbToUse,
                        rottenTomatoesScore: tomatoesToUse,
                        availablePlatforms: platformsToUse
                    )
            }

            if ItemCategory.categoryHasSeasons(categoryToUse) {
                if let seasons, !seasons.isEmpty {
                    try await db.createSeasons(itemId: item.id, seasons: seasons)
                    try? await db.fetchCatalog()
                }
                let fetchedSeasons = (try? await db.ensureSeasonScaffold(for: item)) ?? []
                if !fetchedSeasons.isEmpty {
                    availableSeasons = fetchedSeasons
                    selectedItemForSeason = db.catalogItems.first { $0.id == item.id } ?? item
                    showFeedback("\"\(result.title)\" is ready. Choose the season or episodes to keep.")
                    return
                }
            }

            try await db.addItemToList(listId: listId, itemId: item.id)
            showFeedback("\"\(result.title)\" added to the list.")
            await dismissAfterFeedback()
        } catch {
            let message = "Couldn't prepare \"\(result.title)\" right now."
            aiStatusMessage = message
            showFeedback(message, isError: true)
        }
    }

    private func matchingCatalogItem(title: String, category: String, year: Int?) -> WatchItem? {
        db.catalogItems.first { item in
            guard item.category == category else { return false }
            guard item.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else {
                return false
            }
            if let year, let itemYear = item.year {
                return itemYear == year
            }
            return true
        }
    }

    // MARK: - Actions

    private func debouncedSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            existingAIResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            isSearching = true
            searchResults = (try? await db.searchItems(query: trimmed)) ?? []
            isSearching = false

            // Auto-trigger AI search when no local results
            if searchResults.isEmpty && aiEnabled {
                isAISearchingExisting = true
                let results = await ai.searchTitles(query: trimmed, hint: combinedAIHint)
                guard !Task.isCancelled else { return }
                existingAIResults = results ?? []
                isAISearchingExisting = false
            } else {
                existingAIResults = []
            }
        }
    }

    private func checkForDuplicates(title: String) {
        duplicateCheckTask?.cancel()
        dismissedDuplicateIds = []
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            duplicateMatches = []
            return
        }
        duplicateCheckTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }

            let lowered = trimmed.lowercased()
            let localMatches = db.catalogItems.filter { item in
                let itemTitle = item.title.lowercased()
                return itemTitle.contains(lowered) || lowered.contains(itemTitle)
            }

            if !localMatches.isEmpty {
                duplicateMatches = Array(localMatches.prefix(5))
                return
            }

            // Fallback to fuzzy DB search
            let dbMatches = (try? await db.searchItems(query: trimmed)) ?? []
            duplicateMatches = Array(dbMatches.prefix(3))
        }
    }

    private func triggerAISearch(showDifferent: Bool = false) {
        triggerAISearch(query: title, showDifferent: showDifferent)
    }

    private func triggerAISearch(query: String, showDifferent: Bool = false) {
        let trimmedTitle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !isAISearchingNew else { return }

        if showDifferent {
            previouslyShownTitles.append(contentsOf: aiSearchResults.map(\.title))
        } else {
            previouslyShownTitles = []
        }

        Task {
            isAISearchingNew = true
            defer { isAISearchingNew = false }
            let results = await ai.searchTitles(
                query: trimmedTitle,
                excluding: previouslyShownTitles,
                hint: combinedAIHint
            )
            aiSearchResults = results ?? []
            aiSearchPerformed = true
        }
    }

    private func triggerAdvancedSuggestionSearch(showDifferent: Bool = false) {
        guard let seed = advancedSearchSeed(preferredText: title) else {
            showFeedback("Write a title or paste a link to search outside the catalog.", isError: true)
            return
        }

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = seed
        }

        triggerAISearch(query: seed, showDifferent: showDifferent)
    }

    private func applyAISearchResult(_ result: AISearchResult, clearSuggestions: Bool = true) {
        title = result.title
        if let cat = ItemCategory(rawValue: result.category) {
            category = cat
        }
        if let url = result.imageURL {
            imageURL = url
        }
        if let year = result.year {
            yearText = String(year)
        }
        if let g = result.genre {
            genre = g
        }
        if let o = result.overview {
            overview = o
        }
        if let t = result.trailerURL {
            trailerURL = t
        }
        if let imdb = result.imdbRating {
            imdbRatingText = String(format: "%.1f", imdb)
        }
        if let tomatoes = result.rottenTomatoesScore {
            rottenTomatoesText = String(tomatoes)
        }
        if !result.availablePlatforms.isEmpty {
            availablePlatforms = result.availablePlatforms
            showAdvancedMetadata = true
        }

        if clearSuggestions {
            aiSearchResults = []
        }
        aiStatusMessage = "Form filled with \"\(result.title)\". Use Complete with AI for seasons."
        checkForDuplicates(title: result.title)
    }

    private func triggerAIAutofill() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !isAIAutofilling else { return }

        aiStatusMessage = nil
        pendingSeasons = []
        Task {
            await runAIAutofill(overwriteExisting: false)
        }
    }

    private var derivedTitleFromSourceURL: String? {
        let trimmed = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return nil }
        return inferredSearchQuery(from: url)
    }

    private func advancedSearchSeed(preferredText: String) -> String? {
        let trimmedText = preferredText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            return trimmedText
        }
        return derivedTitleFromSourceURL
    }

    private func importFromSourceLink() async {
        let trimmedSource = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedSource),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            showFeedback("Paste a valid http(s) link to import a title.", isError: true)
            return
        }

        let currentTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchSeed = currentTitle.isEmpty ? (inferredSearchQuery(from: url) ?? "") : currentTitle
        guard !searchSeed.isEmpty else {
            showFeedback("We couldn't infer a title from that link. Add a short note and try again.", isError: true)
            return
        }

        isImportingFromSource = true
        aiStatusMessage = "Investigating link..."
        defer { isImportingFromSource = false }

        let results = await ai.searchTitles(query: searchSeed, hint: combinedAIHint)
        if let bestMatch = results?.first {
            aiSearchResults = results ?? []
            aiSearchPerformed = true
            applyAISearchResult(bestMatch, clearSuggestions: false)
        } else if currentTitle.isEmpty {
            title = searchSeed
        }

        await runAIAutofill(overwriteExisting: true)

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showFeedback("The link was analyzed, but we still need a clearer title or note.", isError: true)
            return
        }

        if pendingSeasons.isEmpty {
            showFeedback("Link analyzed. Review the generated details for \"\(title)\" before saving.")
        } else {
            showFeedback("Link analyzed. \"\(title)\" is ready with \(pendingSeasons.count) season\(pendingSeasons.count == 1 ? "" : "s").")
        }
    }

    private func runExistingAdvancedSearch() async {
        guard let seed = advancedSearchSeed(preferredText: searchQuery) else {
            showFeedback("Write a search term or paste a link to search outside the catalog.", isError: true)
            return
        }

        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchQuery = seed
        }

        isAISearchingExisting = true
        defer { isAISearchingExisting = false }

        let results = await ai.searchTitles(query: seed, hint: combinedAIHint)
        existingAIResults = results ?? []

        if existingAIResults.isEmpty {
            showFeedback("No external suggestions were found for \"\(seed)\".", isError: true)
        } else {
            showFeedback("Found \(existingAIResults.count) suggestion\(existingAIResults.count == 1 ? "" : "s") outside your catalog.")
        }
    }

    private func runAIAutofill(overwriteExisting: Bool) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        isAIAutofilling = true
        defer { isAIAutofilling = false }

        guard let result = await ai.autoFill(title: trimmedTitle, category: category.rawValue, hint: combinedAIHint) else {
            aiStatusMessage = nil
            if overwriteExisting {
                showFeedback("AI couldn't finish importing that link yet. Try adding a short note.", isError: true)
            }
            return
        }

        applyAIAutofillResult(result, overwriteExisting: overwriteExisting)
    }

    private func applyAIAutofillResult(_ result: AIAutoFillResult, overwriteExisting: Bool) {
        var didApplyAnyValue = false

        func shouldReplace(_ current: String) -> Bool {
            overwriteExisting || current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if let imageURLResult = result.imageURL, shouldReplace(imageURL) {
            imageURL = imageURLResult
            didApplyAnyValue = true
        }
        if let year = result.year, (overwriteExisting || yearText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            yearText = String(year)
            didApplyAnyValue = true
        }
        if let overviewResult = result.overview, shouldReplace(overview) {
            overview = overviewResult
            didApplyAnyValue = true
        }
        if let genreResult = result.genre, shouldReplace(genre) {
            genre = genreResult
            didApplyAnyValue = true
        }
        if let trailerResult = result.trailerURL, shouldReplace(trailerURL) {
            trailerURL = trailerResult
            didApplyAnyValue = true
        }
        if let imdb = result.imdbRating, (overwriteExisting || imdbRatingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            imdbRatingText = String(format: "%.1f", imdb)
            didApplyAnyValue = true
        }
        if let tomatoes = result.rottenTomatoesScore, (overwriteExisting || rottenTomatoesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            rottenTomatoesText = String(tomatoes)
            didApplyAnyValue = true
        }
        if overwriteExisting || availablePlatforms.isEmpty {
            let mergedPlatforms = overwriteExisting
                ? PlatformAvailability.merged(preferred: result.availablePlatforms, fallback: availablePlatforms)
                : result.availablePlatforms
            if !mergedPlatforms.isEmpty {
                availablePlatforms = mergedPlatforms
                showAdvancedMetadata = true
                didApplyAnyValue = true
            }
        }

        if let seasons = result.seasons, !seasons.isEmpty {
            pendingSeasons = seasons
            aiStatusMessage = didApplyAnyValue
                ? "Fields updated from AI (\(seasons.count) seasons found)."
                : "\(seasons.count) seasons found by AI."
        } else {
            aiStatusMessage = didApplyAnyValue ? "Fields updated from AI." : "AI returned no new data."
        }
    }

    private func saveNewItem() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            showFeedback("Add a title before saving.", isError: true)
            return
        }

        isSavingNewItem = true
        defer { isSavingNewItem = false }

        do {
            let year = Int(yearText)
            let itemId = try await db.createItem(
                title: trimmedTitle,
                category: category.rawValue,
                genre: genre.isEmpty ? nil : genre,
                trailerURL: trailerURL.isEmpty ? nil : trailerURL,
                imageURL: imageURL.isEmpty ? nil : imageURL,
                year: year,
                overview: overview.isEmpty ? nil : overview,
                imdbRating: Double(imdbRatingText),
                rottenTomatoesScore: Int(rottenTomatoesText),
                availablePlatforms: availablePlatforms
            )

            if !pendingSeasons.isEmpty {
                try await db.createSeasons(itemId: itemId, seasons: pendingSeasons)
            }

            let createdItem = db.catalogItems.first { $0.id == itemId }
                ?? WatchItem(
                    id: itemId,
                    title: trimmedTitle,
                    imageURL: imageURL.isEmpty ? nil : imageURL,
                    category: category.rawValue,
                    genre: genre.isEmpty ? nil : genre,
                    trailerURL: trailerURL.isEmpty ? nil : trailerURL,
                    year: year,
                    overview: overview.isEmpty ? nil : overview,
                    createdAt: Date(),
                    imdbRating: Double(imdbRatingText),
                    rottenTomatoesScore: Int(rottenTomatoesText),
                    availablePlatforms: availablePlatforms
                )

            if category.hasSeasons {
                availableSeasons = try await db.ensureSeasonScaffold(for: createdItem)
                selectedItemForSeason = createdItem
                aiStatusMessage = "Choose the full season or only the episodes you want to keep in this list."
                showFeedback("\"\(trimmedTitle)\" was created. Choose the season or episodes to add.")
                return
            }

            try await db.addItemToList(listId: listId, itemId: itemId)
            showFeedback("\"\(trimmedTitle)\" added to the list.")
            await dismissAfterFeedback()
        } catch {
            showFeedback("Couldn't save \"\(trimmedTitle)\" right now. \(error.localizedDescription)", isError: true)
        }
    }

    private func addCatalogItemToList(itemId: UUID, successMessage: String) async {
        isAddingSelection = true
        defer { isAddingSelection = false }

        do {
            try await db.addItemToList(listId: listId, itemId: itemId)
            showFeedback(successMessage)
            await dismissAfterFeedback()
        } catch {
            showFeedback("Couldn't add this item to the list right now. \(error.localizedDescription)", isError: true)
        }
    }

    private func addSeasonEntryToList(item: WatchItem, season: ItemSeason, successMessage: String) async {
        isAddingSelection = true
        defer { isAddingSelection = false }

        do {
            try await db.addItemToList(listId: listId, itemId: item.id, seasonId: season.id)
            showFeedback(successMessage)
            await dismissAfterFeedback()
        } catch {
            showFeedback("Couldn't add that season right now. \(error.localizedDescription)", isError: true)
        }
    }

    private func dismissAfterFeedback() async {
        try? await Task.sleep(for: .milliseconds(700))
        dismiss()
    }

    private func showFeedback(_ message: String, isError: Bool = false) {
        feedbackIsError = isError
        withAnimation(.easeInOut(duration: 0.2)) {
            feedbackMessage = message
        }

        Task {
            try? await Task.sleep(for: .seconds(isError ? 4 : 2.5))
            guard feedbackMessage == message else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                feedbackMessage = nil
            }
        }
    }

    private func inferredSearchQuery(from url: URL) -> String? {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            let preferredKeys = ["title", "name", "q", "query", "movie", "show", "series", "anime", "slug"]
            for item in components.queryItems ?? [] where preferredKeys.contains(item.name.lowercased()) {
                if let value = normalizedSourceFragment(item.value) {
                    return value
                }
            }
        }

        for component in url.pathComponents.reversed() {
            if let value = normalizedSourceFragment(component) {
                return value
            }
        }

        return normalizedSourceFragment(url.host)
    }

    private func normalizedSourceFragment(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let decoded = raw.removingPercentEncoding ?? raw
        let cleaned = decoded
            .replacingOccurrences(of: #"\.[a-z0-9]{2,4}$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[_\-.+]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(tt\d+|nm\d+|id\d+|watch|title|movie|show|series|anime|episode|season)\b"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.rangeOfCharacter(from: .letters) != nil else { return nil }
        guard cleaned.count >= 3 else { return nil }
        return cleaned
    }
}
