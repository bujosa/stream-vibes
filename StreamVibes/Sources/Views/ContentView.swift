import SwiftUI

struct ContentView: View {
    @Environment(DatabaseService.self) var db
    @Environment(AIService.self) var ai
    @Environment(BuddyChatController.self) var buddy
    @SecureStorage("databaseURL") private var databaseURL: String
    @AppStorage("currentUserId") private var currentUserId = ""
    @State private var isAutoConnecting = false
    @State private var showSplash = true
    @State private var pendingSelectionFromBuddy: WatchItem?

    var body: some View {
        Group {
            if showSplash && !databaseURL.isEmpty {
                SplashView(isConnecting: isAutoConnecting)
            } else if db.isConnected && !currentUserId.isEmpty {
                MainView(externalSelection: $pendingSelectionFromBuddy)
            } else {
                SetupView()
            }
        }
        .background(SVTheme.background)
        .overlay(alignment: .bottomTrailing) {
            if ai.shouldPresentTaskUI {
                AITaskCenterView()
            }
        }
        .overlay(alignment: .trailing) {
            if buddy.isPresented {
                BuddyChatView { item in
                    pendingSelectionFromBuddy = item
                }
                .transition(.move(edge: .trailing))
                .zIndex(100)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if buddy.isPresented && buddy.isMinimized {
                BuddyChatFloatingButton()
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .zIndex(101)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: buddy.isPresented)
        .animation(.easeInOut(duration: 0.25), value: buddy.isMinimized)
        .task {
            if !databaseURL.isEmpty && !db.isConnected {
                isAutoConnecting = true
                do {
                    try await db.connect(urlString: databaseURL)
                } catch {
                    db.errorMessage = error.localizedDescription
                }
                isAutoConnecting = false
            }
            // Small delay so splash feels intentional
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeOut(duration: 0.4)) {
                showSplash = false
            }
        }
        .task {
            while !Task.isCancelled {
                ai.pruneExpiredOperations()
                try? await Task.sleep(for: .seconds(900))
            }
        }
    }
}

// MARK: - Splash Screen

struct SplashView: View {
    var isConnecting: Bool
    @State private var logoScale: CGFloat = 0.8
    @State private var logoOpacity: Double = 0
    @State private var textOpacity: Double = 0

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "movieclapper.fill")
                .font(.system(size: 80))
                .foregroundStyle(SVTheme.accent)
                .scaleEffect(logoScale)
                .opacity(logoOpacity)

            Text("StreamVibes")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(SVTheme.textPrimary)
                .opacity(textOpacity)

            Text("Track what you watch together")
                .font(.title3)
                .foregroundStyle(SVTheme.textSecondary)
                .opacity(textOpacity)

            if isConnecting {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(SVTheme.accent)
                    Text("Connecting...")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                }
                .padding(.top, 20)
                .opacity(textOpacity)
            }

            Spacer()

            Text("v1.0")
                .font(.caption2)
                .foregroundStyle(SVTheme.textMuted)
                .padding(.bottom, 20)
                .opacity(textOpacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SVTheme.background)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.6).delay(0.2)) {
                textOpacity = 1.0
            }
        }
    }
}

// MARK: - Setup View

struct SetupView: View {
    @Environment(DatabaseService.self) var db
    @SecureStorage("databaseURL") private var databaseURL: String
    @AppStorage("currentUserId") private var currentUserId = ""
    @State private var urlInput = ""
    @State private var nameInput = ""
    @State private var isConnecting = false
    @State private var step: SetupStep = .database

    enum SetupStep {
        case database, profile
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                // Logo
                VStack(spacing: 8) {
                    Image(systemName: "movieclapper.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(SVTheme.accent)

                    Text("StreamVibes")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(SVTheme.textPrimary)

                    Text("Track what you watch together")
                        .font(.title3)
                        .foregroundStyle(SVTheme.textSecondary)
                }

                if step == .database {
                    databaseStep
                } else {
                    profileStep
                }

                if let error = db.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .frame(maxWidth: 480)
            .padding(40)
            .background(SVTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SVTheme.background)
        .onAppear {
            urlInput = databaseURL
            if db.isConnected && currentUserId.isEmpty {
                step = .profile
            }
        }
    }

