import SwiftUI

struct SidebarView: View {
    @Environment(DatabaseService.self) var db
    @Binding var selectedTab: AppTab
    @Binding var selectedList: WatchList?
    @Binding var selectedItem: WatchItem?
    @State private var showAddList = false
    @State private var showSettings = false
    @State private var editingList: WatchList?
    @AppStorage("sidebarShowCompleted") private var showCompleted = false

    var activeLists: [WatchList] {
        db.lists.filter { $0.isActive }
    }

    var completedLists: [WatchList] {
        db.lists.filter { !$0.isActive }.sorted { ($0.createdAt) > ($1.createdAt) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // App Header
            HStack(spacing: 8) {
                Image(systemName: "movieclapper.fill")
                    .font(.title2)
                    .foregroundStyle(SVTheme.accent)
                Text("StreamVibes")
                    .font(.headline)
                    .foregroundStyle(SVTheme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .overlay(SVTheme.border)

            // Navigation
            List {
                // Main Tabs
                Section {
                    sidebarButton(label: "Home", icon: "house.fill", tab: .home)
                    sidebarButton(label: "Catalog", icon: "square.grid.2x2.fill", tab: .catalog)
                    sidebarButton(label: "Lists", icon: "list.bullet.rectangle.fill", tab: .lists, action: {
                        selectedItem = nil
                        selectedTab = .lists
                        selectedList = nil
                    })
                }

                // Browse by Category
                Section("Browse") {
                    ForEach(ItemCategory.allCases) { cat in
                        categoryButton(cat)
                    }
                }

                // Active Lists
                Section("Currently Watching") {
                    ForEach(activeLists) { list in
                        listRow(list)
                    }

                    if activeLists.isEmpty {
                        Text("No active lists")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                            .padding(.vertical, 4)
                    }
                }

                // Completed Lists (collapsed by default)
                if !completedLists.isEmpty {
                    Section {
                        if showCompleted {
                            ForEach(completedLists.prefix(5)) { list in
                                listRow(list)
                            }
                            if completedLists.count > 5 {
                                Button {
                                    selectedItem = nil
                                    selectedTab = .lists
                                    selectedList = nil
                                } label: {
                                    Text("See all \(completedLists.count) in Lists")
                                        .font(.caption2)
                                        .foregroundStyle(SVTheme.accent)
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 2)
                            }
                        }
                    } header: {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showCompleted.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("Completed")
                                Text("\(completedLists.count)")
                                    .font(.caption2)
                                    .foregroundStyle(SVTheme.textMuted)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(SVTheme.card)
                                    .clipShape(Capsule())
                                Spacer()
                                Image(systemName: showCompleted ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                                    .foregroundStyle(SVTheme.textMuted)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
                .overlay(SVTheme.border)

            // Add List Button
            Button {
                showAddList = true
            } label: {
                Label("New List", systemImage: "plus.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .buttonStyle(.plain)

            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            .buttonStyle(.plain)

            // Connection Status
            HStack(spacing: 6) {
                Circle()
                    .fill(db.isConnected ? SVTheme.success : .red)
                    .frame(width: 6, height: 6)
                Text(db.isConnected ? "Connected" : "Disconnected")
                    .font(.caption2)
                    .foregroundStyle(SVTheme.textMuted)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .background(SVTheme.surface)
        .sheet(isPresented: $showAddList) {
            AddListView()
        }
        .sheet(item: $editingList) { list in
            EditListView(list: list)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private func categoryButton(_ cat: ItemCategory) -> some View {
        let isSelected = selectedTab == .category(cat) && selectedList == nil
        let count = db.catalogItems.filter { $0.category == cat.rawValue }.count

        return Button {
            selectedItem = nil
            selectedTab = .category(cat)
            selectedList = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: cat.icon)
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? SVTheme.categoryColor(cat.rawValue) : SVTheme.categoryColor(cat.rawValue).opacity(0.7))
                    .frame(width: 20)
                Text(cat.label)
                    .foregroundStyle(isSelected ? SVTheme.categoryColor(cat.rawValue) : SVTheme.textSecondary)
                Spacer()
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(SVTheme.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(SVTheme.card)
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private func sidebarButton(label: String, icon: String, tab: AppTab, action: (() -> Void)? = nil) -> some View {
        Button {
            if let action {
                action()
            } else {
                selectedItem = nil
                selectedTab = tab
                selectedList = nil
            }
        } label: {
            Label(label, systemImage: icon)
                .foregroundStyle(selectedTab == tab && selectedList == nil ? SVTheme.accent : SVTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func listRow(_ list: WatchList) -> some View {
        Button {
            selectedItem = nil
            selectedTab = .lists
            selectedList = list
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(list.name)
                        .font(.subheadline)
                        .foregroundStyle(selectedList?.id == list.id ? SVTheme.accent : SVTheme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text("\(list.watchedItems)/\(list.totalItems)")
                            .font(.caption2)
                            .foregroundStyle(SVTheme.textMuted)

                        if list.totalItems > 0 {
                            ProgressView(value: list.progress)
                                .tint(SVTheme.accent)
                                .frame(width: 40)
                        }
                    }

                    Text("by \(list.createdByName ?? "Unknown") · \(list.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(SVTheme.textMuted.opacity(0.9))
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") { editingList = list }
            Divider()
            Button("Delete", role: .destructive) {
                Task {
                    try? await db.deleteList(id: list.id)
                    if selectedList?.id == list.id {
                        selectedList = nil
                    }
                }
            }
        }
    }
}

// MARK: - Add List

struct AddListView: View {
    @Environment(DatabaseService.self) var db
    @Environment(AIService.self) var ai
    @Environment(\.dismiss) var dismiss
    @AppStorage("currentUserId") private var currentUserId = ""
    @AppStorage("aiProvider") private var aiProviderRaw = "none"
    @State private var name = ""
    @State private var description = ""
    @State private var imageURL = ""
    @State private var bannerImageURL = ""
    @State private var aiMessage: String?
    @State private var isGeneratingVibe = false

    private var currentUserUUID: UUID? {
        UUID(uuidString: currentUserId)
    }

    private var aiEnabled: Bool {
        aiProviderRaw != AIProvider.none.rawValue
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("New Watch List")
                .font(.title2.bold())
                .foregroundStyle(SVTheme.textPrimary)

            // AI Vibe Generator
            if aiEnabled {
                Button {
                    Task { await generateVibe() }
                } label: {
                    HStack(spacing: 8) {
                        if isGeneratingVibe {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Generate Vibe with AI")
                                .font(.subheadline.bold())
                            Text("Auto-create name, description & covers")
                                .font(.caption2)
                                .foregroundStyle(SVTheme.textMuted)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                .tint(SVTheme.anime)
                .disabled(isGeneratingVibe)

                if let aiMessage {
                    Text(aiMessage)
                        .font(.caption2)
                        .foregroundStyle(SVTheme.textMuted)
                }
                if let error = ai.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                TextField("e.g. Horror Season, Anime Binge 2024", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Description (optional)")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                TextField("What's this list about?", text: $description)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Card Cover URL (optional)")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)

                TextField("https://...", text: $imageURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))

                if let url = URL(string: imageURL), !imageURL.isEmpty {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Banner URL (optional)")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)

                TextField("https://...", text: $bannerImageURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))

                if let url = URL(string: bannerImageURL), !bannerImageURL.isEmpty {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Create") {
                    Task {
                        try? await db.createList(
                            name: name,
                            description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description.trimmingCharacters(in: .whitespacesAndNewlines),
                            imageURL: imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : imageURL.trimmingCharacters(in: .whitespacesAndNewlines),
                            bannerImageURL: bannerImageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bannerImageURL.trimmingCharacters(in: .whitespacesAndNewlines),
                            createdBy: currentUserUUID
                        )
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(SVTheme.accent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(SVTheme.surface)
    }

    private func generateVibe() async {
        guard aiEnabled else { return }
        aiMessage = nil
        isGeneratingVibe = true
        defer { isGeneratingVibe = false }

        let items = db.currentEntries.compactMap { $0.item?.title }
        if let vibe = await ai.generateListVibe(currentName: name, currentDescription: description, itemTitles: items) {
            if let vibeDesc = vibe.description { description = vibeDesc }
            if let vibeImage = vibe.imageURL { imageURL = vibeImage }
            if let vibeBanner = vibe.bannerImageURL { bannerImageURL = vibeBanner }
            aiMessage = "Vibe generated!"
        } else {
            aiMessage = "AI could not generate a vibe."
        }
    }
}

// MARK: - Edit List

struct EditListView: View {
    @Environment(DatabaseService.self) var db
    @Environment(AIService.self) var ai
    @AppStorage("aiProvider") private var aiProviderRaw = "none"
    @Environment(\.dismiss) var dismiss
    let list: WatchList
    @State private var name = ""
    @State private var description = ""
    @State private var imageURL = ""
    @State private var bannerImageURL = ""
    @State private var isActive = true
    @State private var aiMessage: String?
    @State private var isGeneratingVibe = false

    private var aiEnabled: Bool {
        aiProviderRaw != AIProvider.none.rawValue
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit List")
                .font(.title2.bold())
                .foregroundStyle(SVTheme.textPrimary)

            // AI Vibe Generator
            if aiEnabled {
                Button {
                    Task { await generateVibe() }
                } label: {
                    HStack(spacing: 8) {
                        if isGeneratingVibe {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Regenerate Vibe with AI")
                                .font(.subheadline.bold())
                            Text("Refresh description & covers")
                                .font(.caption2)
                                .foregroundStyle(SVTheme.textMuted)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                .tint(SVTheme.anime)
                .disabled(isGeneratingVibe)

                if let aiMessage {
                    Text(aiMessage)
                        .font(.caption2)
                        .foregroundStyle(SVTheme.textMuted)
                }
                if let error = ai.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                TextField("List name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Description")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
                TextField("Description", text: $description)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Card Cover URL")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)

                TextField("https://...", text: $imageURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Banner URL")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)

                TextField("https://...", text: $bannerImageURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }

            Toggle("Active", isOn: $isActive)
                .foregroundStyle(SVTheme.textPrimary)

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    Task {
                        try? await db.updateList(
                            id: list.id,
                            name: name,
                            description: description.isEmpty ? nil : description,
                            imageURL: imageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : imageURL.trimmingCharacters(in: .whitespacesAndNewlines),
                            bannerImageURL: bannerImageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bannerImageURL.trimmingCharacters(in: .whitespacesAndNewlines),
                            isActive: isActive
                        )
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(SVTheme.accent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(SVTheme.surface)
        .onAppear {
            name = list.name
            description = list.description ?? ""
            imageURL = list.imageURL ?? ""
            bannerImageURL = list.bannerImageURL ?? ""
            isActive = list.isActive
        }
    }

    private func generateVibe() async {
        guard aiEnabled else { return }
        aiMessage = nil
        isGeneratingVibe = true
        defer { isGeneratingVibe = false }

        let items = db.currentEntries.compactMap { $0.item?.title }
        if let vibe = await ai.generateListVibe(currentName: name, currentDescription: description, itemTitles: items) {
            if let vibeDesc = vibe.description { description = vibeDesc }
            if let vibeImage = vibe.imageURL { imageURL = vibeImage }
            if let vibeBanner = vibe.bannerImageURL { bannerImageURL = vibeBanner }
            aiMessage = "Vibe generated!"
        } else {
            aiMessage = "AI could not generate a vibe."
        }
    }
}
