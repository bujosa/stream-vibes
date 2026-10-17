import SwiftUI

struct ListsBrowserView: View {
    @Environment(DatabaseService.self) var db
    @Binding var selectedList: WatchList?
    @State private var showAddList = false
    @State private var searchText = ""

    private var filtered: [WatchList] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return db.lists
        }
        return db.lists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var activeLists: [WatchList] {
        filtered.filter { $0.isActive }
    }

    var completedLists: [WatchList] {
        filtered.filter { !$0.isActive }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lists")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(SVTheme.textPrimary)
                        Text("Your watch playlists")
                            .font(.subheadline)
                            .foregroundStyle(SVTheme.textSecondary)
                    }
                    Spacer()

                    Button {
                        showAddList = true
                    } label: {
                        Label("New List", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SVTheme.accent)

                    SettingsButton()
                }

                // Search
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(SVTheme.textMuted)
                    TextField("Search lists...", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: 300)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(SVTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Active Lists
                if !activeLists.isEmpty {
                    sectionHeader("Currently Watching", icon: "play.circle.fill", color: SVTheme.accent)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 16)], spacing: 16) {
                        ForEach(activeLists) { list in
                            listCard(list)
                        }
                    }
                }

                // Completed Lists
                if !completedLists.isEmpty {
                    sectionHeader("Completed", icon: "checkmark.circle.fill", color: SVTheme.success)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 16)], spacing: 16) {
                        ForEach(completedLists) { list in
                            listCard(list)
                        }
                    }
                }

                // Empty state
                if db.lists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 48))
                            .foregroundStyle(SVTheme.textMuted)
                        Text("No lists yet")
                            .font(.title3)
                            .foregroundStyle(SVTheme.textSecondary)
                        Text("Create a playlist to organize what you watch together")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                        Button {
                            showAddList = true
                        } label: {
                            Label("Create your first list", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(SVTheme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(60)
                }
            }
            .padding(24)
        }
        .background(SVTheme.background)
        .sheet(isPresented: $showAddList) {
            AddListView()
        }
    }

    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(SVTheme.textPrimary)
        }
    }

    private func listCard(_ list: WatchList) -> some View {
        Button {
            selectedList = list
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    Group {
                        if let imageURL = list.imageURL,
                           !imageURL.isEmpty,
                           let url = URL(string: imageURL) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().aspectRatio(contentMode: .fill)
                                default:
                                    listCoverPlaceholder(list)
                                }
                            }
                        } else {
                            listCoverPlaceholder(list)
                        }
                    }
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    Text(list.name)
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(10)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if let desc = list.description, !desc.isEmpty {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(SVTheme.textMuted)
                                .lineLimit(2)
                        }

                        Text("Created by \(list.createdByName ?? "Unknown") on \(list.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption2)
                            .foregroundStyle(SVTheme.textMuted)
                            .lineLimit(1)
                    }
                    Spacer()

                    if !list.isActive {
                        Text("Completed")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(SVTheme.success.opacity(0.2))
                            .foregroundStyle(SVTheme.success)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                ProgressView(value: list.progress)
                    .tint(list.isActive ? SVTheme.accent : SVTheme.success)

                HStack {
                    Label("\(list.totalItems) items", systemImage: "film.stack")
                    Spacer()
                    Label("\(list.watchedItems) watched", systemImage: "checkmark.circle")
                    Spacer()
                    if list.totalItems > 0 {
                        Text("\(Int(list.progress * 100))%")
                            .fontWeight(.bold)
                            .foregroundStyle(SVTheme.accent)
                    }
                }
                .font(.caption)
                .foregroundStyle(SVTheme.textMuted)
            }
            .padding(16)
            .background(SVTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func listCoverPlaceholder(_ list: WatchList) -> some View {
        ZStack {
            LinearGradient(
                colors: [SVTheme.accent.opacity(0.35), SVTheme.card],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}
