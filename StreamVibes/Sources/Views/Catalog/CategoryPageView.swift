import SwiftUI

struct CategoryPageView: View {
    @Environment(DatabaseService.self) var db
    @AppStorage("currentUserId") private var currentUserId = ""
    let category: ItemCategory
    @Binding var selectedItem: WatchItem?

    @State private var searchText = ""
    @State private var searchResults: [WatchItem]? = nil
    @State private var searchTask: Task<Void, Never>?
    @State private var watchedFilter: WatchedFilter = .all
    @State private var genreFilter: String? = nil
    @State private var showAddItem = false

    enum WatchedFilter: String, CaseIterable {
        case all = "All"
        case watched = "Watched"
        case pending = "Pending"
    }

    private var displayItems: [WatchItem] {
        var items = searchResults ?? db.catalogItems.filter { $0.category == category.rawValue }

        if let genre = genreFilter {
            items = items.filter { $0.genre == genre }
        }

        switch watchedFilter {
        case .all: return items
        case .watched: return items.filter { $0.isWatched }
        case .pending: return items.filter { !$0.isWatched }
        }
    }

    private var availableGenres: [String] {
        let genres = db.catalogItems
            .filter { $0.category == category.rawValue }
            .compactMap(\.genre)
            .filter { !$0.isEmpty }
        return Array(Set(genres)).sorted()
    }

    private var pendingCount: Int {
        db.catalogItems.filter { $0.category == category.rawValue && !$0.isWatched }.count
    }

    private var watchedCount: Int {
        db.catalogItems.filter { $0.category == category.rawValue && $0.isWatched }.count
    }

    let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: category.icon)
                        .font(.system(size: 28))
                        .foregroundStyle(SVTheme.categoryColor(category.rawValue))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.label)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(SVTheme.textPrimary)

                        HStack(spacing: 12) {
                            Text("\(pendingCount) pending")
                                .foregroundStyle(.orange)
                            Text("\(watchedCount) watched")
                                .foregroundStyle(SVTheme.success)
                        }
                        .font(.caption)
                    }

                    Spacer()

                    Button {
                        showAddItem = true
                    } label: {
                        Label("Add \(category.label)", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SVTheme.categoryColor(category.rawValue))

                    Button {
                        Task { try? await db.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                            .foregroundStyle(SVTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                // Search + filter
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(SVTheme.textMuted)
                        TextField("Search \(category.label.lowercased())...", text: $searchText)
                            .textFieldStyle(.plain)
                            .frame(minWidth: 200)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(SVTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

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
                }
            }
            .padding(24)
            .background(
                LinearGradient(
                    colors: [SVTheme.categoryColor(category.rawValue).opacity(0.15), SVTheme.surface],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )

            // Grid
            ScrollView {
                if displayItems.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(displayItems) { item in
                            CatalogItemCard(item: item)
                                .onTapGesture { selectedItem = item }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(SVTheme.background)
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults = nil
                return
            }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let results = try? await db.searchItems(query: newValue, category: category.rawValue)
                if !Task.isCancelled {
                    searchResults = results
                }
            }
        }
        .sheet(isPresented: $showAddItem) {
            AddToCatalogView(presetCategory: category)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: category.icon)
                .font(.system(size: 48))
                .foregroundStyle(SVTheme.categoryColor(category.rawValue).opacity(0.5))

            if searchResults != nil {
                Text("No results found")
                    .font(.title3)
                    .foregroundStyle(SVTheme.textSecondary)
                Text("Try a different search term")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)
            } else {
                Text("No \(category.label.lowercased()) yet")
                    .font(.title3)
                    .foregroundStyle(SVTheme.textSecondary)
                Button {
                    showAddItem = true
                } label: {
                    Label("Add your first \(category.label.lowercased())", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(SVTheme.categoryColor(category.rawValue))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(60)
    }
}
