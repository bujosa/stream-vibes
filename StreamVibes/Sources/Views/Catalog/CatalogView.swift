import Combine
import SwiftUI

struct CatalogView: View {
    @Environment(DatabaseService.self) var db
    @Environment(AIService.self) var ai
    @Binding var selectedItem: WatchItem?
    @AppStorage("aiProvider") private var aiProviderRaw = "none"
    @AppStorage("aiCatalogSearch") private var aiCatalogSearch = true
    @AppStorage("currentUserId") private var currentUserId = ""

    @State private var searchText = ""
    @State private var searchResults: [WatchItem]? = nil
    @State private var searchTask: Task<Void, Never>?
    @State private var categoryFilter: CategoryFilter = .all
    @State private var watchedFilter: WatchedFilter = .all
    @State private var genreFilter: String? = nil
    @State private var showAddItem = false

    // AI search state
    @State private var aiSearchResults: [AISearchResult] = []
    @State private var aiSearchPerformed = false
    @State private var isAISearching = false
    @State private var previouslyExcludedTitles: [String] = []
    @State private var selectedAIResults: Set<UUID> = []
    @State private var addedResultIds: Set<UUID> = []
    @State private var isAddingResults = false

    // AI loading animation state
    @State private var sparkleRotation: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.3
    @State private var particleOffset1: CGFloat = 0
    @State private var particleOffset2: CGFloat = 0
    @State private var particleOffset3: CGFloat = 0
    @State private var aiLoadingAppeared = false
    @State private var dotCount = 0
    private let dotTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    enum CategoryFilter: String, CaseIterable {
        case all = "All"
        case anime = "Anime"
        case movie = "Movies"
        case series = "Series"
        case novela = "Telenovelas"

        var categoryValue: String? {
            switch self {
            case .all: return nil
            case .anime: return "anime"
            case .movie: return "movie"
            case .series: return "series"
            case .novela: return "novela"
            }
        }
    }

    enum WatchedFilter: String, CaseIterable {
        case all = "All"
        case pending = "Pending"
        case inProgress = "In Progress"
        case watched = "Watched"
    }

    private var filteredItems: [WatchItem] {
        var items = searchResults ?? db.catalogItems

        if searchResults == nil, let cat = categoryFilter.categoryValue {
            items = items.filter { $0.category == cat }
        }

        if let genre = genreFilter {
            items = items.filter { $0.genre == genre }
        }

        switch watchedFilter {
        case .all: break
        case .pending: items = items.filter { $0.watchStatus == .pending }
        case .inProgress: items = items.filter { $0.watchStatus == .inProgress }
        case .watched: items = items.filter { $0.watchStatus == .watched }
        }

        return items
    }

    private var availableGenres: [String] {
        let genres = db.catalogItems.compactMap(\.genre).filter { !$0.isEmpty }
        return Array(Set(genres)).sorted()
    }

    private var aiEnabled: Bool {
        aiProviderRaw != "none" && aiCatalogSearch
    }

    private var hasActiveSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Catalog")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(SVTheme.textPrimary)

