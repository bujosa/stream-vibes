import SwiftUI

struct SettingsView: View {
    private struct CatalogMetadataIssue: Identifiable {
        let item: WatchItem
        let missingFields: [String]
        let hasBrokenImage: Bool

        var id: UUID { item.id }
    }

    private struct SeasonHealthIssue: Identifiable {
        let item: WatchItem
        let storedSeasonNumbers: [Int]
        let expectedSeasonNumbers: [Int]

        var id: UUID { item.id }

        var missingSeasonNumbers: [Int] {
            Array(Set(expectedSeasonNumbers).subtracting(storedSeasonNumbers)).sorted()
        }

        var extraSeasonNumbers: [Int] {
            Array(Set(storedSeasonNumbers).subtracting(expectedSeasonNumbers)).sorted()
        }
    }

    private struct SeasonHealthReport {
        var scannedCount: Int
        var verifiedCount: Int
        var unverifiedTitles: [String]
        var issues: [SeasonHealthIssue]
    }

    @Environment(DatabaseService.self) var db
    @Environment(AIService.self) var ai
    @Environment(\.dismiss) var dismiss
    @SecureStorage("databaseURL") private var databaseURL: String
    @AppStorage("currentUserId") private var currentUserId = ""
    @AppStorage("aiProvider") private var aiProviderRaw = "none"
    @AppStorage("aiCLIPath") private var aiCLIPath = ""
    @SecureStorage("aiAPIKey") private var aiAPIKey: String
    @SecureStorage("omdbAPIKey") private var omdbAPIKey: String
    @SecureStorage("tmdbAPIKey") private var tmdbAPIKey: String
    @AppStorage("aiCatalogSearch") private var aiCatalogSearch = true

    @State private var urlInput = ""
    @State private var testResult: Bool?
    @State private var selectedTab: SettingsTab = .general
    @State private var isTestingAI = false

    // Maintenance state
    @State private var itemsWithBrokenImages: [WatchItem] = []
    @State private var isScanning = false
    @State private var scanComplete = false
    @State private var isFixing = false
    @State private var fixProgress = 0
    @State private var fixTotal = 0
    @State private var fixedCount = 0
    @State private var metadataIssues: [CatalogMetadataIssue] = []
    @State private var isScanningMetadata = false
    @State private var metadataScanComplete = false
    @State private var isImprovingMetadata = false
    @State private var metadataImprovementSummary: AICatalogImprovementSummary?

