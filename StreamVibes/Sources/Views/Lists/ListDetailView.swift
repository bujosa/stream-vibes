import SwiftUI

struct ListDetailView: View {
    @Environment(DatabaseService.self) var db
    let list: WatchList
    @Binding var selectedItem: WatchItem?
    @Binding var selectedList: WatchList?
    @State private var filter: EntryFilter = .all
    @State private var showAddItem = false
    @State private var showEditList = false
    @State private var showDeleteConfirm = false
    @State private var showCloseSeasonConfirm = false
    @State private var searchText = ""

    enum EntryFilter: String, CaseIterable {
        case all = "All"
        case toWatch = "To Watch"
        case inProgress = "In Progress"
        case watched = "Watched"
    }

    private var liveEntries: [ListEntry] {
        let items = Dictionary(uniqueKeysWithValues: db.catalogItems.map { ($0.id, $0) })
        return db.currentEntries.map { entry in
            var updated = entry
            updated.item = items[entry.itemId] ?? entry.item
            return updated
        }
    }

    private var filteredEntries: [ListEntry] {
        var entries = liveEntries
        switch filter {
        case .all: break
        case .toWatch: entries = entries.filter { $0.item?.watchStatus == .pending }
        case .inProgress: entries = entries.filter { $0.item?.watchStatus == .inProgress }
        case .watched: entries = entries.filter { $0.item?.watchStatus == .watched }
        }
        if !searchText.isEmpty {
            entries = entries.filter { ($0.item?.title ?? "").localizedCaseInsensitiveContains(searchText) }
        }
        return entries
    }

    let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)
    ]

    private var liveList: WatchList {
        db.lists.first { $0.id == list.id } ?? list
    }

    private var unwatchedCount: Int {
        liveEntries.filter { $0.item?.isWatched != true }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 12) {
                if let bannerURL = (liveList.bannerImageURL ?? liveList.imageURL), !bannerURL.isEmpty, let url = URL(string: bannerURL) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            listCoverPlaceholder
                        }
                    }
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    listCoverPlaceholder
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(liveList.name)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(SVTheme.textPrimary)

                        if let desc = liveList.description, !desc.isEmpty {
                            Text(desc)
                                .font(.subheadline)
                                .foregroundStyle(SVTheme.textSecondary)
                        }

                        HStack(spacing: 12) {
                            Label("\(liveList.totalItems) items", systemImage: "film.stack")
                            Label("\(liveList.watchedItems) watched", systemImage: "checkmark.circle")
                            Label(liveList.createdByName ?? "Unknown", systemImage: "person")
                            Label(liveList.createdAt.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                            if liveList.totalItems > 0 {
                                Text("\(Int(liveList.progress * 100))%")
                                    .fontWeight(.medium)
                                    .foregroundStyle(SVTheme.accent)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                    }

                    Spacer()

                    if liveList.isActive {
                        Button {
                            showAddItem = true
                        } label: {
                            Label("Add Item", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SVTheme.accent)

                        Button {
                            showCloseSeasonConfirm = true
                        } label: {
                            Label("Complete List", systemImage: "checkmark.seal")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SVTheme.success)
                    } else {
                        Button {
                            Task { try? await db.reopenSeason(listId: list.id) }
                        } label: {
                            Label("Reopen List", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        showEditList = true
                    } label: {
                        Label("Edit List", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete List", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
                }

                if liveList.isActive {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(SVTheme.textMuted)
                        Text("Complete List affects the whole list. Season closing lives inside each season card.")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                    }
                }

                if !liveList.isActive {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                        Text("List Completed")
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.success)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(SVTheme.success.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Progress bar
                if liveList.totalItems > 0 {
                    ProgressView(value: liveList.progress)
                        .tint(liveList.isActive ? SVTheme.accent : SVTheme.success)
                }

                // Filters
                HStack(spacing: 12) {
                    Picker("Filter", selection: $filter) {
                        ForEach(EntryFilter.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)

                    Spacer()

                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(SVTheme.textMuted)
                        TextField("Search...", text: $searchText)
                            .textFieldStyle(.plain)
                            .frame(width: 150)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SVTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(24)
            .background(SVTheme.surface)

            // Grid
            ScrollView {
                if filteredEntries.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(filteredEntries) { entry in
                            ItemCardView(entry: entry, listId: list.id)
                                .onTapGesture {
                                    if let item = entry.item {
                                        selectedItem = item
                                    }
                                }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(SVTheme.background)
        .task(id: liveList.id) {
            try? await db.fetchEntries(for: liveList.id)
        }
        .sheet(isPresented: $showAddItem) {
            AddItemView(listId: liveList.id)
        }
        .sheet(isPresented: $showEditList) {
            EditListView(list: liveList)
        }
        .alert("Complete List", isPresented: $showCloseSeasonConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Complete List", role: .destructive) {
                Task {
                    try? await db.closeSeason(listId: list.id)
                }
            }
        } message: {
            if unwatchedCount > 0 {
                Text("\(unwatchedCount) unwatched item\(unwatchedCount == 1 ? "" : "s") will be removed from this list. Only watched items will remain after completing it. This cannot be undone.")
            } else {
                Text("All items have been watched. The list will be marked as completed.")
            }
        }
        .alert("Delete List", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    try? await db.deleteList(id: list.id)
                    selectedList = nil
                }
            }
        } message: {
            Text("Are you sure you want to delete \"\(liveList.name)\"? All entries in this list will be removed. This cannot be undone.")
        }
    }

    private var listCoverPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [SVTheme.accent.opacity(0.35), SVTheme.card], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title)
                .foregroundStyle(SVTheme.textMuted)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "popcorn")
                .font(.system(size: 48))
                .foregroundStyle(SVTheme.textMuted)

            Text(filter == .all ? "This list is empty" : "No \(filter.rawValue.lowercased()) items")
                .font(.title3)
                .foregroundStyle(SVTheme.textSecondary)

            if filter == .all {
                Button {
                    showAddItem = true
                } label: {
                    Label("Add your first item", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(SVTheme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(60)
    }
}