                        Text("\(db.catalogItems.count) items in your collection")
                            .font(.subheadline)
                            .foregroundStyle(SVTheme.textSecondary)
                    }

                    Spacer()

                    Button {
                        showAddItem = true
                    } label: {
                        Label("Add Item", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SVTheme.accent)

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

                // Filters
                HStack(spacing: 16) {
                    Picker(selection: $categoryFilter) {
                        ForEach(CategoryFilter.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)

                    Picker(selection: $watchedFilter) {
                        ForEach(WatchedFilter.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)

                    if !availableGenres.isEmpty {
                        Menu {
                            Button("All Genres") { genreFilter = nil }
                            Divider()
                            ForEach(availableGenres, id: \.self) { genre in
                                Button(genre) { genreFilter = genre }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "tag")
                                Text(genreFilter ?? "Genre")
                                    .font(.subheadline)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(genreFilter != nil ? SVTheme.accent.opacity(0.2) : SVTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(SVTheme.textMuted)
                        TextField("Search...", text: $searchText)
                            .textFieldStyle(.plain)
                            .frame(width: 160)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(SVTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(24)
            .background(SVTheme.surface)

            // Grid
            ScrollView {
                if filteredItems.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredItems) { item in
                            CatalogItemCard(item: item)
                                .onTapGesture {
                                    selectedItem = item
                                }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(SVTheme.background)
        .onChange(of: searchText) { _, newValue in
            aiSearchResults = []
            aiSearchPerformed = false
            previouslyExcludedTitles = []
            selectedAIResults = []
            addedResultIds = []

            searchTask?.cancel()
            if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults = nil
                return
            }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let results = try? await db.searchItems(query: newValue, category: categoryFilter.categoryValue)
                if !Task.isCancelled {
                    searchResults = results
                    // Auto-trigger AI search if no local results and AI is enabled
                    if (results ?? []).isEmpty && aiEnabled {
                        triggerCatalogAISearch()
                    }
                }
            }
        }
        .onChange(of: categoryFilter) { _, _ in
            if searchResults != nil, !searchText.isEmpty {
                searchTask?.cancel()
                searchTask = Task {
                    let results = try? await db.searchItems(query: searchText, category: categoryFilter.categoryValue)
                    if !Task.isCancelled {
                        searchResults = results
                    }
                }
            }
        }
        .sheet(isPresented: $showAddItem) {
            AddToCatalogView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if db.catalogItems.isEmpty && !hasActiveSearch {
                Image(systemName: "film.stack")
                    .font(.system(size: 48))
                    .foregroundStyle(SVTheme.textMuted)

                Text("Your catalog is empty")
                    .font(.title3)
                    .foregroundStyle(SVTheme.textSecondary)
                Text("Add movies, series and anime to start tracking")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
                Button {
                    showAddItem = true
                } label: {
                    Label("Add your first item", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(SVTheme.accent)
            } else if hasActiveSearch {
                // AI search loading / results / hint
                if isAISearching {
                    aiLoadingView
                } else if !aiSearchResults.isEmpty {
                    aiResultsSection
                } else if aiSearchPerformed && aiSearchResults.isEmpty {
                    Image(systemName: "film.stack")
                        .font(.system(size: 48))
                        .foregroundStyle(SVTheme.textMuted)
                    Text("No results found")
                        .font(.title3)
                        .foregroundStyle(SVTheme.textSecondary)
                    Text("AI couldn't find matching titles either. Try a different search term.")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                } else if !aiEnabled {
                    // AI not configured — show hint
                    Image(systemName: "film.stack")
                        .font(.system(size: 48))
                        .foregroundStyle(SVTheme.textMuted)
                    Text("No items match your filters")
                        .font(.title3)
                        .foregroundStyle(SVTheme.textSecondary)

                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(SVTheme.anime)
                        Text("Enable AI Search in Settings to find titles online")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(SVTheme.anime.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "film.stack")
                        .font(.system(size: 48))
                        .foregroundStyle(SVTheme.textMuted)
                    Text("No items match your filters")
                        .font(.title3)
                        .foregroundStyle(SVTheme.textSecondary)
                }
            } else {
                Image(systemName: "film.stack")
                    .font(.system(size: 48))
                    .foregroundStyle(SVTheme.textMuted)
                Text("No items match your filters")
                    .font(.title3)
                    .foregroundStyle(SVTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(aiSearchResults.isEmpty ? 60 : 24)
    }

    // MARK: - AI Search

    private var aiLoadingView: some View {
        ZStack {
            // Radial glow behind icon
            Circle()
                .fill(
                    RadialGradient(
                        colors: [SVTheme.anime.opacity(glowOpacity), .clear],
                        center: .center,
                        startRadius: 15,
                        endRadius: 140
                    )
                )
                .frame(width: 280, height: 280)
                .scaleEffect(pulseScale)

            VStack(spacing: 24) {
                // Animated sparkle cluster
                ZStack {
                    // Orbiting particles
                    ForEach(0..<3, id: \.self) { i in
                        Image(systemName: "sparkle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SVTheme.anime.opacity(0.6))
                            .offset(
                                x: cos(sparkleRotation * .pi / 180 + Double(i) * 2.094) * 40,
                                y: sin(sparkleRotation * .pi / 180 + Double(i) * 2.094) * 40
                            )
                    }

                    // Floating small sparkles
                    Image(systemName: "sparkle")
                        .font(.system(size: 9))
                        .foregroundStyle(SVTheme.anime.opacity(0.5))
                        .offset(x: -25, y: particleOffset1 - 30)

                    Image(systemName: "sparkle")
                        .font(.system(size: 7))
                        .foregroundStyle(SVTheme.anime.opacity(0.4))
                        .offset(x: 28, y: particleOffset2 - 15)

                    Image(systemName: "sparkle")
                        .font(.system(size: 10))
                        .foregroundStyle(SVTheme.anime.opacity(0.3))
                        .offset(x: 8, y: particleOffset3 - 40)

                    // Center icon
                    Image(systemName: "sparkles")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [SVTheme.anime, SVTheme.accent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .scaleEffect(pulseScale)
                }
                .frame(width: 100, height: 100)

                // Title
                Text("Searching with AI")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(SVTheme.textPrimary)

                // Progress message
                Text((ai.progressMessage ?? "Asking AI for suggestions") + String(repeating: ".", count: dotCount))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(SVTheme.textSecondary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: ai.progressMessage)

                // Progress bar
                Capsule()
                    .fill(SVTheme.card)
                    .frame(width: 180, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [SVTheme.anime, SVTheme.accent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: aiLoadingAppeared ? 180 : 0)
                            .animation(.easeInOut(duration: 25).repeatCount(1, autoreverses: false), value: aiLoadingAppeared)
                    }
                    .clipShape(Capsule())
            }
            .opacity(aiLoadingAppeared ? 1 : 0)
            .scaleEffect(aiLoadingAppeared ? 1 : 0.9)
        }
        .padding(40)
        .onAppear {
            aiLoadingAppeared = false
            sparkleRotation = 0
            pulseScale = 1.0
            glowOpacity = 0.3
            particleOffset1 = 0
            particleOffset2 = 0
            particleOffset3 = 0

            withAnimation(.easeOut(duration: 0.4)) {
                aiLoadingAppeared = true
            }
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                sparkleRotation = 360
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulseScale = 1.08
            }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                glowOpacity = 0.6
            }
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                particleOffset1 = -18
            }
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                particleOffset2 = -22
            }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                particleOffset3 = -14
            }
        }
        .onDisappear {
            aiLoadingAppeared = false
        }
        .onReceive(dotTimer) { _ in
            if isAISearching {
                dotCount = (dotCount + 1) % 4
            }
        }
    }

    private var aiResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(SVTheme.anime)
                Text("AI Suggestions")
                    .font(.headline)
                    .foregroundStyle(SVTheme.textPrimary)

                Spacer()

                Text("\(notAddedResults.count) found")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(aiSearchResults) { result in
                        aiSuggestionCard(result)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }

            // Action bar
            HStack(spacing: 12) {
                Button {
                    triggerCatalogAISearch(showDifferent: true)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("Not what I'm looking for")
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SVTheme.accent)
                .disabled(isAISearching || isAddingResults)

                Spacer()

                if !notAddedResults.isEmpty {
                    Button {
                        addAllAIResults()
                    } label: {
                        HStack(spacing: 4) {
                            if isAddingResults {
                                ProgressView().controlSize(.small)
                            }
                            Image(systemName: "plus.circle.fill")
                            Text("Add All")
                        }
                        .font(.caption.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SVTheme.accent)
                    .disabled(isAddingResults)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            if let error = ai.lastError, aiSearchPerformed {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .background(SVTheme.anime.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(SVTheme.anime.opacity(0.2), lineWidth: 1)
        )
    }

    private var notAddedResults: [AISearchResult] {
        aiSearchResults.filter { !addedResultIds.contains($0.id) }
    }

    private func aiSuggestionCard(_ result: AISearchResult) -> some View {
        let isAdded = addedResultIds.contains(result.id)

        return VStack(alignment: .leading, spacing: 0) {
            // Poster
            ZStack(alignment: .topLeading) {
                Group {
                    if let urlStr = result.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().aspectRatio(contentMode: .fill)
                            } else if case .failure = phase {
                                aiSuggestionPlaceholder(result)
                            } else {
                                ZStack { SVTheme.card; ProgressView().controlSize(.small) }
                            }
                        }
                    } else {
                        aiSuggestionPlaceholder(result)
                    }
                }
                .frame(width: 200, height: 260)
                .clipped()

                Text(SVTheme.categoryLabel(result.category))
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(SVTheme.categoryColor(result.category).opacity(0.9))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }

            // Info
            VStack(alignment: .leading, spacing: 6) {
                Text(result.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(isAdded ? SVTheme.textMuted : SVTheme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if let year = result.year {
                        Text(String(year))
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                    }

                    if let genre = result.genre, !genre.isEmpty {
                        Text(genre)
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                            .lineLimit(1)
                    }
                }

                if let overview = result.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(SVTheme.textSecondary)
                        .lineLimit(3)
                }

                Spacer(minLength: 6)

                // Individual Add button
                if isAdded {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Added")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(SVTheme.success)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(SVTheme.success.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Button {
                        addAIResultsToCatalog([result])
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add")
                        }
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SVTheme.accent)
                    .disabled(isAddingResults)
                }
            }
            .padding(10)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(SVTheme.card)
        }
        .frame(width: 200, height: 440)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 4)
        .opacity(isAdded ? 0.7 : 1.0)
    }

    private func aiSuggestionPlaceholder(_ result: AISearchResult) -> some View {
        ZStack {
            LinearGradient(
                colors: [SVTheme.categoryColor(result.category).opacity(0.3), SVTheme.surface],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: SVTheme.categoryIcon(result.category))
                .font(.title3)
                .foregroundStyle(SVTheme.textMuted)
        }
    }

    private func triggerCatalogAISearch(showDifferent: Bool = false) {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        if showDifferent {
            previouslyExcludedTitles.append(contentsOf: aiSearchResults.map(\.title))
            selectedAIResults = []
            addedResultIds = []
        } else {
            previouslyExcludedTitles = []
        }

        isAISearching = true
        Task {
            let results = await ai.searchTitles(
                query: query,
                excluding: previouslyExcludedTitles
            )
            aiSearchResults = results ?? []
            aiSearchPerformed = true
            isAISearching = false
        }
    }

    private func addSelectedAIResults() {
        let toAdd = aiSearchResults.filter { selectedAIResults.contains($0.id) && !addedResultIds.contains($0.id) }
        addAIResultsToCatalog(toAdd)
    }

    private func addAllAIResults() {
        let toAdd = notAddedResults
        addAIResultsToCatalog(toAdd)
    }

    private func addAIResultsToCatalog(_ results: [AISearchResult]) {
        guard !results.isEmpty else { return }
        isAddingResults = true
        Task {
            let addedBy = UUID(uuidString: currentUserId)
            for result in results {
                let category = ItemCategory(rawValue: result.category)?.rawValue ?? "movie"
                _ = try? await db.createItem(
                    title: result.title,
                    category: category,
                    genre: result.genre,
                    trailerURL: result.trailerURL,
                    imageURL: result.imageURL,
                    year: result.year,
                    overview: result.overview,
                    imdbRating: result.imdbRating,
                    rottenTomatoesScore: result.rottenTomatoesScore,
                    availablePlatforms: result.availablePlatforms,
                    isWatched: false,
                    addedBy: addedBy
                )
                addedResultIds.insert(result.id)
            }
            selectedAIResults = []
            isAddingResults = false
        }
    }
}

// MARK: - Catalog Item Card

struct CatalogItemCard: View {
    @Environment(DatabaseService.self) var db
    let item: WatchItem
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Poster
            ZStack {
                Color.clear
                    .frame(height: 250)
                    .overlay { posterImage }
                    .clipped()

                // Play icon for items with trailers
                if let trailer = item.trailerURL, !trailer.isEmpty {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.5), radius: 4)
                }

                VStack(alignment: .trailing, spacing: 4) {
                    Text(SVTheme.categoryLabel(item.category))
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SVTheme.categoryColor(item.category).opacity(0.9))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    switch item.watchStatus {
                    case .watched:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(SVTheme.success)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    case .inProgress:
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    case .pending:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(8)
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(SVTheme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let year = item.year {
                        Text(String(year))
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                    }

                    if let genre = item.genre, !genre.isEmpty {
                        Text(genre)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(SVTheme.accent.opacity(0.15))
                            .foregroundStyle(SVTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                    switch item.watchStatus {
                    case .watched:
                        Text("Watched")
                            .font(.caption)
                            .foregroundStyle(SVTheme.success)
                    case .inProgress:
                        Text("In Progress")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    case .pending:
                        Text("Pending")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    if item.avgRating > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(SVTheme.star)
                            Text(String(format: "%.1f", item.avgRating))
                                .font(.caption.bold())
                                .foregroundStyle(SVTheme.star)
                        }
                    }
                }

                if item.hasSeasons {
                    VStack(spacing: 3) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(SVTheme.border)
                                    .frame(height: 3)
                                Capsule()
                                    .fill(SVTheme.categoryColor(item.category))
                                    .frame(width: geo.size.width * item.seasonProgress, height: 3)
                            }
                        }
                        .frame(height: 3)

                        HStack {
                            Text("S\(item.watchedSeasons)/\(item.totalSeasons)")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(SVTheme.categoryColor(item.category))
                            Spacer()
                            if item.watchedSeasons == item.totalSeasons {
                                Text("Complete")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(SVTheme.success)
                            }
                        }
                    }
                    .padding(.top, 4)
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
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(item.isWatched ? "Mark as Unwatched" : "Mark as Watched") {
                Task { try? await db.toggleItemWatched(itemId: item.id) }
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task { try? await db.deleteItem(id: item.id) }
            }
        }
    }

    @ViewBuilder
    private var posterImage: some View {
        if let urlStr = item.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    placeholderImage
                default:
                    ZStack { SVTheme.card; ProgressView().controlSize(.small) }
                }
            }
        } else {
            placeholderImage
        }
    }

    private var placeholderImage: some View {
        ZStack {
            LinearGradient(
                colors: [SVTheme.categoryColor(item.category).opacity(0.4), SVTheme.surface],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 8) {
                Image(systemName: SVTheme.categoryIcon(item.category))
                    .font(.system(size: 36))
                    .foregroundStyle(SVTheme.textMuted)
                Text(item.title)
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
            }
        }
    }
}