    // Reset DB state
    @State private var showResetWarning1 = false
    @State private var showResetWarning2 = false
    @State private var isResetting = false
    @State private var resetComplete = false
    @State private var isScanningSeriesSeasons = false
    @State private var isScanningAnimeSeasons = false
    @State private var isScanningNovelaSeasons = false
    @State private var seriesSeasonProgress: String?
    @State private var animeSeasonProgress: String?
    @State private var novelaSeasonProgress: String?
    @State private var seriesSeasonReport: SeasonHealthReport?
    @State private var animeSeasonReport: SeasonHealthReport?
    @State private var novelaSeasonReport: SeasonHealthReport?

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case ai = "AI"
        case maintenance = "Maintenance"
        case about = "About"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .ai: return "sparkles"
            case .maintenance: return "wrench.and.screwdriver"
            case .about: return "info.circle"
            }
        }
    }

    private var currentUser: AppUser? {
        guard let uuid = UUID(uuidString: currentUserId) else { return nil }
        return db.users.first { $0.id == uuid }
    }

    private var selectedProvider: AIProvider {
        AIProvider(rawValue: aiProviderRaw) ?? .none
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
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

            // Tab bar
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.subheadline)
                            Text(tab.rawValue)
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .foregroundStyle(selectedTab == tab ? SVTheme.accent : SVTheme.textSecondary)
                        .background(selectedTab == tab ? SVTheme.accent.opacity(0.1) : .clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(SVTheme.surface)

            Divider().overlay(SVTheme.border)

            // Tab content
            switch selectedTab {
            case .general:
                generalTab
            case .ai:
                aiTab
            case .maintenance:
                maintenanceTab
            case .about:
                aboutTab
            }
        }
        .frame(minWidth: 600, minHeight: 520)
        .background(SVTheme.surface)
        .onAppear {
            urlInput = databaseURL
            normalizeAIPathIfNeeded()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsSection("Profile") {
                    if let user = currentUser {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(SVTheme.accent)
                            VStack(alignment: .leading) {
                                Text(user.name)
                                    .font(.headline)
                                    .foregroundStyle(SVTheme.textPrimary)
                                Text("Joined \(user.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(SVTheme.textMuted)
                            }
                            Spacer()
                            Button("Switch User") {
                                currentUserId = ""
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                settingsSection("All Users") {
                    ForEach(db.users) { user in
                        HStack {
                            Circle()
                                .fill(user.id.uuidString == currentUserId ? SVTheme.accent : SVTheme.textMuted)
                                .frame(width: 8, height: 8)
                            Text(user.name)
                                .foregroundStyle(SVTheme.textPrimary)
                            Spacer()
                            if user.id.uuidString == currentUserId {
                                Text("You")
                                    .font(.caption)
                                    .foregroundStyle(SVTheme.accent)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                settingsSection("Database") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Circle()
                                .fill(db.isConnected ? SVTheme.success : .red)
                                .frame(width: 8, height: 8)
                            Text(db.isConnected ? "Connected" : "Disconnected")
                                .font(.subheadline)
                                .foregroundStyle(SVTheme.textPrimary)
                        }

                        SecureField("PostgreSQL URL", text: $urlInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))

                        HStack {
                            Button("Reconnect") {
                                Task {
                                    guard CredentialStore.shared.set(urlInput, for: "databaseURL") else { return }
                                    db.disconnect()
                                    try? await db.connect(urlString: urlInput)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SVTheme.accent)

                            Button("Disconnect") {
                                guard CredentialStore.shared.set("", for: "databaseURL") else { return }
                                db.disconnect()
                                currentUserId = ""
                            }
                            .buttonStyle(.bordered)
                            .foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - AI Tab

    private var aiTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsSection("AI Provider") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Use AI to auto-fill item details, search titles, and more")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)

                        Picker("Provider", selection: $aiProviderRaw) {
                            ForEach(AIProvider.allCases) { provider in
                                Label(provider.label, systemImage: provider.icon).tag(provider.rawValue)
                            }
                        }
                        .onChange(of: aiProviderRaw) { _, newValue in
                            if let provider = AIProvider(rawValue: newValue) {
                                if provider.isCLI {
                                    if aiCLIPath.isEmpty || AIProvider.allCases.contains(where: { $0.isKnownPath(aiCLIPath) }) {
                                        aiCLIPath = provider.defaultPath
                                    }
                                }
                            }
                            testResult = nil
                        }

                        if selectedProvider != .none {
                            if selectedProvider.isCLI {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("CLI Path")
                                        .font(.subheadline)
                                        .foregroundStyle(SVTheme.textSecondary)
                                    TextField(selectedProvider.defaultPath, text: $aiCLIPath)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.caption, design: .monospaced))
                                }
                            } else if selectedProvider.isAPI {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("API Key")
                                        .font(.subheadline)
                                        .foregroundStyle(SVTheme.textSecondary)
                                    SecureField("Enter your API key...", text: $aiAPIKey)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }

                            AIModelSelector(provider: selectedProvider)
                                .id(selectedProvider.rawValue)

                            HStack {
                                Button {
                                    Task {
                                        isTestingAI = true
                                        defer { isTestingAI = false }
                                        testResult = await ai.testConnection()
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        if isTestingAI {
                                            ProgressView().controlSize(.small)
                                        }
                                        Text("Test Connection")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(SVTheme.accent)
                                .disabled(
                                    isTestingAI
                                    || (selectedProvider.isCLI && aiCLIPath.isEmpty)
                                    || (selectedProvider.isAPI && aiAPIKey.isEmpty)
                                )

                                if let result = testResult {
                                    HStack(spacing: 4) {
                                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        Text(result ? "Connected" : "Failed")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(result ? SVTheme.success : .red)
                                }
                            }

                            if let error = ai.lastError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }

                settingsSection("Movie Metadata (optional)") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Use your own keys for OMDb posters, ratings and episodes, or TMDB availability. These sources are skipped when no key is set.")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                        SecureField("OMDb API key", text: $omdbAPIKey)
                            .textFieldStyle(.roundedBorder)
                        SecureField("TMDB API key", text: $tmdbAPIKey)
                            .textFieldStyle(.roundedBorder)
                        Text("Credentials are saved in macOS Keychain.")
                            .font(.caption)
                            .foregroundStyle(SVTheme.textMuted)
                    }
                }

                if selectedProvider != .none {
                    settingsSection("AI Features") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle(isOn: $aiCatalogSearch) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("AI Search in Catalog")
                                        .font(.subheadline)
                                        .foregroundStyle(SVTheme.textPrimary)
                                    Text("Automatically search with AI when no local results match your catalog search")
                                        .font(.caption)
                                        .foregroundStyle(SVTheme.textMuted)
                                }
                            }
                            .tint(SVTheme.accent)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Maintenance Tab

    private var maintenanceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsSection("Catalog Health") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Missing or Broken Images")
                                    .font(.subheadline)
                                    .foregroundStyle(SVTheme.textPrimary)
                                Text("Scan your catalog to find items without working poster images")
                                    .font(.caption)
                                    .foregroundStyle(SVTheme.textMuted)
                            }
                            Spacer()
                            if scanComplete && !isScanning {
                                Text("\(itemsWithBrokenImages.count) found")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(itemsWithBrokenImages.isEmpty ? SVTheme.success.opacity(0.15) : .orange.opacity(0.15))
                                    .foregroundStyle(itemsWithBrokenImages.isEmpty ? SVTheme.success : .orange)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }

                        HStack(spacing: 8) {
                            Button {
                                Task { await scanForBrokenImages() }
                            } label: {
                                HStack(spacing: 6) {
                                    if isScanning {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "magnifyingglass")
                                    }
                                    Text(isScanning ? "Scanning..." : "Scan Catalog")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SVTheme.accent)
                            .disabled(isScanning || isFixing)

                            if !itemsWithBrokenImages.isEmpty && aiProviderRaw != "none" {
                                Button {
                                    Task { await fixBrokenImages() }
                                } label: {
                                    HStack(spacing: 6) {
                                        if isFixing {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "sparkles")
                                        }
                                        Text(isFixing ? "Fixing \(fixProgress)/\(fixTotal)..." : "Fix with AI")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                                .disabled(isScanning || isFixing)
                            }
                        }

                        if isFixing {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: Double(fixProgress), total: Double(fixTotal))
                                    .tint(.orange)
                                Text("\(fixedCount) fixed so far")
                                    .font(.caption)
                                    .foregroundStyle(SVTheme.textMuted)
                            }
                        }

                        if !isFixing && fixedCount > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(SVTheme.success)
                                Text("Fixed \(fixedCount) image\(fixedCount == 1 ? "" : "s")")
                                    .foregroundStyle(SVTheme.success)
                            }
                            .font(.caption)
                        }

                        if !itemsWithBrokenImages.isEmpty && !isFixing {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Items with missing images:")
                                    .font(.caption.bold())
                                    .foregroundStyle(SVTheme.textSecondary)

                                ForEach(itemsWithBrokenImages.prefix(20)) { item in
                                    HStack(spacing: 8) {
                                        Text(SVTheme.categoryLabel(item.category))
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(SVTheme.categoryColor(item.category).opacity(0.2))
                                            .foregroundStyle(SVTheme.categoryColor(item.category))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                        Text(item.title)
                                            .font(.caption)
                                            .foregroundStyle(SVTheme.textPrimary)
                                            .lineLimit(1)
                                        if let year = item.year {
                                            Text(String(year))
                                                .font(.caption2)
                                                .foregroundStyle(SVTheme.textMuted)
                                        }
                                    }
                                }

                                if itemsWithBrokenImages.count > 20 {
                                    Text("... and \(itemsWithBrokenImages.count - 20) more")
                                        .font(.caption)
                                        .foregroundStyle(SVTheme.textMuted)
                                }
                            }
                        }
                    }
                }

                settingsSection("Content Improvement") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Metadata Gaps")
                                    .font(.subheadline)
                                    .foregroundStyle(SVTheme.textPrimary)
                                Text("Scan for missing posters, overview, genre, year, trailer, ratings, platforms, and empty season scaffolds.")
                                    .font(.caption)
                                    .foregroundStyle(SVTheme.textMuted)
                            }
                            Spacer()
                            if metadataScanComplete && !isScanningMetadata {
                                Text("\(metadataIssues.count) found")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(metadataIssues.isEmpty ? SVTheme.success.opacity(0.15) : .orange.opacity(0.15))
                                    .foregroundStyle(metadataIssues.isEmpty ? SVTheme.success : .orange)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }

                        HStack(spacing: 8) {
                            Button {
                                Task { await scanForMetadataIssues() }
                            } label: {
                                HStack(spacing: 6) {
                                    if isScanningMetadata {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "text.magnifyingglass")
                                    }
                                    Text(isScanningMetadata ? "Scanning..." : "Scan Content")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SVTheme.accent)
                            .disabled(isScanningMetadata || isImprovingMetadata)

                            if !metadataIssues.isEmpty && aiProviderRaw != AIProvider.none.rawValue {
                                Button {
                                    let items = metadataIssues.map(\.item)
                                    Task {
                                        isImprovingMetadata = true
                                        metadataImprovementSummary = await ai.improveCatalogItems(items, db: db)
                                        isImprovingMetadata = false
                                        await scanForMetadataIssues()
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        if isImprovingMetadata {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "wand.and.stars")
                                        }
                                        Text(isImprovingMetadata ? "Running in background..." : "Improve with AI")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                                .disabled(isScanningMetadata || isImprovingMetadata)
                            }
                        }

                        if aiProviderRaw == AIProvider.none.rawValue {
                            Text("Configure an AI provider to improve incomplete content in background.")
                                .font(.caption)
                                .foregroundStyle(SVTheme.textMuted)
                        } else {
                            Text("The improvement runs through the AI Jobs panel, so you can minimize it and keep using the app.")
                                .font(.caption)
                                .foregroundStyle(SVTheme.textMuted)
                        }

                        if let summary = metadataImprovementSummary, !isImprovingMetadata {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(SVTheme.success)
                                Text("Updated \(summary.improvedCount) items, saved \(summary.seasonsSavedCount) seasons, synced \(summary.episodesSyncedCount) episodes.")
                                    .foregroundStyle(SVTheme.success)
                            }
                            .font(.caption)
                        }

                        if !metadataIssues.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Items that could be improved:")
                                    .font(.caption.bold())
                                    .foregroundStyle(SVTheme.textSecondary)

                                ForEach(metadataIssues.prefix(12)) { issue in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text(SVTheme.categoryLabel(issue.item.category))
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(SVTheme.categoryColor(issue.item.category).opacity(0.2))
                                                .foregroundStyle(SVTheme.categoryColor(issue.item.category))
                                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                            Text(issue.item.title)
                                                .font(.caption)
                                                .foregroundStyle(SVTheme.textPrimary)
                                                .lineLimit(1)
                                            if let year = issue.item.year {
                                                Text(String(year))
                                                    .font(.caption2)
                                                    .foregroundStyle(SVTheme.textMuted)
                                            }
                                        }

                                        Text(issue.missingFields.joined(separator: ", "))
                                            .font(.caption2)
                                            .foregroundStyle(issue.hasBrokenImage ? .orange : SVTheme.textMuted)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(SVTheme.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }

                                if metadataIssues.count > 12 {
                                    Text("... and \(metadataIssues.count - 12) more")
                                        .font(.caption)
                                        .foregroundStyle(SVTheme.textMuted)
                                }
                            }
                        }
                    }
                }

                settingsSection("Season Health") {
                    VStack(alignment: .leading, spacing: 18) {
                        seasonHealthTool(
                            title: "Series Seasons",
                            description: "Check whether each series in your catalog has every season stored locally.",
                            isScanning: isScanningSeriesSeasons,
                            progress: seriesSeasonProgress,
                            report: seriesSeasonReport,
                            actionTitle: "Scan Series Seasons"
                        ) {
                            Task { await scanSeasonHealth(for: "series") }
                        }

                        Divider().overlay(SVTheme.border)

                        seasonHealthTool(
                            title: "Anime Seasons",
                            description: "Check whether each anime in your catalog has every season stored locally.",
                            isScanning: isScanningAnimeSeasons,
                            progress: animeSeasonProgress,
                            report: animeSeasonReport,
                            actionTitle: "Scan Anime Seasons"
                        ) {
                            Task { await scanSeasonHealth(for: "anime") }
                        }

                        Divider().overlay(SVTheme.border)

                        seasonHealthTool(
                            title: "Telenovela Seasons",
                            description: "Check whether each novela in your catalog has every season stored locally.",
                            isScanning: isScanningNovelaSeasons,
                            progress: novelaSeasonProgress,
                            report: novelaSeasonReport,
                            actionTitle: "Scan Telenovela Seasons"
                        ) {
                            Task { await scanSeasonHealth(for: "novela") }
                        }

                        if aiProviderRaw == AIProvider.none.rawValue {
                            Text("Season health scans need an AI provider configured, because verification fetches expected season data first.")
                                .font(.caption)
                                .foregroundStyle(SVTheme.textMuted)
                        }
                    }
                }

                settingsSection("Danger Zone") {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reset Database")
                                .font(.subheadline)
                                .foregroundStyle(.red)
                            Text("Permanently delete ALL data: items, lists, ratings, comments, seasons, and users. This cannot be undone.")
                                .font(.caption)
                                .foregroundStyle(SVTheme.textMuted)
                        }

                        if resetComplete {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(SVTheme.success)
                                Text("Database has been reset. Please restart the app or re-select your user.")
                                    .foregroundStyle(SVTheme.success)
                            }
                            .font(.caption)
                        }

                        Button {
                            showResetWarning1 = true
                        } label: {
                            HStack(spacing: 6) {
                                if isResetting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "trash.fill")
                                }
                                Text(isResetting ? "Resetting..." : "Reset Everything")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(isResetting)
                        .alert("Are you sure?", isPresented: $showResetWarning1) {
                            Button("Cancel", role: .cancel) { }
                            Button("Continue", role: .destructive) {
                                showResetWarning2 = true
                            }
                        } message: {
                            Text("This will permanently delete ALL your data: every item, list, rating, comment, season, and user. There is no way to recover this data.")
                        }
                        .alert("Final Warning", isPresented: $showResetWarning2) {
                            Button("Cancel", role: .cancel) { }
                            Button("Delete Everything", role: .destructive) {
                                Task {
                                    isResetting = true
                                    resetComplete = false
                                    do {
                                        try await db.resetDatabase()
                                        currentUserId = ""
                                        resetComplete = true
                                    } catch {
                                        // silently fail
                                    }
                                    isResetting = false
                                }
                            }
                        } message: {
                            Text("LAST CHANCE. This action is IRREVERSIBLE. All \(db.catalogItems.count) items, \(db.lists.count) lists, and \(db.users.count) users will be permanently deleted.")
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func scanForBrokenImages() async {
        isScanning = true
        scanComplete = false
        itemsWithBrokenImages = []
        fixedCount = 0

        var broken: [WatchItem] = []
        for item in db.catalogItems {
            guard let urlStr = item.imageURL, !urlStr.isEmpty else {
                broken.append(item)
                continue
            }
            if !(await ai.validateImageURL(urlStr)) {
                broken.append(item)
            }
        }

        itemsWithBrokenImages = broken
        isScanning = false
        scanComplete = true
    }

    private func fixBrokenImages() async {
        isFixing = true
        fixProgress = 0
        fixTotal = itemsWithBrokenImages.count
        fixedCount = 0

        for item in itemsWithBrokenImages {
            fixProgress += 1
            if let newURL = await ai.fetchAlternativeImageURL(title: item.title, category: item.category) {
                try? await db.updateItem(
                    id: item.id,
                    title: item.title,
                    category: item.category,
                    genre: item.genre,
                    trailerURL: item.trailerURL,
                    imageURL: newURL,
                    year: item.year,
                    overview: item.overview,
                    imdbRating: item.imdbRating,
                    rottenTomatoesScore: item.rottenTomatoesScore,
                    availablePlatforms: item.availablePlatforms
                )
                fixedCount += 1
            }
        }

        isFixing = false
        // Re-scan to update the list
        await scanForBrokenImages()
    }

    private func scanForMetadataIssues() async {
        isScanningMetadata = true
        metadataScanComplete = false
        metadataIssues = []

        var issues: [CatalogMetadataIssue] = []

        for item in db.catalogItems {
            let hasImageURL = item.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let brokenImage = hasImageURL ? !(await ai.validateImageURL(item.imageURL ?? "")) : true

            var missingFields: [String] = []
            if brokenImage { missingFields.append("poster") }
            if item.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { missingFields.append("overview") }
            if item.genre?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { missingFields.append("genre") }
            if item.year == nil { missingFields.append("year") }
            if item.trailerURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { missingFields.append("trailer") }
            if item.imdbRating == nil { missingFields.append("IMDb") }
            if item.rottenTomatoesScore == nil { missingFields.append("Rotten Tomatoes") }
            if item.availablePlatforms.isEmpty || item.availablePlatforms.allSatisfy({ $0.platform == .other }) {
                missingFields.append("platforms")
            }
            if ItemCategory.categoryHasSeasons(item.category) && item.totalSeasons == 0 {
                missingFields.append("seasons")
            }

            if !missingFields.isEmpty {
                issues.append(
                    CatalogMetadataIssue(
                        item: item,
                        missingFields: missingFields,
                        hasBrokenImage: brokenImage
                    )
                )
            }
        }

        metadataIssues = issues.sorted {
            if $0.missingFields.count == $1.missingFields.count {
                return $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
            }
            return $0.missingFields.count > $1.missingFields.count
        }
        isScanningMetadata = false
        metadataScanComplete = true
    }

    private func scanSeasonHealth(for category: String) async {
        let items = db.catalogItems
            .filter { $0.category == category }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        switch category {
        case "series":
            isScanningSeriesSeasons = true
            seriesSeasonProgress = nil
            seriesSeasonReport = nil
        case "anime":
            isScanningAnimeSeasons = true
            animeSeasonProgress = nil
            animeSeasonReport = nil
        case "novela":
            isScanningNovelaSeasons = true
            novelaSeasonProgress = nil
            novelaSeasonReport = nil
        default:
            return
        }

        defer {
            switch category {
            case "series": isScanningSeriesSeasons = false
            case "anime": isScanningAnimeSeasons = false
            case "novela": isScanningNovelaSeasons = false
            default: break
            }
        }

        var issues: [SeasonHealthIssue] = []
        var verifiedCount = 0
        var unverifiedTitles: [String] = []

        for (index, item) in items.enumerated() {
            let message = "Checking \(index + 1)/\(items.count): \(item.title)"
            switch category {
            case "series": seriesSeasonProgress = message
            case "anime": animeSeasonProgress = message
            case "novela": novelaSeasonProgress = message
            default: break
            }

            let storedSeasons = ((try? await db.fetchSeasons(for: item.id)) ?? [])
                .map(\.seasonNumber)
                .sorted()
            let expectedSeasons = (await ai.fetchSeasonInfo(title: item.title, category: category) ?? [])
                .map(\.seasonNumber)
                .sorted()

            guard !expectedSeasons.isEmpty else {
                unverifiedTitles.append(item.title)
                continue
            }

            verifiedCount += 1
            let issue = SeasonHealthIssue(
                item: item,
                storedSeasonNumbers: storedSeasons,
                expectedSeasonNumbers: expectedSeasons
            )

            if !issue.missingSeasonNumbers.isEmpty || !issue.extraSeasonNumbers.isEmpty {
                issues.append(issue)
            }
        }

        let report = SeasonHealthReport(
            scannedCount: items.count,
            verifiedCount: verifiedCount,
            unverifiedTitles: unverifiedTitles,
            issues: issues
        )

        let completion = "Checked \(items.count) \(category) title\(items.count == 1 ? "" : "s")"
        switch category {
        case "series":
            seriesSeasonProgress = completion
            seriesSeasonReport = report
        case "anime":
            animeSeasonProgress = completion
            animeSeasonReport = report
        case "novela":
            novelaSeasonProgress = completion
            novelaSeasonReport = report
        default: break
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "movieclapper.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(SVTheme.accent)

                Text("StreamVibes")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(SVTheme.textPrimary)

                Text("Usable · Core catalog & watch tracking")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SVTheme.success)

                Text("v1.0")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textMuted)

                Text("Track movies, series, anime & telenovelas with your partner")
                    .font(.subheadline)
                    .foregroundStyle(SVTheme.textSecondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func normalizeAIPathIfNeeded() {
        guard selectedProvider.isCLI else { return }
        let trimmedPath = aiCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedPath.isEmpty {
            aiCLIPath = selectedProvider.defaultPath
            return
        }

        if !FileManager.default.fileExists(atPath: trimmedPath),
           selectedProvider.isKnownPath(trimmedPath),
           FileManager.default.fileExists(atPath: selectedProvider.defaultPath) {
            aiCLIPath = selectedProvider.defaultPath
        }
    }

    private func seasonHealthTool(
        title: String,
        description: String,
        isScanning: Bool,
        progress: String?,
        report: SeasonHealthReport?,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(SVTheme.textPrimary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                }

                Spacer()

                if let report {
                    Text("\(report.issues.count) issue\(report.issues.count == 1 ? "" : "s")")
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(report.issues.isEmpty ? SVTheme.success.opacity(0.15) : .orange.opacity(0.15))
                        .foregroundStyle(report.issues.isEmpty ? SVTheme.success : .orange)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            Button(action: action) {
                HStack(spacing: 6) {
                    if isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "waveform.path.ecg")
                    }
                    Text(isScanning ? "Scanning..." : actionTitle)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(SVTheme.accent)
            .disabled(isScanning || aiProviderRaw == AIProvider.none.rawValue)

            if let progress {
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(SVTheme.textSecondary)
            }

            if let report {
                Text("Verified \(report.verifiedCount) of \(report.scannedCount). Unverified: \(report.unverifiedTitles.count).")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textMuted)

                if report.issues.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(SVTheme.success)
                        Text("No season gaps found in verified titles.")
                            .foregroundStyle(SVTheme.success)
                    }
                    .font(.caption)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.issues.prefix(12)) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(issue.item.title)
                                        .font(.caption.bold())
                                        .foregroundStyle(SVTheme.textPrimary)
                                        .lineLimit(1)
                                    if let year = issue.item.year {
                                        Text(String(year))
                                            .font(.caption2)
                                            .foregroundStyle(SVTheme.textMuted)
                                    }
                                }

                                Text("Stored: \(formatSeasonNumbers(issue.storedSeasonNumbers))")
                                    .font(.caption2)
                                    .foregroundStyle(SVTheme.textMuted)

                                if !issue.missingSeasonNumbers.isEmpty {
                                    Text("Missing: \(formatSeasonNumbers(issue.missingSeasonNumbers))")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }

                                if !issue.extraSeasonNumbers.isEmpty {
                                    Text("Unexpected local seasons: \(formatSeasonNumbers(issue.extraSeasonNumbers))")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(SVTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        if report.issues.count > 12 {
                            Text("... and \(report.issues.count - 12) more")
                                .font(.caption)
                                .foregroundStyle(SVTheme.textMuted)
                        }
                    }
                }

                if !report.unverifiedTitles.isEmpty {
                    Text("Couldn't verify: \(report.unverifiedTitles.prefix(6).joined(separator: ", "))\(report.unverifiedTitles.count > 6 ? "..." : "")")
                        .font(.caption2)
                        .foregroundStyle(SVTheme.textMuted)
                }
            }
        }
    }

    private func formatSeasonNumbers(_ numbers: [Int]) -> String {
        guard !numbers.isEmpty else { return "None" }
        return numbers.map(String.init).joined(separator: ", ")
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(SVTheme.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SVTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: SVTheme.cornerRadius))
        }
    }
}