    private var databaseStep: some View {
        VStack(spacing: 16) {
            Text("Connect to your database")
                .font(.headline)
                .foregroundStyle(SVTheme.textPrimary)

            SecureField("PostgreSQL URL", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            Button {
                Task {
                    isConnecting = true
                    db.errorMessage = nil
                    do {
                        guard CredentialStore.shared.set(urlInput, for: "databaseURL") else {
                            isConnecting = false
                            return
                        }
                        try await db.connect(urlString: urlInput)
                        step = .profile
                    } catch {
                        db.errorMessage = error.localizedDescription
                    }
                    isConnecting = false
                }
            } label: {
                HStack {
                    if isConnecting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isConnecting ? "Connecting..." : "Connect")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(SVTheme.accent)
            .disabled(urlInput.isEmpty || isConnecting)
        }
    }

    private var profileStep: some View {
        VStack(spacing: 16) {
            Text("Who are you?")
                .font(.headline)
                .foregroundStyle(SVTheme.textPrimary)

            if !db.users.isEmpty {
                VStack(spacing: 8) {
                    ForEach(db.users) { user in
                        Button {
                            currentUserId = user.id.uuidString
                        } label: {
                            HStack {
                                Image(systemName: "person.circle.fill")
                                    .font(.title2)
                                Text(user.name)
                                    .font(.headline)
                                Spacer()
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(SVTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()
                        .padding(.vertical, 4)
                }
            }

            Text(db.users.isEmpty ? "Create your profile" : "Or create a new profile")
                .font(.subheadline)
                .foregroundStyle(SVTheme.textSecondary)

            HStack {
                TextField("Your name", text: $nameInput)
                    .textFieldStyle(.roundedBorder)

                Button("Create") {
                    Task {
                        do {
                            let user = try await db.createUser(name: nameInput)
                            currentUserId = user.id.uuidString
                            nameInput = ""
                        } catch {
                            db.errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(SVTheme.accent)
                .disabled(nameInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Main View

struct MainView: View {
    @Environment(DatabaseService.self) var db
    @Environment(BuddyChatController.self) var buddy
    @Binding var externalSelection: WatchItem?
    @State private var selectedTab: AppTab = .home
    @State private var selectedList: WatchList?
    @State private var selectedItem: WatchItem?

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedTab: $selectedTab, selectedList: $selectedList, selectedItem: $selectedItem)
                .navigationSplitViewColumnWidth(min: 200, ideal: SVTheme.sidebarWidth, max: 300)
        } detail: {
            if let item = selectedItem {
                ItemDetailPageView(item: item, onBack: { selectedItem = nil }, onNavigateToItem: { selectedItem = $0 })
                    .id(item.id)
            } else {
                switch selectedTab {
                case .home:
                    HomeView(selectedTab: $selectedTab, selectedItem: $selectedItem)
                case .catalog:
                    CatalogView(selectedItem: $selectedItem)
                case .category(let cat):
                    CategoryPageView(category: cat, selectedItem: $selectedItem)
                case .lists:
                    if let list = selectedList {
                        ListDetailView(list: list, selectedItem: $selectedItem, selectedList: $selectedList)
                    } else {
                        ListsBrowserView(selectedList: $selectedList)
                    }
                }
            }
        }
        .background(SVTheme.background)
        .onChange(of: selectedItem) { _, newValue in
            buddy.currentItem = newValue
        }
        .onChange(of: externalSelection) { _, newValue in
            if let newValue {
                selectedItem = newValue
                externalSelection = nil
            }
        }
        .onAppear {
            buddy.currentItem = selectedItem
        }
    }
}