// MARK: - Add to Catalog View

struct AddToCatalogView: View {
    @Environment(DatabaseService.self) var db
    @Environment(AIService.self) var ai
    @AppStorage("currentUserId") private var currentUserId = ""
    @AppStorage("aiProvider") private var aiProviderRaw = "none"
    @Environment(\.dismiss) var dismiss
    var presetCategory: ItemCategory? = nil

    @State private var title = ""
    @State private var category: ItemCategory = .movie
    @State private var imageURL = ""
    @State private var yearText = ""
    @State private var genre = ""
    @State private var overview = ""
    @State private var trailerURL = ""
    @State private var imdbRatingText = ""
    @State private var rottenTomatoesText = ""
    @State private var availablePlatforms: [PlatformAvailability] = []
    @State private var isWatched = false
    @State private var isAIAutofilling = false
    @State private var aiNote = ""
    @State private var showAdvancedMetadata = false

    private var aiConfigured: Bool {
        aiProviderRaw != "none"
    }

    private var previewItem: WatchItem {
        WatchItem(
            id: UUID(),
            title: title.isEmpty ? "Title Preview" : title,
            imageURL: imageURL.isEmpty ? nil : imageURL,
            category: category.rawValue,
            genre: genre.isEmpty ? nil : genre,
            trailerURL: trailerURL.isEmpty ? nil : trailerURL,
            year: Int(yearText),
            overview: overview.isEmpty ? nil : overview,
            createdAt: Date(),
            isWatched: isWatched,
            imdbRating: Double(imdbRatingText),
            rottenTomatoesScore: Int(rottenTomatoesText),
            availablePlatforms: availablePlatforms
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add to Catalog")
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

            // Two-column layout
            HStack(alignment: .top, spacing: 0) {
                // Left: form
                ScrollView {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Text("Title")
                                    .font(.subheadline)
                                    .foregroundStyle(SVTheme.textSecondary)
                                Text("*")
                                    .foregroundStyle(SVTheme.accent)
                            }
                            TextField("e.g. Attack on Titan, Inception...", text: $title)
                                .textFieldStyle(.roundedBorder)
                        }

                        // AI Auto-fill
                        if aiConfigured {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("AI Note (optional)")
                                    .font(.subheadline)
                                    .foregroundStyle(SVTheme.textSecondary)
                                TextField("e.g. Apple TV+, remake, anime not movie...", text: $aiNote, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(2...4)
                                Text("Use this to help AI identify the exact title/version before autofill.")
                                    .font(.caption2)
                                    .foregroundStyle(SVTheme.textMuted)
                            }

                            Button {
                                Task {
                                    guard !title.trimmingCharacters(in: .whitespaces).isEmpty, !isAIAutofilling else { return }
                                    isAIAutofilling = true
                                    defer { isAIAutofilling = false }
                                    if let result = await ai.autoFill(title: title, category: category.rawValue, hint: aiNote) {
                                    if let url = result.imageURL { imageURL = url }
                                    if let year = result.year { yearText = String(year) }
                                    if let desc = result.overview { overview = desc }
                                    if let g = result.genre, genre.isEmpty { genre = g }
                                    if let t = result.trailerURL, trailerURL.isEmpty { trailerURL = t }
                                    if let imdb = result.imdbRating, imdbRatingText.isEmpty { imdbRatingText = String(format: "%.1f", imdb) }
                                    if let tomatoes = result.rottenTomatoesScore, rottenTomatoesText.isEmpty { rottenTomatoesText = String(tomatoes) }
                                    if availablePlatforms.isEmpty, !result.availablePlatforms.isEmpty {
                                        availablePlatforms = result.availablePlatforms
                                        showAdvancedMetadata = true
                                    }
                                }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if isAIAutofilling {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "sparkles")
                                    }
                                    Text(isAIAutofilling ? "Generating..." : "Auto-fill with AI")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.bordered)
                            .tint(SVTheme.anime)
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isAIAutofilling)

                            if let error = ai.lastError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

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

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Image URL")
                                .font(.subheadline)
                                .foregroundStyle(SVTheme.textSecondary)
                            TextField("https://image.tmdb.org/t/p/w500/...", text: $imageURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }

                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Year")
                                    .font(.subheadline)
                                    .foregroundStyle(SVTheme.textSecondary)
                                TextField("2024", text: $yearText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Genre")
                                    .font(.subheadline)
                                    .foregroundStyle(SVTheme.textSecondary)
                                TextField("e.g. Action, Drama...", text: $genre)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Toggle("Already watched", isOn: $isWatched)
                                .foregroundStyle(SVTheme.textPrimary)
                                .padding(.top, 20)

                            Spacer()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Overview")
                                .font(.subheadline)
                                .foregroundStyle(SVTheme.textSecondary)
                            TextEditor(text: $overview)
                                .font(.body)
                                .frame(height: 80)
                                .padding(4)
                                .background(SVTheme.card)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Trailer URL")
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
                                        Text("IMDb Rating")
                                            .font(.subheadline)
                                            .foregroundStyle(SVTheme.textSecondary)
                                        TextField("8.7", text: $imdbRatingText)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 120)
                                    }

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Rotten Tomatoes %")
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

                        Button {
                            Task {
                                let year = Int(yearText)
                                let addedBy = UUID(uuidString: currentUserId)
                                _ = try await db.createItem(
                                    title: title,
                                    category: category.rawValue,
                                    genre: genre.isEmpty ? nil : genre,
                                    trailerURL: trailerURL.isEmpty ? nil : trailerURL,
                                    imageURL: imageURL.isEmpty ? nil : imageURL,
                                    year: year,
                                    overview: overview.isEmpty ? nil : overview,
                                    imdbRating: Double(imdbRatingText),
                                    rottenTomatoesScore: Int(rottenTomatoesText),
                                    availablePlatforms: availablePlatforms,
                                    isWatched: isWatched,
                                    addedBy: addedBy
                                )
                                dismiss()
                            }
                        } label: {
                            Text("Add to Catalog")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SVTheme.accent)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(20)
                }

                Divider().overlay(SVTheme.border)

                // Right: live preview
                VStack(spacing: 16) {
                    Text("Preview")
                        .font(.headline)
                        .foregroundStyle(SVTheme.textPrimary)

                    CatalogItemCard(item: previewItem)
                        .frame(width: 200)
                        .allowsHitTesting(false)

                    Spacer()
                }
                .padding(20)
                .frame(width: 260)
                .background(SVTheme.background)
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        .background(SVTheme.surface)
        .onAppear {
            if let preset = presetCategory {
                category = preset
            }
        }
    }
}
