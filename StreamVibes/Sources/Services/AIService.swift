import Foundation



struct AIAutoFillResult: Sendable {
    var imageURL: String?
    var year: Int?
    var overview: String?
    var genre: String?
    var trailerURL: String?
    var seasons: [AISeasonResult]?
    var imdbRating: Double?
    var rottenTomatoesScore: Int?
    var availablePlatforms: [PlatformAvailability] = []
}

struct AISeasonResult: Sendable {
    var seasonNumber: Int
    var name: String?
    var year: Int?
    var episodeCount: Int?
    var imageURL: String?
    var trailerURL: String?
    var overview: String?
}

struct AIEpisodeResult: Sendable {
    var episodeNumber: Int
    var title: String?
    var overview: String?
    var airDate: String?
    var runtimeMinutes: Int?
}

struct AISearchResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    var title: String
    var category: String
    var year: Int?
    var imageURL: String?
    var overview: String?
    var genre: String?
    var trailerURL: String?
    var imdbRating: Double?
    var rottenTomatoesScore: Int?
    var availablePlatforms: [PlatformAvailability] = []
}

struct AIListVibeResult: Sendable {
    var description: String?
    var imageURL: String?
    var bannerImageURL: String?
    var coverItemTitle: String?
    var bannerItemTitle: String?
}

struct AICatalogImprovementSummary: Sendable {
    var processedCount: Int
    var improvedCount: Int
    var seasonsSavedCount: Int
    var episodesSyncedCount: Int
}

enum AIOperationStatus: String, Hashable {
    case running
    case completed
    case failed
    case cancelled

    var isFinished: Bool {
        self != .running
    }
}

struct AIOperationSnapshot: Identifiable, Hashable {
    let id: UUID
    var title: String
    var progressMessage: String?
    var isMinimized: Bool
    var canCancel: Bool
    var startedAt: Date
    var status: AIOperationStatus
    var summary: String?
    var completedAt: Date?
}

private struct ExternalMetadata {
    var imageURL: String?
    var year: Int?
    var overview: String?
    var genre: String?
    var trailerURL: String?
    var imdbRating: Double?
    var rottenTomatoesScore: Int?
    var availablePlatforms: [PlatformAvailability] = []

    var hasSpecificPlatform: Bool {
        availablePlatforms.contains { $0.platform != .other }
    }

    var hasRichMatch: Bool {
        imdbRating != nil && rottenTomatoesScore != nil && hasSpecificPlatform
    }

    mutating func mergeMissingValues(from other: ExternalMetadata) {
        if imageURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            imageURL = other.imageURL
        }
        if year == nil {
            year = other.year
        }
        if overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            overview = other.overview
        }
        if genre?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            genre = other.genre
        }
        if trailerURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            trailerURL = other.trailerURL
        }
        if imdbRating == nil {
            imdbRating = other.imdbRating
        }
        if rottenTomatoesScore == nil {
            rottenTomatoesScore = other.rottenTomatoesScore
        }
        availablePlatforms = PlatformAvailability.merged(preferred: availablePlatforms, fallback: other.availablePlatforms)
    }
}

@Observable
@MainActor
final class AIService {
    @TaskLocal static var currentOperationID: UUID?

    typealias OperationRerunAction = @MainActor @Sendable () async -> Void

    var operations: [AIOperationSnapshot] = []
    var lastError: String?
    var lastOperationWasCancelled = false
    var isJobsPanelVisible = UserDefaults.standard.object(forKey: "showAIJobsPanel") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(isJobsPanelVisible, forKey: "showAIJobsPanel")
        }
    }

    private final class OperationRuntime: @unchecked Sendable {
        let id: UUID
        var activeProcess: Process?
        var activeDataTask: URLSessionDataTask?
        var cancellationRequested = false

        init(id: UUID) {
            self.id = id
        }
    }

    private var operationRuntimes: [UUID: OperationRuntime] = [:]
    private var rerunActions: [UUID: OperationRerunAction] = [:]
    private var focusedOperationID: UUID?
    private let finishedOperationRetentionInterval: TimeInterval = 60 * 60 * 6

    var isProcessing: Bool {
        !activeOperations.isEmpty
    }

    var isOverlayMinimized: Bool {
        foregroundOperation == nil
    }

    var canCancelOperation: Bool {
        foregroundOperation?.canCancel == true
    }

    var progressMessage: String? {
        foregroundOperation?.progressMessage ?? dockOperations.last?.progressMessage
    }

    var activeOperations: [AIOperationSnapshot] {
        operations
            .filter { $0.status == .running }
            .sorted { $0.startedAt < $1.startedAt }
    }

    var recentOperations: [AIOperationSnapshot] {
        operations
            .filter { $0.status.isFinished }
            .sorted { ($0.completedAt ?? $0.startedAt) > ($1.completedAt ?? $1.startedAt) }
    }

    var shouldPresentTaskUI: Bool {
        foregroundOperation != nil || isJobsPanelVisible
    }

    var foregroundOperation: AIOperationSnapshot? {
        guard let focusedOperationID else { return nil }
        return activeOperations.first { $0.id == focusedOperationID && !$0.isMinimized }
    }

    var dockOperations: [AIOperationSnapshot] {
        activeOperations
            .filter { $0.id != focusedOperationID || $0.isMinimized }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private static let strictJSONRules = """
    Return exactly one JSON object and nothing else.
    Do not use markdown, code fences, notes, explanations, apologies, permission requests, or web-search disclaimers.
    Use canonical official data for the requested title only. Do not invent titles, seasons, episodes, dates, runtimes, or URLs.
    If a field is unknown, use null, an empty string, or an empty array instead of guessing.
    """

    private func promptHintClause(_ hint: String?) -> String {
        let trimmed = (hint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let normalized = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return """

        Additional user note for disambiguation: "\(normalized)".
        Use this note only to identify the intended title, platform, version, remake, adaptation, region, or timeframe.
        """
    }

    private func hintSearchFragments(_ hint: String?) -> [String] {
        let trimmed = (hint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var fragments: [String] = []

        func append(_ value: String?) {
            guard let value = normalizedHintFragment(value) else { return }
            if !fragments.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                fragments.append(value)
            }
        }

        var nonURLHint = trimmed
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let matches = detector.matches(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed))
            for match in matches {
                guard let range = Range(match.range, in: trimmed) else { continue }
                nonURLHint.replaceSubrange(range, with: " ")

                guard let url = match.url else { continue }
                append(url.host?.replacingOccurrences(of: "www.", with: ""))

                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    let interestingQueryKeys = ["title", "name", "q", "query", "movie", "show", "series", "anime", "slug"]
                    for item in components.queryItems ?? [] where interestingQueryKeys.contains(item.name.lowercased()) {
                        append(item.value)
                    }
                }

                for component in url.pathComponents.suffix(4) {
                    append(component)
                }
            }
        }

        append(nonURLHint)
        return Array(fragments.prefix(5))
    }

    private func normalizedHintFragment(_ raw: String?) -> String? {
        guard let raw else { return nil }

        let decoded = raw.removingPercentEncoding ?? raw
        let withoutExtension = decoded.replacingOccurrences(
            of: #"\.[a-z0-9]{2,4}$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let normalized = withoutExtension
            .replacingOccurrences(of: #"[_\-.+]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(tt\d+|nm\d+|id\d+)\b"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.rangeOfCharacter(from: .letters) != nil else { return nil }
        guard normalized.count >= 3 else { return nil }
        return normalized
    }

    private static let autoFillPromptTemplate = """
    For the %@ titled "%@", provide the following information:
    {
      "imageURL": "a direct publicly accessible image URL for the official poster or cover art. Prefer URLs from Wikipedia/Wikimedia Commons (e.g. https://upload.wikimedia.org/wikipedia/en/...) or other stable sources. Do NOT use TMDB URLs. Use empty string if unknown",
      "year": the release year as a number or null if unknown,
      "overview": "a 1-2 sentence description of the plot",
      "genre": "primary genre (e.g. Action, Comedy, Drama, Horror, Sci-Fi, Romance, Thriller, Fantasy, Slice of Life, Mecha, Shonen) or empty string if unknown",
      "trailerURL": "a public trailer URL. Prefer YouTube, but Vimeo, Apple/iTunes preview URLs, or a direct video URL are also valid. Use empty string if unknown",
      "imdbRating": 8.2 or null,
      "rottenTomatoesScore": 94 or null,
      "platforms": [
        {
          "name": "Apple TV+" ,
          "availability": "streaming",
          "url": "https://..."
        }
      ]
    }
    Use the canonical release for this exact title.
    If this is a series or anime, describe the show overall, not a single season or episode.
    For platforms, prefer a specific named service such as Apple TV+, Netflix, Max, Crunchyroll, Disney+, Hulu, Prime Video, Peacock, Paramount+, YouTube, or Theaters.
    Do not return a generic "Other" platform when a specific service is identifiable. If you are not sure, return an empty array instead.
    \(strictJSONRules)
    """

    func minimizeOverlay() {
        guard let focusedOperationID else { return }
        minimizeOperation(id: focusedOperationID)
    }

    func showJobsPanel() {
        pruneExpiredOperations()
        isJobsPanelVisible = true
    }

    func hideJobsPanel() {
        isJobsPanelVisible = false
    }

    func toggleJobsPanel() {
        pruneExpiredOperations()
        isJobsPanelVisible.toggle()
    }

    func restoreOverlay() {
        guard let operation = dockOperations.last else { return }
        restoreOperation(id: operation.id)
    }

    func cancelCurrentOperation() {
        guard let focusedOperationID else { return }
        cancelOperation(id: focusedOperationID)
    }

    func minimizeOperation(id: UUID) {
        mutateOperation(id) { operation in
            operation.isMinimized = true
        }
        if focusedOperationID == id {
            focusedOperationID = nil
        }
    }

    func restoreOperation(id: UUID) {
        if let focusedOperationID, focusedOperationID != id {
            mutateOperation(focusedOperationID) { operation in
                operation.isMinimized = true
            }
        }
        mutateOperation(id) { operation in
            operation.isMinimized = false
        }
        focusedOperationID = id
    }

    func cancelOperation(id: UUID) {
        guard let runtime = operationRuntimes[id] else { return }
        runtime.cancellationRequested = true
        lastOperationWasCancelled = true
        setProgress("Canceling...", for: id)
        runtime.activeDataTask?.cancel()
        if let process = runtime.activeProcess, process.isRunning {
            process.terminate()
        }
    }

    func rerunOperation(id: UUID) {
        pruneExpiredOperations()
        guard let rerun = rerunActions[id] else { return }
        Task {
            await rerun()
        }
    }

    func dismissOperation(id: UUID) {
        operations.removeAll { $0.id == id }
        operationRuntimes[id] = nil
        rerunActions[id] = nil
        if focusedOperationID == id {
            focusedOperationID = nil
        }
    }

    func clearFinishedOperations() {
        let activeIDs = Set(activeOperations.map(\.id))
        let removedIDs = operations
            .filter { !activeIDs.contains($0.id) }
            .map(\.id)

        operations.removeAll { !activeIDs.contains($0.id) }
        removedIDs.forEach { rerunActions[$0] = nil }
        if let focusedOperationID, !activeIDs.contains(focusedOperationID) {
            self.focusedOperationID = nil
        }
    }

    func canRerunOperation(id: UUID) -> Bool {
        rerunActions[id] != nil
    }

    func pruneExpiredOperations() {
        let cutoff = Date().addingTimeInterval(-finishedOperationRetentionInterval)
        let removedIDs = operations
            .filter { operation in
                guard let completedAt = operation.completedAt else { return false }
                return operation.status.isFinished && completedAt < cutoff
            }
            .map(\.id)

        guard !removedIDs.isEmpty else { return }
        let removedSet = Set(removedIDs)
        operations.removeAll { removedSet.contains($0.id) }
        removedIDs.forEach { rerunActions[$0] = nil }
        if let focusedOperationID, removedSet.contains(focusedOperationID) {
            self.focusedOperationID = nil
        }
    }

    private func beginOperation(
        title: String,
        initialMessage: String,
        rerunAction: OperationRerunAction? = nil
    ) -> UUID {
        pruneExpiredOperations()
        if let focusedOperationID {
            mutateOperation(focusedOperationID) { operation in
                operation.isMinimized = true
            }
        }

        let id = UUID()
        operations.append(
            AIOperationSnapshot(
                id: id,
                title: title,
                progressMessage: initialMessage,
                isMinimized: false,
                canCancel: true,
                startedAt: Date(),
                status: .running,
                summary: nil,
                completedAt: nil
            )
        )
        operationRuntimes[id] = OperationRuntime(id: id)
        if let rerunAction {
            rerunActions[id] = rerunAction
        }
        focusedOperationID = id
        lastOperationWasCancelled = false
        lastError = nil
        return id
    }

    private func completeOperation(
        _ id: UUID,
        status: AIOperationStatus,
        summary: String? = nil
    ) {
        operationRuntimes[id]?.activeProcess = nil
        operationRuntimes[id]?.activeDataTask = nil
        operationRuntimes[id] = nil
        mutateOperation(id) { operation in
            operation.status = status
            operation.canCancel = false
            operation.isMinimized = true
            operation.summary = summary
            operation.completedAt = Date()
        }
        if focusedOperationID == id {
            focusedOperationID = nil
        }
        pruneExpiredOperations()
    }

    private func throwIfCancelled() throws {
        if isCancellationRequested() {
            throw AIError.cancelled
        }
    }

    private func handleOperationError(_ error: Error, operationID: UUID? = nil) {
        let status: AIOperationStatus
        let summary: String

        if let aiError = error as? AIError, case .cancelled = aiError {
            lastError = AIError.cancelled.localizedDescription
            status = .cancelled
            summary = "Canceled before completion."
        } else {
            lastError = error.localizedDescription
            status = .failed
            summary = error.localizedDescription
        }

        if let operationID {
            completeOperation(operationID, status: status, summary: summary)
        }
    }

    private func mutateOperation(_ id: UUID, _ mutate: (inout AIOperationSnapshot) -> Void) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&operations[index])
    }

    private func setProgress(_ message: String?, for id: UUID? = nil) {
        guard let operationID = id ?? Self.currentOperationID else { return }
        mutateOperation(operationID) { operation in
            operation.progressMessage = message
        }
    }

    private func setActiveProcess(_ process: Process?, for id: UUID?) {
        guard let id, let runtime = operationRuntimes[id] else { return }
        runtime.activeProcess = process
    }

    private func setActiveDataTask(_ task: URLSessionDataTask?, for id: UUID?) {
        guard let id, let runtime = operationRuntimes[id] else { return }
        runtime.activeDataTask = task
    }

    private func isCancellationRequested(for id: UUID? = nil) -> Bool {
        guard let operationID = id ?? Self.currentOperationID,
              let runtime = operationRuntimes[operationID] else { return false }
        return runtime.cancellationRequested
    }

    private func buildAutoFillSummary(from result: AIAutoFillResult) -> String {
        var parts: [String] = []
        if result.imageURL != nil { parts.append("poster") }
        if result.trailerURL != nil { parts.append("trailer") }
        if result.overview != nil { parts.append("overview") }
        if result.genre != nil { parts.append("genre") }
        if result.year != nil { parts.append("year") }
        if result.imdbRating != nil { parts.append("IMDb") }
        if result.rottenTomatoesScore != nil { parts.append("Rotten Tomatoes") }
        if !result.availablePlatforms.isEmpty { parts.append("\(result.availablePlatforms.count) platforms") }
        if let seasons = result.seasons, !seasons.isEmpty {
            parts.append("\(seasons.count) seasons")
        }

        guard !parts.isEmpty else {
            return "Finished, but there was little metadata to save."
        }

        var summary = "Completed with " + ListFormatter.localizedString(byJoining: parts) + "."
        var missing: [String] = []
        if result.rottenTomatoesScore == nil { missing.append("Rotten Tomatoes") }
        if result.availablePlatforms.isEmpty || result.availablePlatforms.allSatisfy({ $0.platform == .other }) {
            missing.append("specific platforms")
        }
        if !missing.isEmpty {
            summary += " Still missing " + ListFormatter.localizedString(byJoining: missing) + "."
        }
        return summary
    }

    private func buildSearchSummary(resultCount: Int) -> String {
        switch resultCount {
        case 0:
            return "No matching titles found."
        case 1:
            return "Found 1 matching title."
        default:
            return "Found \(resultCount) matching titles."
        }
    }

    private func buildListVibeSummary(from result: AIListVibeResult) -> String {
        var parts: [String] = []
        if result.description != nil { parts.append("description") }
        if result.imageURL != nil { parts.append("cover image") }
        if result.bannerImageURL != nil { parts.append("banner image") }

        guard !parts.isEmpty else {
            return "Finished, but there were no new vibe suggestions."
        }

        return "Generated " + ListFormatter.localizedString(byJoining: parts) + "."
    }

    private func buildCatalogImprovementSummary(from result: AICatalogImprovementSummary) -> String {
        var parts = ["processed \(result.processedCount) item\(result.processedCount == 1 ? "" : "s")"]
        if result.improvedCount > 0 {
            parts.append("updated \(result.improvedCount)")
        }
        if result.seasonsSavedCount > 0 {
            parts.append("saved \(result.seasonsSavedCount) season\(result.seasonsSavedCount == 1 ? "" : "s")")
        }
        if result.episodesSyncedCount > 0 {
            parts.append("synced \(result.episodesSyncedCount) episode\(result.episodesSyncedCount == 1 ? "" : "s")")
        }
        return "Catalog improvement finished: " + ListFormatter.localizedString(byJoining: parts) + "."
    }

    private func autoFillCore(title: String, category: String, hint: String? = nil) async throws -> AIAutoFillResult? {
        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        guard provider != .none else {
            lastError = "No AI provider configured"
            return nil
        }

        let prompt = String(format: Self.autoFillPromptTemplate, category, title) + promptHintClause(hint)

        try throwIfCancelled()
        setProgress("Generating metadata...")
        let output = try await runPrompt(provider: provider, prompt: prompt)

        try throwIfCancelled()
        setProgress("Parsing response...")
        guard var result = parseAutoFillResponse(output) else {
            return nil
        }

        try throwIfCancelled()
        setProgress("Checking trusted sources...")
        let trustedMetadata = await fetchTrustedMetadata(title: title, category: category, hint: hint)
        if result.year == nil {
            result.year = trustedMetadata.year
        }
        if result.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            result.overview = trustedMetadata.overview
        }
        if result.genre?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            result.genre = trustedMetadata.genre
        }
        if result.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            result.imageURL = trustedMetadata.imageURL
        }
        if result.trailerURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            result.trailerURL = trustedMetadata.trailerURL
        }
        if result.imdbRating == nil {
            result.imdbRating = trustedMetadata.imdbRating
        }
        if result.rottenTomatoesScore == nil {
            result.rottenTomatoesScore = trustedMetadata.rottenTomatoesScore
        }
        if result.availablePlatforms.isEmpty {
            result.availablePlatforms = trustedMetadata.availablePlatforms
        }

        var imageValid = false
        if let imageURL = result.imageURL {
            try throwIfCancelled()
            setProgress("Validating image...")
            imageValid = await validateImageURL(imageURL)
        }
        if !imageValid {
            try throwIfCancelled()
            setProgress("Searching for poster image...")
            if let trustedImageURL = trustedMetadata.imageURL {
                result.imageURL = trustedImageURL
            } else {
                result.imageURL = await searchImageURL(title: title, category: category)
            }
        }

        var trailerValid = false
        if let trailerURL = result.trailerURL {
            try throwIfCancelled()
            setProgress("Validating trailer...")
            trailerValid = await validateVideoURL(trailerURL)
        }
        if !trailerValid, let trustedTrailer = trustedMetadata.trailerURL, trustedTrailer != result.trailerURL {
            try throwIfCancelled()
            setProgress("Trying trusted trailer source...")
            if await validateVideoURL(trustedTrailer) {
                result.trailerURL = trustedTrailer
                trailerValid = true
            }
        }
        if !trailerValid {
            try throwIfCancelled()
            setProgress("Searching for trailer...")
            result.trailerURL = await fetchAlternativeTrailerURL(title: title, category: category)
        }

        if ItemCategory.categoryHasSeasons(category) {
            try throwIfCancelled()
            setProgress("Fetching season info...")
            result.seasons = await fetchSeasonInfo(title: title, category: category, hint: hint)
        }

        return result
    }

    func autoFill(title: String, category: String, hint: String? = nil) async -> AIAutoFillResult? {
        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        guard provider != .none else {
            lastError = "No AI provider configured"
            return nil
        }

        let operationID = beginOperation(
            title: "Autofill: \(title)",
            initialMessage: "Connecting to AI...",
            rerunAction: { [weak self] in
                guard let self else { return }
                _ = await self.autoFill(title: title, category: category, hint: hint)
            }
        )

        return await Self.$currentOperationID.withValue(operationID) {
            do {
                guard let result = try await autoFillCore(title: title, category: category, hint: hint) else {
                    completeOperation(operationID, status: .failed, summary: lastError ?? "Couldn't parse metadata.")
                    return nil
                }

                completeOperation(operationID, status: .completed, summary: buildAutoFillSummary(from: result))
                return result
            } catch {
                handleOperationError(error, operationID: operationID)
                return nil
            }
        }
    }

    func improveCatalogItems(_ items: [WatchItem], db: DatabaseService) async -> AICatalogImprovementSummary? {
        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        guard provider != .none else {
            lastError = "No AI provider configured"
            return nil
        }
        guard !items.isEmpty else {
            return AICatalogImprovementSummary(
                processedCount: 0,
                improvedCount: 0,
                seasonsSavedCount: 0,
                episodesSyncedCount: 0
            )
        }

        let operationID = beginOperation(
            title: "Catalog Improvement",
            initialMessage: "Preparing background improvement..."
        )

        return await Self.$currentOperationID.withValue(operationID) {
            do {
                var summary = AICatalogImprovementSummary(
                    processedCount: items.count,
                    improvedCount: 0,
                    seasonsSavedCount: 0,
                    episodesSyncedCount: 0
                )

                for (index, item) in items.enumerated() {
                    try throwIfCancelled()
                    setProgress("Improving \(index + 1)/\(items.count): \(item.title)")

                    let hasImageURL = item.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    let existingImageValid = hasImageURL ? await validateImageURL(item.imageURL ?? "") : false

                    guard let result = try await autoFillCore(title: item.title, category: item.category) else {
                        continue
                    }

                    let mergedPlatforms = PlatformAvailability.merged(
                        preferred: item.availablePlatforms,
                        fallback: result.availablePlatforms
                    )

                    let nextImageURL = existingImageValid ? item.imageURL : (result.imageURL ?? item.imageURL)
                    let nextYear = item.year ?? result.year
                    let nextOverview = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? item.overview
                        : result.overview
                    let nextGenre = item.genre?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? item.genre
                        : result.genre
                    let nextTrailerURL = item.trailerURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? item.trailerURL
                        : result.trailerURL
                    let nextIMDb = item.imdbRating ?? result.imdbRating
                    let nextRottenTomatoes = item.rottenTomatoesScore ?? result.rottenTomatoesScore

                    let shouldUpdateItem =
                        nextImageURL != item.imageURL ||
                        nextYear != item.year ||
                        nextOverview != item.overview ||
                        nextGenre != item.genre ||
                        nextTrailerURL != item.trailerURL ||
                        nextIMDb != item.imdbRating ||
                        nextRottenTomatoes != item.rottenTomatoesScore ||
                        mergedPlatforms != item.availablePlatforms

                    if shouldUpdateItem {
                        try? await db.updateItem(
                            id: item.id,
                            title: item.title,
                            category: item.category,
                            genre: nextGenre,
                            trailerURL: nextTrailerURL,
                            imageURL: nextImageURL,
                            year: nextYear,
                            overview: nextOverview,
                            imdbRating: nextIMDb,
                            rottenTomatoesScore: nextRottenTomatoes,
                            availablePlatforms: mergedPlatforms
                        )
                        summary.improvedCount += 1
                    }

                    guard ItemCategory.categoryHasSeasons(item.category) else { continue }

                    if let seasons = result.seasons, !seasons.isEmpty {
                        try? await db.createSeasons(itemId: item.id, seasons: seasons)
                        summary.seasonsSavedCount += seasons.count
                    }

                    let storedSeasons = (try? await db.ensureSeasonScaffold(for: item)) ?? []
                    for season in storedSeasons {
                        try throwIfCancelled()
                        setProgress("Syncing \(item.title) Season \(season.seasonNumber)...")

                        guard let episodes = await fetchEpisodeInfoCore(
                            title: item.title,
                            category: item.category,
                            seasonNumber: season.seasonNumber
                        ), !episodes.isEmpty else {
                            continue
                        }

                        let existingEpisodes = (try? await db.fetchEpisodes(for: season.id)) ?? []
                        let existingNumbers = Set(existingEpisodes.map(\.episodeNumber))
                        let missingEpisodes = episodes.filter { !existingNumbers.contains($0.episodeNumber) }

                        if !missingEpisodes.isEmpty {
                            try? await db.createEpisodes(seasonId: season.id, itemId: item.id, episodes: missingEpisodes)
                            try? await db.syncSeasonAndItemStatus(seasonId: season.id)
                            summary.episodesSyncedCount += missingEpisodes.count
                        }
                    }
                }

                try? await db.fetchCatalog()
                completeOperation(operationID, status: .completed, summary: buildCatalogImprovementSummary(from: summary))
                return summary
            } catch {
                handleOperationError(error, operationID: operationID)
                return nil
            }
        }
    }

    // MARK: - AI Title Search

    private static let searchTitlesPromptTemplate = """
    The user is searching for: "%@"
    Search and find up to 5 real movies, series, anime, or telenovelas (novelas) that match this query.
    Include different real variations only when they are distinct official titles (e.g., sequel, remake, adaptation, spin-off).
    Prefer the closest canonical title matches first and do not return duplicates.
    For each result, provide:
    {
      "results": [
        {
          "title": "exact official title",
          "category": "movie" or "series" or "anime" or "novela",
          "year": release year as number or null,
          "imageURL": "a direct publicly accessible image URL for the poster. Prefer Wikipedia/Wikimedia Commons URLs (https://upload.wikimedia.org/wikipedia/en/...). Do NOT use TMDB URLs. Use empty string if unknown",
          "overview": "1-2 sentence description",
          "genre": "primary genre or empty string if unknown",
          "trailerURL": "a public trailer URL. Prefer YouTube, but Vimeo, Apple/iTunes preview URLs, or a direct video URL are also valid. Use empty string if unknown"
        }
      ]
    }
    Use "novela" specifically for Spanish/Portuguese-language telenovelas (e.g. Latin American or Brazilian dramatic serials with a defined run). Use "series" for general TV series.
    If you are not confident, return {"results": []}.
    \(strictJSONRules)
    %@
    """

    func searchTitles(query: String, excluding: [String] = [], hint: String? = nil) async -> [AISearchResult]? {
        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        guard provider != .none else {
            lastError = "No AI provider configured"
            return nil
        }

        let operationID = beginOperation(
            title: "Search: \(query)",
            initialMessage: "Searching for titles...",
            rerunAction: { [weak self] in
                guard let self else { return }
                _ = await self.searchTitles(query: query, excluding: excluding, hint: hint)
            }
        )

        let excludeClause = excluding.isEmpty
            ? ""
            : "Do NOT include these titles: \(excluding.joined(separator: ", ")). Suggest different ones."

        let prompt = String(format: Self.searchTitlesPromptTemplate, query, excludeClause) + promptHintClause(hint)

        return await Self.$currentOperationID.withValue(operationID) {
            do {
                try throwIfCancelled()
                setProgress("Asking AI for suggestions...")
                let output = try await runPrompt(provider: provider, prompt: prompt)
                try throwIfCancelled()
                setProgress("Parsing results...")
                guard var results = parseSearchTitlesResponse(output) else {
                    completeOperation(operationID, status: .failed, summary: lastError ?? "Couldn't parse search results.")
                    return nil
                }

                setProgress("Fetching poster images...")
                for i in results.indices {
                    try throwIfCancelled()
                    var hasValid = false
                    if let imgURL = results[i].imageURL {
                        hasValid = await validateImageURL(imgURL)
                    }
                    if !hasValid {
                        results[i].imageURL = await searchImageURL(title: results[i].title, category: results[i].category)
                    }
                }

                completeOperation(operationID, status: .completed, summary: buildSearchSummary(resultCount: results.count))
                return results
            } catch {
                handleOperationError(error, operationID: operationID)
                return nil
            }
        }
    }

    func generateListVibe(currentName: String, currentDescription: String, itemTitles: [String] = []) async -> AIListVibeResult? {
        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        guard provider != .none else {
            lastError = "No AI provider configured"
            return nil
        }

        let operationID = beginOperation(
            title: "List Vibe: \(currentName)",
            initialMessage: "Generating list vibe...",
            rerunAction: { [weak self] in
                guard let self else { return }
                _ = await self.generateListVibe(
                    currentName: currentName,
                    currentDescription: currentDescription,
                    itemTitles: itemTitles
                )
            }
        )

        var context = "List name: \"\(currentName)\""
        if !currentDescription.isEmpty {
            context += ", description: \"\(currentDescription)\""
        }

        let prompt: String
        if itemTitles.isEmpty {
            prompt = """
            Generate a creative description for a watchlist named "\(currentName)" in a movie/series/anime/novela tracking app.
            \(context)

            The list has no items yet. Based on the list name, create:
            1. A fun thematic description (1-2 sentences max, sets the mood for this list)
            2. Suggest ONE real movie/series/anime/novela title for "coverItem" that fits the list theme, and a DIFFERENT real title for "bannerItem"

            Do NOT change or suggest a new name. Only provide description and title suggestions.

            \(Self.strictJSONRules)
            {"description": "...", "coverItem": "suggested title", "bannerItem": "suggested title"}
            """
        } else {
            context += "\nItems in this list: \(itemTitles.joined(separator: ", "))"
            prompt = """
            Generate a creative description for a watchlist in a movie/series/anime/novela tracking app.
            \(context)

            Create:
            1. A fun thematic description (1-2 sentences max, sets the mood for this list based on its items)
            2. From the items in the list, pick ONE title for "coverItem" (best represents the list) and a DIFFERENT title for "bannerItem"

            Do NOT change or suggest a new name. Only provide description and item picks.

            \(Self.strictJSONRules)
            {"description": "...", "coverItem": "exact title from list", "bannerItem": "exact title from list"}
            """
        }

        return await Self.$currentOperationID.withValue(operationID) {
            do {
                try throwIfCancelled()
                setProgress("Asking AI...")
                let output = try await runPrompt(provider: provider, prompt: prompt)
                try throwIfCancelled()
                setProgress("Parsing response...")
                guard var result = parseListVibeResponse(output) else {
                    completeOperation(operationID, status: .failed, summary: lastError ?? "Couldn't parse vibe suggestion.")
                    return nil
                }

                if let coverTitle = result.coverItemTitle, !coverTitle.isEmpty {
                    try throwIfCancelled()
                    setProgress("Fetching cover image...")
                    result.imageURL = await searchImageURL(title: coverTitle, category: "movie")
                }
                if let bannerTitle = result.bannerItemTitle, !bannerTitle.isEmpty {
                    try throwIfCancelled()
                    setProgress("Fetching banner image...")
                    result.bannerImageURL = await searchImageURL(title: bannerTitle, category: "movie")
                }

                completeOperation(operationID, status: .completed, summary: buildListVibeSummary(from: result))
                return result
            } catch {
                handleOperationError(error, operationID: operationID)
                return nil
            }
        }
    }

    func testConnection() async -> Bool {
        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        guard provider != .none else {
            lastError = "No AI provider configured"
            return false
        }

        let operationID = beginOperation(
            title: "AI Connection Test",
            initialMessage: "Testing AI connection...",
            rerunAction: { [weak self] in
                guard let self else { return }
                _ = await self.testConnection()
            }
        )

        return await Self.$currentOperationID.withValue(operationID) {
            if provider.isCLI {
                let cliPath = resolvedCLIPath(for: provider)
                guard !cliPath.isEmpty else {
                    lastError = "CLI path not configured"
                    return false
                }
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: cliPath)
                    process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    process.environment = processEnvironment
                    process.arguments = ["--version"]
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    setActiveProcess(process, for: operationID)
                    try process.run()
                    process.waitUntilExit()
                    setActiveProcess(nil, for: operationID)
                    let succeeded = process.terminationStatus == 0
                    if !succeeded {
                        lastError = "CLI returned exit code \(process.terminationStatus)"
                        completeOperation(operationID, status: .failed, summary: lastError)
                    }
                    if succeeded {
                        completeOperation(operationID, status: .completed, summary: "Connection test passed.")
                    }
                    return succeeded
                } catch {
                    lastError = error.localizedDescription
                    completeOperation(operationID, status: .failed, summary: error.localizedDescription)
                    return false
                }
            } else {
                let apiKey = CredentialStore.shared.value(for: "aiAPIKey")
                let storedModel = AIModelPreferences.value(for: provider.rawValue)
                let model = storedModel.isEmpty ? provider.defaultModel : storedModel
                guard !apiKey.isEmpty else {
                    lastError = "API key not configured"
                    completeOperation(operationID, status: .failed, summary: lastError)
                    return false
                }
                do {
                    _ = try await runAPI(provider: provider, apiKey: apiKey, model: model, prompt: "Say hello in one word.")
                    completeOperation(operationID, status: .completed, summary: "Connection test passed.")
                    return true
                } catch {
                    lastError = error.localizedDescription
                    handleOperationError(error, operationID: operationID)
                    return false
                }
            }
        }
    }

    // MARK: - Shared Prompt Runner

    private func runPrompt(provider: AIProvider, prompt: String) async throws -> String {
        if provider.isCLI {
            let cliPath = resolvedCLIPath(for: provider)
            let model = AIModelPreferences.value(for: provider.rawValue)
            guard !cliPath.isEmpty else {
                throw AIError.cliError("CLI path not configured")
            }
            return try await runCLI(provider: provider, path: cliPath, model: model, prompt: prompt)
        } else {
            let apiKey = CredentialStore.shared.value(for: "aiAPIKey")
            let storedModel = AIModelPreferences.value(for: provider.rawValue)
            let model = storedModel.isEmpty ? provider.defaultModel : storedModel
            guard !apiKey.isEmpty else {
                throw AIError.apiError("API key not configured")
            }
            return try await runAPI(provider: provider, apiKey: apiKey, model: model, prompt: prompt)
        }
    }

    // MARK: - CLI Execution

    private func resolvedCLIPath(for provider: AIProvider) -> String {
        let defaults = UserDefaults.standard
        let storedPath = (defaults.string(forKey: "aiCLIPath") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard provider.isCLI else { return "" }

        if !storedPath.isEmpty {
            if FileManager.default.fileExists(atPath: storedPath) {
                return storedPath
            }
            if provider.isKnownPath(storedPath) {
                let detected = provider.defaultPath
                if !detected.isEmpty, FileManager.default.fileExists(atPath: detected) {
                    defaults.set(detected, forKey: "aiCLIPath")
                    return detected
                }
            }
            return storedPath
        }

        let detected = provider.defaultPath
        if !detected.isEmpty {
            defaults.set(detected, forKey: "aiCLIPath")
        }
        return detected
    }

    /// Environment with PATH set so that scripts using `#!/usr/bin/env node` (or similar) can resolve their interpreter.
    private var processEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/sbin"]
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extra + [current]).joined(separator: ":")
        return env
    }

    private func runCLI(provider: AIProvider, path: String, model: String, prompt: String) async throws -> String {
        let environment = processEnvironment
        let operationID = Self.currentOperationID
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    process.environment = environment

                    switch provider {
                    case .claude:
                        var args = ["--print", "--no-session-persistence"]
                        if !model.isEmpty {
                            args += ["--model", model]
                        }
                        args.append(prompt)
                        process.arguments = args
                    case .ollama:
                        let modelName = model.isEmpty ? "llama3.2" : model
                        process.arguments = ["run", modelName, prompt]
                    default:
                        continuation.resume(throwing: AIError.noProvider)
                        return
                    }

                    let outputPipe = Pipe()
                    let errorPipe = Pipe()
                    process.standardOutput = outputPipe
                    process.standardError = errorPipe

                    Task { @MainActor in
                        self.setActiveProcess(process, for: operationID)
                    }
                    try process.run()
                    process.waitUntilExit()
                    Task { @MainActor in
                        self.setActiveProcess(nil, for: operationID)
                    }

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        if process.terminationReason == .uncaughtSignal {
                            continuation.resume(throwing: AIError.cancelled)
                            return
                        }
                        let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
                        continuation.resume(throwing: AIError.cliError(errStr))
                    } else {
                        continuation.resume(returning: output)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - API Execution

    private func runAPI(provider: AIProvider, apiKey: String, model: String, prompt: String) async throws -> String {
        let request = try buildAPIRequest(provider: provider, apiKey: apiKey, model: model, prompt: prompt)
        let (data, response) = try await performDataRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.apiError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIError.apiError("HTTP \(httpResponse.statusCode): \(body)")
        }

        return try extractTextFromAPIResponse(provider: provider, data: data)
    }

    private func performDataRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let operationID = Self.currentOperationID
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            var sessionTask: URLSessionDataTask?
            sessionTask = URLSession.shared.dataTask(with: request) { data, response, error in
                Task { @MainActor in
                    if let sessionTask,
                       let runtime = operationID.flatMap({ self.operationRuntimes[$0] }),
                       runtime.activeDataTask?.taskIdentifier == sessionTask.taskIdentifier {
                        self.setActiveDataTask(nil, for: operationID)
                    }
                }

                if let urlError = error as? URLError, urlError.code == .cancelled {
                    continuation.resume(throwing: AIError.cancelled)
                    return
                }

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data, let response else {
                    continuation.resume(throwing: AIError.apiError("Invalid response"))
                    return
                }

                continuation.resume(returning: (data, response))
            }

            guard let sessionTask else {
                continuation.resume(throwing: AIError.apiError("Failed to create request"))
                return
            }

            Task { @MainActor in
                self.setActiveDataTask(sessionTask, for: operationID)
            }
            sessionTask.resume()
        }
    }

    private func buildAPIRequest(provider: AIProvider, apiKey: String, model: String, prompt: String) throws -> URLRequest {
        try AIAPITransport.request(provider: provider, apiKey: apiKey, model: model, prompt: prompt)
    }

    private func extractTextFromAPIResponse(provider: AIProvider, data: Data) throws -> String {
        try AIAPITransport.text(provider: provider, data: data)
    }

    // MARK: - Parse Response

    private func parseAutoFillResponse(_ raw: String) -> AIAutoFillResult? {
        guard let data = extractJSONObjectData(from: raw),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastError = userFacingParseError(
                raw,
                fallback: "AI couldn't complete this title right now. Try again or fill the fields manually."
            )
            return nil
        }

        var result = AIAutoFillResult()
        if let url = json["imageURL"] as? String, !url.isEmpty {
            result.imageURL = url
        }
        result.year = intValue(from: json["year"])
        if let overview = json["overview"] as? String, !overview.isEmpty {
            result.overview = overview
        }
        if let genre = json["genre"] as? String, !genre.isEmpty {
            result.genre = genre
        }
        if let trailerURL = json["trailerURL"] as? String, !trailerURL.isEmpty {
            result.trailerURL = trailerURL
        }
        result.imdbRating = doubleValue(from: json["imdbRating"] ?? json["imdb_rating"])
        result.rottenTomatoesScore = intValue(from: json["rottenTomatoesScore"] ?? json["rotten_tomatoes_score"])
        result.availablePlatforms = parsePlatforms(json["platforms"])

        return result
    }

    private func parseSearchTitlesResponse(_ raw: String) -> [AISearchResult]? {
        guard let data = extractJSONObjectData(from: raw),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultsArr = json["results"] as? [[String: Any]] else {
            lastError = userFacingParseError(
                raw,
                fallback: "AI couldn't suggest titles for this search. Try a broader title or add it manually."
            )
            return nil
        }

        return resultsArr.compactMap { dict -> AISearchResult? in
            guard let title = dict["title"] as? String, !title.isEmpty else { return nil }
            let category = dict["category"] as? String ?? "movie"
            let validCategory = ["movie", "series", "anime", "novela"].contains(category) ? category : "movie"
            let imgURL = (dict["imageURL"] as? String) ?? (dict["image_url"] as? String)
            let vidURL = (dict["trailerURL"] as? String) ?? (dict["trailer_url"] as? String)

            return AISearchResult(
                title: title,
                category: validCategory,
                year: intValue(from: dict["year"]),
                imageURL: (imgURL?.isEmpty == false) ? imgURL : nil,
                overview: {
                    let o = dict["overview"] as? String
                    return (o?.isEmpty == false) ? o : nil
                }(),
                genre: {
                    let g = dict["genre"] as? String
                    return (g?.isEmpty == false) ? g : nil
                }(),
                trailerURL: (vidURL?.isEmpty == false) ? vidURL : nil,
                imdbRating: doubleValue(from: dict["imdbRating"] ?? dict["imdb_rating"]),
                rottenTomatoesScore: intValue(from: dict["rottenTomatoesScore"] ?? dict["rotten_tomatoes_score"]),
                availablePlatforms: parsePlatforms(dict["platforms"])
            )
        }
    }

    private func parsePlatforms(_ raw: Any?) -> [PlatformAvailability] {
        let parsed: [PlatformAvailability]

        if let array = raw as? [[String: Any]] {
            parsed = array.compactMap { item in
                let platformName = (item["name"] as? String) ?? (item["platform"] as? String)
                let availability = (item["availability"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = (item["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !(platformName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                      platformName?.lowercased() != "other" else {
                    return url?.isEmpty == false
                        ? PlatformAvailability(
                            platform: StreamingPlatform.detect(name: platformName, url: url, availability: availability),
                            availability: availability?.isEmpty == true ? nil : availability,
                            url: url?.isEmpty == true ? nil : url
                        )
                        : nil
                }
                return PlatformAvailability(
                    platform: StreamingPlatform.detect(name: platformName, url: url, availability: availability),
                    availability: availability?.isEmpty == true ? nil : availability,
                    url: url?.isEmpty == true ? nil : url
                )
            }
        } else if let array = raw as? [String] {
            parsed = array.compactMap { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.lowercased() != "other" else { return nil }
                return PlatformAvailability(
                    platform: StreamingPlatform.detect(name: trimmed, availability: "streaming"),
                    availability: "streaming",
                    url: nil
                )
            }
        } else {
            parsed = []
        }

        return PlatformAvailability.merged(preferred: parsed, fallback: [])
    }

    private func parseListVibeResponse(_ raw: String) -> AIListVibeResult? {
        guard let data = extractJSONObjectData(from: raw),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastError = userFacingParseError(
                raw,
                fallback: "AI couldn't generate a vibe suggestion right now. Try again in a moment."
            )
            return nil
        }

        var result = AIListVibeResult()
        if let desc = json["description"] as? String, !desc.isEmpty {
            result.description = desc
        }

        // Extract item titles for cover/banner (we'll fetch real images via APIs)
        let coverItem = (json["coverItem"] as? String)
            ?? (json["cover_item"] as? String)
        if let coverItem, !coverItem.isEmpty {
            result.coverItemTitle = coverItem
        }

        let bannerItem = (json["bannerItem"] as? String)
            ?? (json["banner_item"] as? String)
        if let bannerItem, !bannerItem.isEmpty {
            result.bannerItemTitle = bannerItem
        }

        return result
    }

    private func extractJSONObjectData(from raw: String) -> Data? {
        var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if jsonStr.contains("```") {
            let lines = jsonStr.components(separatedBy: "\n")
            jsonStr = lines
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let start = jsonStr.firstIndex(of: "{"), let end = jsonStr.lastIndex(of: "}") {
            jsonStr = String(jsonStr[start...end])
        }

        return jsonStr.data(using: .utf8)
    }

    private func userFacingParseError(_ raw: String, fallback: String) -> String {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let refusalSignals = [
            "web search",
            "internet access",
            "browse the web",
            "browsing limitations",
            "grant permission",
            "don't want to risk fabricating",
            "do not want to risk fabricating",
            "can't verify",
            "cannot verify",
            "need access"
        ]

        if refusalSignals.contains(where: { normalized.contains($0) }) {
            return fallback
        }

        if normalized.isEmpty {
            return fallback
        }

        let preview = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let compactPreview = String(preview.prefix(120))
        return "AI returned an unexpected format. \(compactPreview)"
    }

    private func parseImageURLOnlyResponse(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences
        if text.hasPrefix("```") {
            let lines = text.components(separatedBy: "\n")
            text = lines.filter { !$0.hasPrefix("```") }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try JSON parsing first
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            let jsonStr = String(text[start...end])
            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Accept common key variants
                let url = (json["imageURL"] as? String)
                    ?? (json["image_url"] as? String)
                    ?? (json["url"] as? String)
                    ?? (json["coverURL"] as? String)
                if let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return url.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // Fallback: extract a raw HTTPS URL from the response
        if let range = text.range(of: "https://[^\\s\"'\\]}>]+", options: .regularExpression) {
            let url = String(text[range])
            if !url.isEmpty { return url }
        }

        return nil
    }

    // MARK: - Image Search via Free APIs (no API key needed)

    /// Search for a poster image using free APIs: Jikan (anime), OMDb (movies/series), iTunes (fallback)
    func searchImageURL(title: String, category: String) async -> String? {
        if isCancellationRequested() { return nil }
        // For anime, try Jikan (MyAnimeList) first
        if category == "anime" {
            if let url = await searchJikanImage(title: title) {
                return url
            }
        }

        // For movies and series, try OMDb (IMDb posters) first
        if let url = await searchOMDbImage(title: title) {
            return url
        }

        // Fallback to iTunes
        if let url = await searchITunesImage(title: title, category: category) {
            return url
        }

        // Last resort: try Jikan even for non-anime (some animated movies are there)
        if category != "anime" {
            if let url = await searchJikanImage(title: title) {
                return url
            }
        }

        return nil
    }

    private func fetchTrustedMetadata(title: String, category: String, hint: String?) async -> ExternalMetadata {
        if isCancellationRequested() { return ExternalMetadata() }

        var metadata = ExternalMetadata()

        let queries = trustedMetadataQueries(title: title, hint: hint)
        for (index, query) in queries.enumerated() {
            if isCancellationRequested() { break }
            setProgress("Checking trusted source \(index + 1)/\(queries.count)...")

            if category == "anime" {
                metadata.mergeMissingValues(from: await searchJikanMetadata(title: query))
                metadata.mergeMissingValues(from: await searchITunesMetadata(title: query, category: category))
            } else {
                metadata.mergeMissingValues(from: await searchOMDbMetadata(title: query, category: category))
                metadata.mergeMissingValues(from: await searchITunesMetadata(title: query, category: category))
            }

            if metadata.hasRichMatch {
                break
            }
        }

        return metadata
    }

    private func trustedMetadataQueries(title: String, hint: String?) -> [String] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var queries: [String] = [trimmedTitle]

        let hintFragments = hintSearchFragments(hint)
        guard !hintFragments.isEmpty else { return queries }

        for fragment in hintFragments {
            queries.append("\(trimmedTitle) \(fragment)")

            if let yearMatch = fragment.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) {
                queries.append("\(trimmedTitle) \(fragment[yearMatch])")
            }

            let lowercaseFragment = fragment.lowercased()
            let platformTerms = [
                "apple tv+", "apple tv", "netflix", "max", "hbo", "crunchyroll",
                "disney+", "hulu", "prime video", "amazon", "peacock", "paramount+"
            ]
            for term in platformTerms where lowercaseFragment.contains(term) {
                queries.append("\(trimmedTitle) \(term)")
            }
        }

        var uniqueQueries: [String] = []
        var seen: Set<String> = []
        for query in queries {
            let normalized = query
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty, seen.insert(normalized.lowercased()).inserted {
                uniqueQueries.append(normalized)
            }
        }
        return Array(uniqueQueries.prefix(4))
    }

    /// Search for season images via Jikan API (anime seasons)
    func searchSeasonImageURL(title: String, seasonNumber: Int) async -> String? {
        if isCancellationRequested() { return nil }
        let query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        guard let url = URL(string: "https://api.jikan.moe/v4/anime?q=\(query)%20season%20\(seasonNumber)&limit=3") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await performDataRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["data"] as? [[String: Any]] else { return nil }

            for result in results {
                if let images = result["images"] as? [String: Any],
                   let jpg = images["jpg"] as? [String: Any],
                   let imageURL = jpg["large_image_url"] as? String ?? jpg["image_url"] as? String,
                   !imageURL.isEmpty {
                    return imageURL
                }
            }
        } catch { }
        return nil
    }

    private func searchOMDbImage(title: String) async -> String? {
        if isCancellationRequested() { return nil }
        guard let url = MetadataRequest.omdbURL(
            apiKey: CredentialStore.shared.value(for: "omdbAPIKey"),
            parameters: [URLQueryItem(name: "t", value: title)]
        ) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await performDataRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let poster = json["Poster"] as? String,
                  poster != "N/A", !poster.isEmpty else { return nil }
            // Upgrade to higher resolution
            return poster.replacingOccurrences(of: "SX300", with: "SX600")
        } catch { }
        return nil
    }

    private func searchOMDbMetadata(title: String, category: String? = nil) async -> ExternalMetadata {
        if isCancellationRequested() { return ExternalMetadata() }
        var parameters = [URLQueryItem(name: "t", value: title), URLQueryItem(name: "plot", value: "short"), URLQueryItem(name: "tomatoes", value: "true")]
        switch category {
        case "movie": parameters.append(URLQueryItem(name: "type", value: "movie"))
        case "series", "novela": parameters.append(URLQueryItem(name: "type", value: "series"))
        default: break
        }
        guard let url = MetadataRequest.omdbURL(
            apiKey: CredentialStore.shared.value(for: "omdbAPIKey"),
            parameters: parameters
        ) else {
            return ExternalMetadata()
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await performDataRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["Response"] as? String) != "False" else {
                return ExternalMetadata()
            }

            var metadata = ExternalMetadata()
            if let poster = json["Poster"] as? String, poster != "N/A", !poster.isEmpty {
                metadata.imageURL = poster.replacingOccurrences(of: "SX300", with: "SX600")
            }
            if let yearString = json["Year"] as? String {
                metadata.year = extractYear(from: yearString)
            }
            if let plot = json["Plot"] as? String, plot != "N/A", !plot.isEmpty {
                metadata.overview = plot
            }
            if let genre = json["Genre"] as? String, genre != "N/A", !genre.isEmpty {
                metadata.genre = genre
            }
            if let imdbString = json["imdbRating"] as? String,
               imdbString != "N/A",
               let imdb = Double(imdbString) {
                metadata.imdbRating = imdb
            }
            if let ratings = json["Ratings"] as? [[String: Any]] {
                for rating in ratings {
                    let source = (rating["Source"] as? String) ?? ""
                    if source.lowercased().contains("rotten"),
                       let value = rating["Value"] as? String,
                       let percent = Int(value.replacingOccurrences(of: "%", with: "")) {
                        metadata.rottenTomatoesScore = percent
                    }
                }
            }
            return metadata
        } catch {
            return ExternalMetadata()
        }
    }

    private func searchJikanImage(title: String) async -> String? {
        if isCancellationRequested() { return nil }
        let query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        guard let url = URL(string: "https://api.jikan.moe/v4/anime?q=\(query)&limit=1") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await performDataRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["data"] as? [[String: Any]],
                  let first = results.first else { return nil }

            if let images = first["images"] as? [String: Any],
               let jpg = images["jpg"] as? [String: Any],
               let imageURL = jpg["large_image_url"] as? String ?? jpg["image_url"] as? String,
               !imageURL.isEmpty {
                return imageURL
            }
        } catch { }
        return nil
    }

    private func searchJikanMetadata(title: String) async -> ExternalMetadata {
        if isCancellationRequested() { return ExternalMetadata() }
        let query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        guard let url = URL(string: "https://api.jikan.moe/v4/anime?q=\(query)&limit=1") else {
            return ExternalMetadata()
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await performDataRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["data"] as? [[String: Any]],
                  let first = results.first else {
                return ExternalMetadata()
            }

            var metadata = ExternalMetadata()
            if let images = first["images"] as? [String: Any],
               let jpg = images["jpg"] as? [String: Any],
               let imageURL = jpg["large_image_url"] as? String ?? jpg["image_url"] as? String,
               !imageURL.isEmpty {
                metadata.imageURL = imageURL
            }
            if let year = first["year"] as? Int {
                metadata.year = year
            } else if let aired = first["aired"] as? [String: Any],
                      let from = aired["from"] as? String {
                metadata.year = extractYear(from: from)
            }
            if let synopsis = first["synopsis"] as? String, !synopsis.isEmpty {
                metadata.overview = synopsis
            }
            if let genres = first["genres"] as? [[String: Any]] {
                let names = genres.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
                if !names.isEmpty {
                    metadata.genre = names.joined(separator: ", ")
                }
            }
            if let trailer = first["trailer"] as? [String: Any] {
                if let url = trailer["url"] as? String, !url.isEmpty {
                    metadata.trailerURL = url
                } else if let embedURL = trailer["embed_url"] as? String, !embedURL.isEmpty {
                    metadata.trailerURL = embedURL
                } else if let youtubeID = trailer["youtube_id"] as? String, !youtubeID.isEmpty {
                    metadata.trailerURL = "https://www.youtube.com/watch?v=\(youtubeID)"
                }
            }
            return metadata
        } catch {
            return ExternalMetadata()
        }
    }

    private func searchITunesImage(title: String, category: String) async -> String? {
        if isCancellationRequested() { return nil }
        let media = (category == "movie") ? "movie" : "tvShow"
        let query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(query)&media=\(media)&limit=3") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await performDataRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return nil }

            for result in results {
                if let artworkURL = result["artworkUrl100"] as? String, !artworkURL.isEmpty {
                    // Scale up from 100x100 to 600x600 for high-res
                    let highRes = artworkURL.replacingOccurrences(of: "100x100", with: "600x600")
                    return highRes
                }
            }
        } catch { }
        return nil
    }

    private func searchITunesMetadata(title: String, category: String) async -> ExternalMetadata {
        if isCancellationRequested() { return ExternalMetadata() }
        let media = (category == "movie") ? "movie" : "tvShow"
        let query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(query)&media=\(media)&limit=3") else {
            return ExternalMetadata()
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await performDataRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first else {
                return ExternalMetadata()
            }

            var metadata = ExternalMetadata()
            if let artworkURL = first["artworkUrl100"] as? String, !artworkURL.isEmpty {
                metadata.imageURL = artworkURL.replacingOccurrences(of: "100x100", with: "600x600")
            }
            if let releaseDate = first["releaseDate"] as? String {
                metadata.year = extractYear(from: releaseDate)
            }
            if let genre = first["primaryGenreName"] as? String, !genre.isEmpty {
                metadata.genre = genre
            }
            let overview = (first["longDescription"] as? String)
                ?? (first["shortDescription"] as? String)
                ?? (first["description"] as? String)
            if let overview, !overview.isEmpty {
                metadata.overview = overview
            }
            if let previewURL = first["previewUrl"] as? String, !previewURL.isEmpty {
                metadata.trailerURL = previewURL
            }
            if let trackViewURL = first["trackViewUrl"] as? String, !trackViewURL.isEmpty {
                let artistName = first["artistName"] as? String
                metadata.availablePlatforms = PlatformAvailability.merged(
                    preferred: [
                        PlatformAvailability(
                            platform: StreamingPlatform.detect(name: artistName, url: trackViewURL, availability: "streaming"),
                            availability: "streaming",
                            url: trackViewURL
                        )
                    ],
                    fallback: []
                )
            }
            return metadata
        } catch {
            return ExternalMetadata()
        }
    }

    private func doubleValue(from raw: Any?) -> Double? {
        if let raw = raw as? Double { return raw }
        if let raw = raw as? NSNumber { return raw.doubleValue }
        if let raw = raw as? String {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/10", with: "")
                .replacingOccurrences(of: "%", with: "")
            return Double(cleaned)
        }
        return nil
    }

    // MARK: - URL Validation

    func validateImageURL(_ urlString: String) async -> Bool {
        if isCancellationRequested() { return false }
        guard let url = URL(string: urlString) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            let (data, response) = try await performDataRequest(request)
            guard let http = response as? HTTPURLResponse else { return false }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            return http.statusCode == 200 && contentType.contains("image") && data.count > 100
        } catch {
            return false
        }
    }

    private func videoURLHasValidFormat(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return true
    }

    func validateVideoURL(_ urlString: String) async -> Bool {
        if isCancellationRequested() { return false }
        guard videoURLHasValidFormat(urlString) else { return false }

        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else {
            return false
        }

        let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString

        if host.contains("youtube.com") || host.contains("youtu.be") {
            guard let oembedURL = URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json") else {
                return false
            }

            var request = URLRequest(url: oembedURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 10

            do {
                let (_, response) = try await performDataRequest(request)
                guard let http = response as? HTTPURLResponse else { return false }
                return http.statusCode == 200
            } catch {
                return false
            }
        }

        if host.contains("vimeo.com") {
            guard let oembedURL = URL(string: "https://vimeo.com/api/oembed.json?url=\(encoded)") else {
                return false
            }

            var request = URLRequest(url: oembedURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 10

            do {
                let (_, response) = try await performDataRequest(request)
                guard let http = response as? HTTPURLResponse else { return false }
                return http.statusCode == 200
            } catch {
                return false
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        do {
            let (data, response) = try await performDataRequest(request)
            guard let http = response as? HTTPURLResponse else { return false }
            guard (200..<400).contains(http.statusCode) else { return false }

            let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if contentType.contains("video") || contentType.contains("mpegurl") || contentType.contains("octet-stream") {
                return true
            }

            let knownTrailerHosts = ["apple.com", "itunes.apple.com", "tv.apple.com"]
            if knownTrailerHosts.contains(where: { host.contains($0) }) {
                return true
            }

            let lowerPath = url.path.lowercased()
            let knownVideoExtensions = [".mp4", ".mov", ".m4v", ".webm", ".m3u8"]
            if knownVideoExtensions.contains(where: { lowerPath.hasSuffix($0) }) {
                return true
            }

            return !data.isEmpty && contentType.contains("html") && knownTrailerHosts.contains(where: { host.contains($0) })
        } catch {
            return false
        }
    }

    func fetchAlternativeImageURL(title: String, category: String, attempt: Int = 1) async -> String? {
        // Try real APIs first (fast and reliable)
        if attempt == 1 {
            if let url = await searchImageURL(title: title, category: category) {
                return url
            }
        }

        // Fallback to AI-generated URL
        let prompt = """
        Provide a direct publicly accessible image URL for the poster/cover art of the \(category) titled "\(title)".
        Use a URL from Wikipedia/Wikimedia Commons (https://upload.wikimedia.org/wikipedia/en/...) or another stable public source.
        Do NOT use TMDB URLs. The URL must point directly to an image file that loads in a browser.
        If you are not confident, return {"imageURL": ""}.
        \(Self.strictJSONRules)
        """
        do {
            let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
            let output = try await runPrompt(provider: provider, prompt: prompt)
            if let url = parseImageURLOnlyResponse(output) {
                if await validateImageURL(url) {
                    return url
                }
            }
        } catch { }

        if attempt < 2 {
            return await fetchAlternativeImageURL(title: title, category: category, attempt: attempt + 1)
        }
        return nil
    }

    func fetchAlternativeTrailerURL(title: String, category: String) async -> String? {
        let prompt = """
        Provide ONLY one real, working trailer URL for the \(category) titled "\(title)".
        Prefer YouTube. If unavailable, Vimeo, Apple/iTunes preview URLs, or a direct public video URL are also valid.
        Make sure the trailer exists and is specific to this title.
        If you are not confident, return {"trailerURL": ""}.
        \(Self.strictJSONRules)
        """
        do {
            let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
            let output = try await runPrompt(provider: provider, prompt: prompt)
            if let url = parseTrailerURLOnlyResponse(output) {
                if await validateVideoURL(url) {
                    return url
                }
            }
        } catch { }
        return nil
    }

    private func parseTrailerURLOnlyResponse(_ raw: String) -> String? {
        var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonStr.contains("```") {
            let lines = jsonStr.components(separatedBy: "\n")
            jsonStr = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = jsonStr.firstIndex(of: "{"), let end = jsonStr.lastIndex(of: "}") {
            let objectString = String(jsonStr[start...end])
            if let data = objectString.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let url = (dict["trailerURL"] as? String)
                    ?? (dict["trailer_url"] as? String)
                    ?? (dict["url"] as? String)
                if let url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return url.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        if let range = jsonStr.range(of: "https?://[^\\s\"'\\]}>]+", options: .regularExpression) {
            return String(jsonStr[range])
        }
        return nil
    }

    private func intValue(from any: Any?) -> Int? {
        switch any {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        case let value as String:
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func extractYear(from text: String) -> Int? {
        guard let range = text.range(of: "\\b(19|20)\\d{2}\\b", options: .regularExpression) else {
            return nil
        }
        return Int(text[range])
    }

    // MARK: - Season Fetching

    private static let seasonPromptTemplate = """
    For the %@ titled "%@", provide season information:
    {
      "seasons": [
        {
          "seasonNumber": 1,
          "name": "Season 1 name or subtitle if any, or null",
          "year": 2020,
          "episodeCount": 12,
          "imageURL": "a direct publicly accessible image URL for this season's poster or cover. Use Wikipedia/Wikimedia Commons or other stable sources. Do NOT use TMDB URLs. Use empty string if unknown",
          "trailerURL": "an official YouTube trailer URL for this specific season (https://www.youtube.com/watch?v=...) or empty string if unknown",
          "overview": "Brief 1-sentence description of this season"
        }
      ]
    }
    Include all official narrative seasons in ascending order.
    If the title has exactly one season, you must still return Season 1.
    Do not include specials, OVAs, recap movies, shorts, or bonus material unless they are officially counted inside a numbered season.
    Do not duplicate seasons.
    If you are not confident, return {"seasons": []}.
    \(strictJSONRules)
    """

    func fetchSeasonInfo(title: String, category: String, hint: String? = nil) async -> [AISeasonResult]? {
        guard ItemCategory.categoryHasSeasons(category) else { return nil }
        if isCancellationRequested() { return nil }

        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        guard provider != .none else { return nil }

        let prompt = String(format: Self.seasonPromptTemplate, category, title) + promptHintClause(hint)

        do {
            let output = try await runPrompt(provider: provider, prompt: prompt)
            guard var seasons = parseSeasonResponse(output) else { return nil }

            // Validate season image URLs and replace with real API images
            for i in seasons.indices {
                if isCancellationRequested() { return nil }
                var hasValid = false
                if let imgURL = seasons[i].imageURL {
                    hasValid = await validateImageURL(imgURL)
                }
                if !hasValid {
                    // Try Jikan for anime season images
                    if category == "anime" {
                        seasons[i].imageURL = await searchSeasonImageURL(title: title, seasonNumber: seasons[i].seasonNumber)
                    }
                }
            }

            return seasons
        } catch {
            return nil
        }
    }

    private func parseSeasonResponse(_ raw: String) -> [AISeasonResult]? {
        var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if jsonStr.contains("```") {
            let lines = jsonStr.components(separatedBy: "\n")
            jsonStr = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let start = jsonStr.firstIndex(of: "{"), let end = jsonStr.lastIndex(of: "}") {
            jsonStr = String(jsonStr[start...end])
        }

        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seasonsArr = json["seasons"] as? [[String: Any]] else {
            return nil
        }

        let seasons = seasonsArr.compactMap { dict -> AISeasonResult? in
            guard let num = intValue(from: dict["seasonNumber"] ?? dict["season_number"]) else { return nil }
            let imgURL = (dict["imageURL"] as? String) ?? (dict["image_url"] as? String)
            let vidURL = (dict["trailerURL"] as? String) ?? (dict["trailer_url"] as? String)
            return AISeasonResult(
                seasonNumber: num,
                name: dict["name"] as? String,
                year: intValue(from: dict["year"]),
                episodeCount: intValue(from: dict["episodeCount"] ?? dict["episode_count"]),
                imageURL: (imgURL?.isEmpty == false) ? imgURL : nil,
                trailerURL: (vidURL?.isEmpty == false) ? vidURL : nil,
                overview: dict["overview"] as? String
            )
        }
        .sorted { $0.seasonNumber < $1.seasonNumber }

        var seenSeasonNumbers = Set<Int>()
        return seasons.filter { seenSeasonNumbers.insert($0.seasonNumber).inserted }
    }

    // MARK: - Episode Fetching

    private static let episodePromptTemplate = """
    For the %@ titled "%@", Season %d, provide episode information:
    {
      "episodes": [
        {
          "episodeNumber": 1,
          "title": "Episode title",
          "overview": "Brief 1-sentence description of the episode",
          "airDate": "YYYY-MM-DD or empty string if unknown",
          "runtimeMinutes": 24
        }
      ]
    }
    Include all standard numbered episodes in this season in ascending order.
    If this season has only one episode, you must still return Episode 1.
    Do not include specials, OVAs, recap episodes, bonus shorts, trailers, or extras unless they are officially numbered inside this season.
    Do not duplicate episodes.
    If you are not confident, return {"episodes": []}.
    \(strictJSONRules)
    """

    func fetchEpisodeInfo(title: String, category: String, seasonNumber: Int, hint: String? = nil, trackAsJob: Bool = false) async -> [AIEpisodeResult]? {
        if trackAsJob {
            let operationID = beginOperation(
                title: "Episodes: \(title) S\(seasonNumber)",
                initialMessage: "Fetching episodes...",
                rerunAction: { [weak self] in
                    guard let self else { return }
                    _ = await self.fetchEpisodeInfo(
                        title: title,
                        category: category,
                        seasonNumber: seasonNumber,
                        hint: hint,
                        trackAsJob: true
                    )
                }
            )

            return await Self.$currentOperationID.withValue(operationID) {
                do {
                    try throwIfCancelled()
                    let episodes = await fetchEpisodeInfoCore(
                        title: title,
                        category: category,
                        seasonNumber: seasonNumber,
                        hint: hint
                    )

                    if let episodes, !episodes.isEmpty {
                        completeOperation(
                            operationID,
                            status: .completed,
                            summary: "Fetched \(episodes.count) episode\(episodes.count == 1 ? "" : "s") for Season \(seasonNumber)."
                        )
                    } else {
                        completeOperation(
                            operationID,
                            status: .failed,
                            summary: "No episode data found for Season \(seasonNumber)."
                        )
                    }
                    return episodes
                } catch {
                    handleOperationError(error, operationID: operationID)
                    return nil
                }
            }
        }

        return await fetchEpisodeInfoCore(title: title, category: category, seasonNumber: seasonNumber, hint: hint)
    }

    private func fetchEpisodeInfoCore(title: String, category: String, seasonNumber: Int, hint: String? = nil) async -> [AIEpisodeResult]? {
        guard ItemCategory.categoryHasSeasons(category) else { return nil }
        if isCancellationRequested() { return nil }

        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        setProgress("Checking trusted episode sources...")
        let trustedEpisodes = await fetchEpisodesFromTrustedSources(
            title: title,
            category: category,
            seasonNumber: seasonNumber,
            hint: hint
        )

        var mergedEpisodes = trustedEpisodes

        if provider != .none {
            let prompt = String(format: Self.episodePromptTemplate, category, title, seasonNumber) + promptHintClause(hint)

            do {
                setProgress("Using AI to fill missing episodes...")
                let output = try await runPrompt(provider: provider, prompt: prompt)
                let aiEpisodes = parseEpisodeResponse(output) ?? []
                mergedEpisodes = mergeEpisodes(preferred: mergedEpisodes, fallback: aiEpisodes)
            } catch {
                if mergedEpisodes.isEmpty {
                    return nil
                }
            }
        }

        guard !mergedEpisodes.isEmpty else { return nil }
        return mergedEpisodes
    }

    private static let singleEpisodePromptTemplate = """
    For the %@ titled "%@", Season %d, Episode %d, provide episode information:
    {
      "episodes": [
        {
          "episodeNumber": %d,
          "title": "Episode title",
          "overview": "Brief 1-2 sentence description of the episode",
          "airDate": "YYYY-MM-DD or empty string if unknown",
          "runtimeMinutes": 24
        }
      ]
    }
    Return data only for the exact requested episode number.
    If you are not confident, return {"episodes": []}.
    \(strictJSONRules)
    """

    func fetchSingleEpisodeInfo(title: String, category: String, seasonNumber: Int, episodeNumber: Int, hint: String? = nil) async -> AIEpisodeResult? {
        guard ItemCategory.categoryHasSeasons(category) else { return nil }
        if isCancellationRequested() { return nil }

        if let seasonEpisodes = await fetchEpisodeInfoCore(
            title: title,
            category: category,
            seasonNumber: seasonNumber,
            hint: hint
        ), let match = seasonEpisodes.first(where: { $0.episodeNumber == episodeNumber }) {
            return match
        }

        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        guard provider != .none else { return nil }

        let prompt = String(format: Self.singleEpisodePromptTemplate, category, title, seasonNumber, episodeNumber, episodeNumber) + promptHintClause(hint)

        do {
            let output = try await runPrompt(provider: provider, prompt: prompt)
            return parseEpisodeResponse(output)?.first
        } catch {
            return nil
        }
    }

    private func parseEpisodeResponse(_ raw: String) -> [AIEpisodeResult]? {
        var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if jsonStr.contains("```") {
            let lines = jsonStr.components(separatedBy: "\n")
            jsonStr = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let start = jsonStr.firstIndex(of: "{"), let end = jsonStr.lastIndex(of: "}") {
            jsonStr = String(jsonStr[start...end])
        }

        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let episodesArr = json["episodes"] as? [[String: Any]] else {
            return nil
        }

        let episodes = episodesArr.compactMap { dict -> AIEpisodeResult? in
            guard let num = intValue(from: dict["episodeNumber"] ?? dict["episode_number"]) else { return nil }
            let airDate = dict["airDate"] as? String ?? dict["air_date"] as? String
            return AIEpisodeResult(
                episodeNumber: num,
                title: dict["title"] as? String,
                overview: dict["overview"] as? String,
                airDate: (airDate?.isEmpty == false) ? airDate : nil,
                runtimeMinutes: intValue(from: dict["runtimeMinutes"] ?? dict["runtime_minutes"])
            )
        }
        .sorted { $0.episodeNumber < $1.episodeNumber }

        var seenEpisodeNumbers = Set<Int>()
        return episodes.filter { seenEpisodeNumbers.insert($0.episodeNumber).inserted }
    }

    private func fetchEpisodesFromTrustedSources(title: String, category: String, seasonNumber: Int, hint: String?) async -> [AIEpisodeResult] {
        let queries = episodeSearchQueries(title: title, hint: hint, seasonNumber: seasonNumber)
        var merged: [AIEpisodeResult] = []

        for query in queries {
            if isCancellationRequested() { return merged }

            setProgress("Trying OMDb for Season \(seasonNumber)...")
            let omdbEpisodes = await searchOMDbEpisodes(title: query, seasonNumber: seasonNumber)
            merged = mergeEpisodes(preferred: merged, fallback: omdbEpisodes)

            setProgress("Trying TVMaze for Season \(seasonNumber)...")
            let tvMazeEpisodes = await searchTVMazeEpisodes(title: query, seasonNumber: seasonNumber)
            merged = mergeEpisodes(preferred: merged, fallback: tvMazeEpisodes)

            if category == "anime" {
                setProgress("Trying Jikan for Season \(seasonNumber)...")
                let jikanEpisodes = await searchJikanEpisodes(title: query, seasonNumber: seasonNumber)
                merged = mergeEpisodes(preferred: merged, fallback: jikanEpisodes)
            }

            if !merged.isEmpty {
                let hasOverviews = merged.contains { ($0.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }
                let hasRuntime = merged.contains { $0.runtimeMinutes != nil }
                if hasOverviews && hasRuntime {
                    break
                }
            }
        }

        return merged
    }

    private func episodeSearchQueries(title: String, hint: String?, seasonNumber: Int) -> [String] {
        var queries: [String] = []

        func append(_ query: String?) {
            guard let query else { return }
            let cleaned = query
                .replacingOccurrences(of: #"["']"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !queries.contains(cleaned) else { return }
            queries.append(cleaned)
        }

        append(title)

        let hintFragments = hintSearchFragments(hint)
        if !hintFragments.isEmpty {
            for fragment in hintFragments {
                append("\(title) \(fragment)")
            }
        }

        append("\(title) season \(seasonNumber)")
        append("\(title) s\(seasonNumber)")
        return Array(queries.prefix(5))
    }

    private func mergeEpisodes(preferred: [AIEpisodeResult], fallback: [AIEpisodeResult]) -> [AIEpisodeResult] {
        var mergedByNumber: [Int: AIEpisodeResult] = [:]

        for episode in fallback where episode.episodeNumber > 0 {
            mergedByNumber[episode.episodeNumber] = episode
        }

        for episode in preferred where episode.episodeNumber > 0 {
            if var existing = mergedByNumber[episode.episodeNumber] {
                if existing.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    existing.title = episode.title
                }
                if existing.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    existing.overview = episode.overview
                }
                if existing.airDate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    existing.airDate = episode.airDate
                }
                if existing.runtimeMinutes == nil {
                    existing.runtimeMinutes = episode.runtimeMinutes
                }
                mergedByNumber[episode.episodeNumber] = existing
            } else {
                mergedByNumber[episode.episodeNumber] = episode
            }
        }

        return mergedByNumber.values.sorted { $0.episodeNumber < $1.episodeNumber }
    }

    private func searchOMDbEpisodes(title: String, seasonNumber: Int) async -> [AIEpisodeResult] {
        if isCancellationRequested() { return [] }
        guard let url = MetadataRequest.omdbURL(
            apiKey: CredentialStore.shared.value(for: "omdbAPIKey"),
            parameters: [URLQueryItem(name: "t", value: title), URLQueryItem(name: "Season", value: String(seasonNumber)), URLQueryItem(name: "plot", value: "short")]
        ) else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await performDataRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["Response"] as? String) != "False",
                  let episodes = json["Episodes"] as? [[String: Any]] else {
                return []
            }

            return episodes.compactMap { episode in
                guard let number = intValue(from: episode["Episode"]) else { return nil }
                return AIEpisodeResult(
                    episodeNumber: number,
                    title: episode["Title"] as? String,
                    overview: nil,
                    airDate: (episode["Released"] as? String).flatMap(normalizeAirDate),
                    runtimeMinutes: nil
                )
            }
        } catch {
            return []
        }
    }

    private func searchTVMazeEpisodes(title: String, seasonNumber: Int) async -> [AIEpisodeResult] {
        if isCancellationRequested() { return [] }
        let query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        guard let searchURL = URL(string: "https://api.tvmaze.com/search/shows?q=\(query)") else { return [] }

        var searchRequest = URLRequest(url: searchURL)
        searchRequest.timeoutInterval = 10

        do {
            let (searchData, searchResponse) = try await performDataRequest(searchRequest)
            guard let http = searchResponse as? HTTPURLResponse, http.statusCode == 200,
                  let results = try? JSONSerialization.jsonObject(with: searchData) as? [[String: Any]],
                  !results.isEmpty else {
                return []
            }

            let normalizedTarget = normalizeEpisodeSearchTitle(title)
            let bestShowID: Int? = results
                .compactMap { result -> (Int, Int)? in
                    guard let show = result["show"] as? [String: Any],
                          let showID = show["id"] as? Int,
                          let showName = show["name"] as? String else { return nil }
                    let normalizedShow = normalizeEpisodeSearchTitle(showName)
                    let score = episodeCandidateScore(candidate: normalizedShow, target: normalizedTarget)
                    return (showID, score)
                }
                .sorted { $0.1 > $1.1 }
                .first?.0

            guard let bestShowID,
                  let episodesURL = URL(string: "https://api.tvmaze.com/shows/\(bestShowID)/episodes") else {
                return []
            }

            var episodesRequest = URLRequest(url: episodesURL)
            episodesRequest.timeoutInterval = 10

            let (episodesData, episodesResponse) = try await performDataRequest(episodesRequest)
            guard let episodesHTTP = episodesResponse as? HTTPURLResponse, episodesHTTP.statusCode == 200,
                  let episodes = try? JSONSerialization.jsonObject(with: episodesData) as? [[String: Any]] else {
                return []
            }

            return episodes.compactMap { episode in
                guard let season = episode["season"] as? Int,
                      season == seasonNumber,
                      let number = episode["number"] as? Int else { return nil }

                let rawSummary = episode["summary"] as? String
                return AIEpisodeResult(
                    episodeNumber: number,
                    title: episode["name"] as? String,
                    overview: stripHTML(from: rawSummary),
                    airDate: normalizeAirDate(episode["airdate"] as? String),
                    runtimeMinutes: episode["runtime"] as? Int
                )
            }
        } catch {
            return []
        }
    }

    private func searchJikanEpisodes(title: String, seasonNumber: Int) async -> [AIEpisodeResult] {
        if isCancellationRequested() { return [] }
        let query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        guard let searchURL = URL(string: "https://api.jikan.moe/v4/anime?q=\(query)&limit=5") else { return [] }

        var searchRequest = URLRequest(url: searchURL)
        searchRequest.timeoutInterval = 10

        do {
            let (searchData, searchResponse) = try await performDataRequest(searchRequest)
            guard let http = searchResponse as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: searchData) as? [String: Any],
                  let results = json["data"] as? [[String: Any]],
                  !results.isEmpty else {
                return []
            }

            let normalizedTarget = normalizeEpisodeSearchTitle(title)
            let bestAnimeID = results
                .compactMap { entry -> (Int, Int)? in
                    guard let animeID = entry["mal_id"] as? Int else { return nil }
                    let titleCandidates = [
                        entry["title"] as? String,
                        entry["title_english"] as? String,
                        entry["title_japanese"] as? String
                    ].compactMap { $0 }
                    let score = titleCandidates
                        .map { episodeCandidateScore(candidate: normalizeEpisodeSearchTitle($0), target: normalizedTarget) }
                        .max() ?? 0
                    return (animeID, score)
                }
                .sorted { $0.1 > $1.1 }
                .first?.0

            guard let bestAnimeID else { return [] }

            var page = 1
            var collected: [AIEpisodeResult] = []

            while page <= 4 {
                guard let episodesURL = URL(string: "https://api.jikan.moe/v4/anime/\(bestAnimeID)/episodes?page=\(page)") else { break }
                var episodesRequest = URLRequest(url: episodesURL)
                episodesRequest.timeoutInterval = 10

                let (episodesData, episodesResponse) = try await performDataRequest(episodesRequest)
                guard let episodesHTTP = episodesResponse as? HTTPURLResponse, episodesHTTP.statusCode == 200,
                      let episodesJSON = try? JSONSerialization.jsonObject(with: episodesData) as? [String: Any],
                      let data = episodesJSON["data"] as? [[String: Any]] else {
                    break
                }

                let pageEpisodes = data.compactMap { episode -> AIEpisodeResult? in
                    guard let number = episode["mal_id"] as? Int else { return nil }
                    return AIEpisodeResult(
                        episodeNumber: number,
                        title: episode["title"] as? String,
                        overview: episode["synopsis"] as? String,
                        airDate: normalizeAirDate(episode["aired"] as? String),
                        runtimeMinutes: nil
                    )
                }
                collected.append(contentsOf: pageEpisodes)

                let pagination = episodesJSON["pagination"] as? [String: Any]
                let hasNextPage = pagination?["has_next_page"] as? Bool ?? false
                if !hasNextPage { break }
                page += 1
            }

            if seasonNumber == 1 || !collected.isEmpty {
                return collected.sorted { $0.episodeNumber < $1.episodeNumber }
            }
            return []
        } catch {
            return []
        }
    }

    private func normalizeEpisodeSearchTitle(_ title: String) -> String {
        title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func episodeCandidateScore(candidate: String, target: String) -> Int {
        guard !candidate.isEmpty, !target.isEmpty else { return 0 }
        if candidate == target { return 100 }
        if candidate.contains(target) || target.contains(candidate) { return 80 }

        let targetTokens = Set(target.split(separator: " ").map(String.init))
        let candidateTokens = Set(candidate.split(separator: " ").map(String.init))
        return targetTokens.intersection(candidateTokens).count * 10
    }

    private func stripHTML(from text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let stripped = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    private func normalizeAirDate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "N/A" else { return nil }

        if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return trimmed
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for format in ["dd MMM yyyy", "d MMM yyyy", "MMM dd, yyyy", "MMMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.string(from: date)
            }
        }

        if let year = extractYear(from: trimmed) {
            return String(format: "%04d-01-01", year)
        }

        return nil
    }

    // MARK: - TMDB (The Movie DB)

    /// Search TMDB for a title and return its TMDB id and resolved type ("movie"/"tv").
    /// Novelas, series, and anime all map to "tv" since TMDB does not distinguish telenovelas.
    private func searchTMDB(title: String, category: String, hint: String? = nil) async -> (id: Int, mediaType: String)? {
        let apiKey = CredentialStore.shared.value(for: "tmdbAPIKey").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return nil }
        let query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let mediaTypePath = (category == "movie") ? "movie" : "tv"

        // Try year-aware search if hint contains a year
        var yearParam = ""
        if let hint, let yearRange = hint.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression),
           let year = Int(hint[yearRange]) {
            yearParam = (mediaTypePath == "movie") ? "&year=\(year)" : "&first_air_date_year=\(year)"
        }

        guard let url = URL(string: "https://api.themoviedb.org/3/search/\(mediaTypePath)?query=\(query)\(yearParam)&api_key=\(apiKey)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await performDataRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let id = intValue(from: first["id"]) else {
                return nil
            }
            return (id, mediaTypePath)
        } catch {
            return nil
        }
    }

    /// Fetch TMDB watch providers for an item. Aggregates flatrate/rent/buy across the largest English-speaking regions.
    private func fetchTMDBWatchProviders(tmdbID: Int, mediaType: String) async -> [PlatformAvailability] {
        let apiKey = CredentialStore.shared.value(for: "tmdbAPIKey").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return [] }

        guard let url = URL(string: "https://api.themoviedb.org/3/\(mediaType)/\(tmdbID)/watch/providers?api_key=\(apiKey)") else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await performDataRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resultsByRegion = json["results"] as? [String: Any] else {
                return []
            }

            // Try priority regions in order. We collect everything we find.
            let priorityRegions = ["US", "GB", "CA", "AU", "ES", "MX", "AR", "DE", "FR", "BR"]
            var collected: [PlatformAvailability] = []
            var seenPlatforms: Set<String> = []

            for region in priorityRegions {
                guard let regionData = resultsByRegion[region] as? [String: Any] else { continue }
                let regionLink = regionData["link"] as? String

                func appendBucket(_ key: String, availability: String) {
                    guard let providers = regionData[key] as? [[String: Any]] else { return }
                    for provider in providers {
                        guard let name = provider["provider_name"] as? String, !name.isEmpty else { continue }
                        let detected = StreamingPlatform.detect(name: name)
                        let dedupeKey = "\(detected.rawValue)|\(availability)"
                        guard seenPlatforms.insert(dedupeKey).inserted else { continue }
                        collected.append(
                            PlatformAvailability(
                                platform: detected,
                                availability: availability,
                                url: regionLink
                            )
                        )
                    }
                }

                appendBucket("flatrate", availability: "streaming")
                appendBucket("free", availability: "free")
                appendBucket("ads", availability: "ads")
                appendBucket("rent", availability: "rental")
                appendBucket("buy", availability: "purchase")

                // If we already have specific entries from a primary region, don't keep accumulating from every region.
                if region == "US" && collected.contains(where: { $0.platform != .other }) {
                    break
                }
            }

            return collected
        } catch {
            return []
        }
    }

    /// One-shot helper that searches TMDB for the title and returns its watch providers.
    func findPlatformsViaTMDB(title: String, category: String, hint: String? = nil) async -> [PlatformAvailability] {
        guard let match = await searchTMDB(title: title, category: category, hint: hint) else { return [] }
        return await fetchTMDBWatchProviders(tmdbID: match.id, mediaType: match.mediaType)
    }

    // MARK: - Web Scraping (no API key)

    /// Patterns that map streaming-service URLs (or domains) back to a `StreamingPlatform`.
    /// Matched against the raw text returned by search engines, Wikipedia, etc.
    private static let platformURLPatterns: [(StreamingPlatform, [String])] = [
        (.netflix,        ["netflix.com/title", "netflix.com/watch", "netflix.com/"]),
        (.appleTVPlus,    ["tv.apple.com/", "apple.co/"]),
        (.max,            ["play.max.com", "hbomax.com", "max.com/movie", "max.com/show", "max.com/series"]),
        (.disneyPlus,     ["disneyplus.com"]),
        (.hulu,           ["hulu.com/movie", "hulu.com/series", "hulu.com/watch"]),
        (.primeVideo,     ["primevideo.com", "amazon.com/gp/video", "amazon.com/dp/B0", "amzn.to/"]),
        (.peacock,        ["peacocktv.com"]),
        (.paramountPlus,  ["paramountplus.com"]),
        (.crunchyroll,    ["crunchyroll.com/series", "crunchyroll.com/watch", "crunchyroll.com/anime"]),
        (.youtube,        ["youtube.com/watch?v=", "youtube.com/movie", "youtu.be/"]),
    ]

    /// Looser word-form fallback: when the URL pattern doesn't match but the text mentions the service.
    private static let platformWordPatterns: [(StreamingPlatform, [String])] = [
        (.netflix,        ["netflix"]),
        (.appleTVPlus,    ["apple tv+", "apple tv plus", "apple tv "]),
        (.max,            ["hbo max", "max ", "hbomax"]),
        (.disneyPlus,     ["disney+", "disney plus"]),
        (.hulu,           ["hulu"]),
        (.primeVideo,     ["prime video", "amazon prime"]),
        (.peacock,        ["peacock"]),
        (.paramountPlus,  ["paramount+", "paramount plus"]),
        (.crunchyroll,    ["crunchyroll"]),
    ]

    /// Decode DuckDuckGo's redirect URLs (e.g. /l/?uddg=https%3A%2F%2Fwww.netflix.com%2F...)
    private func decodeDuckDuckGoRedirects(in html: String) -> String {
        var result = html
        if let regex = try? NSRegularExpression(pattern: "uddg=([^&\"]+)", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2,
                      let mr = Range(match.range(at: 1), in: result) else { continue }
                let encoded = String(result[mr])
                if let decoded = encoded.removingPercentEncoding {
                    result.replaceSubrange(mr, with: decoded)
                }
            }
        }
        return result
    }

    /// Extracts platforms from arbitrary HTML/text by matching streaming service URLs first, then plain words.
    private func extractPlatformsFromText(_ rawText: String) -> [PlatformAvailability] {
        let text = rawText.lowercased()
        var found: [(StreamingPlatform, String?)] = []

        for (platform, patterns) in Self.platformURLPatterns {
            for pattern in patterns where text.contains(pattern.lowercased()) {
                // Try to capture the actual URL containing this pattern
                let url = extractFirstURL(containing: pattern.lowercased(), in: rawText)
                if !found.contains(where: { $0.0 == platform }) {
                    found.append((platform, url))
                }
                break
            }
        }

        // If we found nothing via URL patterns, try plain word patterns (snippet text)
        if found.isEmpty {
            for (platform, words) in Self.platformWordPatterns {
                for word in words where text.contains(word) {
                    if !found.contains(where: { $0.0 == platform }) {
                        found.append((platform, nil))
                    }
                    break
                }
            }
        }

        return found.map {
            PlatformAvailability(
                platform: $0.0,
                availability: "streaming",
                url: $0.1
            )
        }
    }

    private func extractFirstURL(containing fragment: String, in text: String) -> String? {
        // Try a non-greedy regex around the fragment for an http(s) URL.
        let pattern = "https?://[^\\s\"<>'`)]*?\(NSRegularExpression.escapedPattern(for: fragment))[^\\s\"<>'`)]*"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range),
           let r = Range(match.range, in: text) {
            return String(text[r])
        }
        return nil
    }

    /// Search the web via DuckDuckGo HTML and parse the resulting page for known streaming domains.
    func scrapePlatformsFromDuckDuckGo(title: String, category: String, hint: String? = nil) async -> [PlatformAvailability] {
        if isCancellationRequested() { return [] }

        let categoryWord: String
        switch category {
        case "anime": categoryWord = "anime"
        case "series": categoryWord = "tv series"
        case "novela": categoryWord = "telenovela"
        default: categoryWord = "movie"
        }
        var queryComponents = ["\(title) \(categoryWord) watch online streaming"]

        if let hint, let yearRange = hint.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) {
            queryComponents.insert("\(title) \(hint[yearRange])", at: 0)
        }

        var collected: [PlatformAvailability] = []

        for queryRaw in queryComponents.prefix(2) {
            if isCancellationRequested() { break }
            guard let encoded = queryRaw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else { continue }

            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await performDataRequest(request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let html = String(data: data, encoding: .utf8) else { continue }

                let decoded = decodeDuckDuckGoRedirects(in: html)
                let parsed = extractPlatformsFromText(decoded)
                if !parsed.isEmpty {
                    collected = PlatformAvailability.merged(preferred: collected, fallback: parsed)
                }

                if collected.contains(where: { $0.platform != .other }) && collected.count >= 3 {
                    break
                }
            } catch {
                continue
            }
        }

        return collected
    }

    /// All the useful fields a single Wikipedia call can give us about a movie/show.
    struct WikipediaArticle: Sendable {
        var canonicalTitle: String?
        var displayTitle: String?
        var description: String?
        var extract: String?
        var year: Int?
        var posterURL: String?
        /// Streaming services mentioned in the article body, parsed via `extractPlatformsFromText`.
        var platforms: [PlatformAvailability]
    }

    /// Search Wikipedia for the article that best matches a title and return its parsed fields.
    /// Uses two endpoints:
    /// 1) `action=query&list=search` to find the article title.
    /// 2) `/api/rest_v1/page/summary/{title}` to get the structured summary (title, extract, description, image).
    /// Then re-uses the existing platform extraction over the extract text.
    func fetchWikipediaArticle(title: String, category: String, hint: String? = nil) async -> WikipediaArticle? {
        if isCancellationRequested() { return nil }

        let yearFromHint: Int? = {
            guard let hint, let r = hint.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) else { return nil }
            return Int(hint[r])
        }()

        let categoryWord: String
        switch category {
        case "movie": categoryWord = "film"
        case "anime": categoryWord = "anime"
        case "novela": categoryWord = "telenovela"
        default: categoryWord = "TV series"
        }

        let yearStr = yearFromHint.map { " \($0)" } ?? ""
        let searchQueryRaw = "\(title)\(yearStr) \(categoryWord)"
        guard let encoded = searchQueryRaw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=\(encoded)&srlimit=1&format=json&origin=*") else {
            return nil
        }

        var searchRequest = URLRequest(url: searchURL)
        searchRequest.timeoutInterval = 10
        searchRequest.setValue("StreamVibes/1.0", forHTTPHeaderField: "User-Agent")

        var pageTitle: String?
        do {
            let (data, response) = try await performDataRequest(searchRequest)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = json["query"] as? [String: Any],
                  let results = query["search"] as? [[String: Any]],
                  let first = results.first,
                  let t = first["title"] as? String else {
                return nil
            }
            pageTitle = t
        } catch {
            return nil
        }

        guard let pageTitle else { return nil }

        // REST summary endpoint — title in path, spaces become underscores, percent encoded.
        let pathTitle = pageTitle.replacingOccurrences(of: " ", with: "_")
        guard let pathEncoded = pathTitle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let summaryURL = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(pathEncoded)") else {
            return nil
        }

        var summaryRequest = URLRequest(url: summaryURL)
        summaryRequest.timeoutInterval = 12
        summaryRequest.setValue("StreamVibes/1.0", forHTTPHeaderField: "User-Agent")

        var article = WikipediaArticle(
            canonicalTitle: nil,
            displayTitle: nil,
            description: nil,
            extract: nil,
            year: nil,
            posterURL: nil,
            platforms: []
        )

        do {
            let (data, response) = try await performDataRequest(summaryRequest)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            article.canonicalTitle = (json["title"] as? String)
            if let titles = json["titles"] as? [String: Any] {
                article.displayTitle = (titles["normalized"] as? String) ?? article.canonicalTitle
            }
            article.description = (json["description"] as? String)
            article.extract = (json["extract"] as? String)
            if let original = json["originalimage"] as? [String: Any], let src = original["source"] as? String {
                article.posterURL = src
            } else if let thumb = json["thumbnail"] as? [String: Any], let src = thumb["source"] as? String {
                article.posterURL = src
            }
        } catch {
            return nil
        }

        // Year: prefer description (e.g. "2010 film by Ben Affleck"), fallback to extract.
        if let desc = article.description, let r = desc.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) {
            article.year = Int(desc[r])
        } else if let extract = article.extract, let r = extract.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) {
            article.year = Int(extract[r])
        }

        // Re-use the platform extractor on the extract text for streaming mentions.
        if let extract = article.extract {
            article.platforms = extractPlatformsFromText(extract)
        }

        // Drop the canonical "(YYYY film)" suffix from the canonical title for clean display.
        if let title = article.canonicalTitle {
            article.canonicalTitle = title
                .replacingOccurrences(of: #" \((\d{4} film|film|TV series|anime|telenovela)\)$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return article
    }

    /// Search the web for an official YouTube trailer URL via DuckDuckGo HTML.
    /// Returns a validated YouTube watch URL or nil.
    func scrapeTrailerFromDuckDuckGo(title: String, category: String, hint: String? = nil) async -> String? {
        if isCancellationRequested() { return nil }

        let yearStr: String = {
            guard let hint, let r = hint.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) else { return "" }
            return " \(hint[r])"
        }()

        let categoryWord: String
        switch category {
        case "anime": categoryWord = "anime"
        case "series": categoryWord = "tv series"
        case "novela": categoryWord = "telenovela"
        default: categoryWord = "movie"
        }

        let queries = [
            "\(title)\(yearStr) \(categoryWord) official trailer site:youtube.com",
            "\(title)\(yearStr) trailer youtube"
        ]

        for queryRaw in queries {
            if isCancellationRequested() { break }
            guard let encoded = queryRaw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else { continue }

            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await performDataRequest(request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let html = String(data: data, encoding: .utf8) else { continue }

                let decoded = decodeDuckDuckGoRedirects(in: html)

                // Match YouTube watch / youtu.be URLs.
                let pattern = "https?://(?:www\\.)?(?:youtube\\.com/watch\\?[^\\s\"<>'`]+|youtu\\.be/[A-Za-z0-9_-]+[^\\s\"<>'`]*)"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(decoded.startIndex..., in: decoded)
                let matches = regex.matches(in: decoded, options: [], range: range)
                for match in matches {
                    guard let r = Range(match.range, in: decoded) else { continue }
                    let candidate = String(decoded[r])
                    // Skip the channel/playlist/results pages — we want a watch URL.
                    if candidate.contains("youtube.com/results") || candidate.contains("youtube.com/channel") {
                        continue
                    }
                    if await validateVideoURL(candidate) {
                        return candidate
                    }
                }
            } catch {
                continue
            }
        }

        return nil
    }

    /// Fetch the Wikipedia article for the title and look for streaming service mentions in the prose.
    func scrapePlatformsFromWikipedia(title: String, category: String, hint: String? = nil) async -> [PlatformAvailability] {
        guard let article = await fetchWikipediaArticle(title: title, category: category, hint: hint) else {
            return []
        }
        return article.platforms
    }

    // MARK: - Platform Discovery

    /// Aggressively searches for streaming platforms for a given title.
    /// Tries multiple no-key sources (DuckDuckGo HTML, Wikipedia, iTunes), an optional TMDB lookup,
    /// and finally a focused AI prompt.
    func findPlatforms(title: String, category: String, hint: String? = nil, knownPlatforms: [PlatformAvailability] = []) async -> [PlatformAvailability]? {
        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        let tmdbKey = CredentialStore.shared.value(for: "tmdbAPIKey").trimmingCharacters(in: .whitespacesAndNewlines)

        var collected: [PlatformAvailability] = knownPlatforms

        // 1. TMDB watch/providers (best quality, but requires optional API key)
        if !tmdbKey.isEmpty && !isCancellationRequested() {
            setProgress("Searching TMDB watch providers...")
            let tmdbResults = await findPlatformsViaTMDB(title: title, category: category, hint: hint)
            if !tmdbResults.isEmpty {
                collected = PlatformAvailability.merged(preferred: collected, fallback: tmdbResults)
            }
        }

        // 2. DuckDuckGo HTML scraping (no key)
        if !isCancellationRequested() {
            setProgress("Searching DuckDuckGo for streaming services...")
            let ddgResults = await scrapePlatformsFromDuckDuckGo(title: title, category: category, hint: hint)
            if !ddgResults.isEmpty {
                collected = PlatformAvailability.merged(preferred: collected, fallback: ddgResults)
            }
        }

        // 3. Wikipedia article scraping (no key)
        if !isCancellationRequested() && !(collected.contains(where: { $0.platform != .other }) && collected.count >= 4) {
            setProgress("Checking Wikipedia for streaming mentions...")
            let wikiResults = await scrapePlatformsFromWikipedia(title: title, category: category, hint: hint)
            if !wikiResults.isEmpty {
                collected = PlatformAvailability.merged(preferred: collected, fallback: wikiResults)
            }
        }

        // 4. iTunes (cheap, adds Apple TV+/iTunes purchase entries)
        let trustedQueries = trustedMetadataQueries(title: title, hint: hint)
        for query in trustedQueries {
            if isCancellationRequested() { break }
            let itunes = await searchITunesMetadata(title: query, category: category)
            if !itunes.availablePlatforms.isEmpty {
                collected = PlatformAvailability.merged(preferred: collected, fallback: itunes.availablePlatforms)
            }
            if collected.count >= 4 {
                break
            }
        }

        // 2. Focused AI prompt — only ask about platforms, with retry
        if provider != .none {
            let knownNames = collected.map { $0.platform.label }.joined(separator: ", ")
            let knownClause = knownNames.isEmpty
                ? "No platforms are currently known."
                : "Already known: \(knownNames). Try to find ADDITIONAL ones."

            let prompt = """
            For the \(category) titled "\(title)", list every legitimate streaming service, rental store, or theatrical availability where it can currently be watched.
            \(knownClause)
            Be exhaustive. Search across regions if you must, but prefer the largest English-speaking markets.
            Return strictly this JSON:
            {
              "platforms": [
                {
                  "name": "Apple TV+",
                  "availability": "streaming",
                  "url": "https://tv.apple.com/..."
                }
              ]
            }
            Use specific service names from this list when possible: Apple TV+, Netflix, Max, Disney+, Hulu, Prime Video, Peacock, Paramount+, Crunchyroll, YouTube, Theaters.
            Do not return generic "Other" entries unless you have a real URL.
            If you genuinely don't know, return {"platforms": []}.
            \(promptHintClause(hint))
            \(Self.strictJSONRules)
            """

            for attempt in 0..<2 {
                if isCancellationRequested() { break }
                do {
                    let output = try await runPrompt(provider: provider, prompt: prompt)
                    if let data = extractJSONObjectData(from: output),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let parsed = parsePlatforms(json["platforms"])
                        if !parsed.isEmpty {
                            collected = PlatformAvailability.merged(preferred: collected, fallback: parsed)
                            if collected.contains(where: { $0.platform != .other }) {
                                break
                            }
                        }
                    }
                } catch {
                    if attempt == 1 {
                        lastError = error.localizedDescription
                    }
                }
            }
        }

        // Strip useless "other" entries when we have specific ones.
        if collected.contains(where: { $0.platform != .other }) {
            collected = collected.filter { $0.platform != .other }
        }

        return collected.isEmpty ? nil : collected
    }

    // MARK: - Focused Field Discovery

    struct FoundRatings: Sendable {
        var imdbRating: Double?
        var rottenTomatoesScore: Int?
    }

    /// Aggressively search for a canonical/official title.
    /// Sources tried, in order: Wikipedia article title → AI focused prompt.
    func findOfficialTitle(title: String, category: String, hint: String? = nil) async -> String? {
        // 1. Wikipedia
        if let article = await fetchWikipediaArticle(title: title, category: category, hint: hint),
           let canonical = article.canonicalTitle, !canonical.isEmpty {
            return canonical
        }

        // 2. AI fallback
        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        guard provider != .none else { return nil }

        let prompt = """
        For the \(category) currently called "\(title)", what is the exact official/canonical title as it appears on its primary release?
        Return strictly:
        {"title": "Exact Official Title"}
        If you are not sure, return {"title": ""}.
        \(promptHintClause(hint))
        \(Self.strictJSONRules)
        """

        for attempt in 0..<2 {
            if isCancellationRequested() { break }
            do {
                let output = try await runPrompt(provider: provider, prompt: prompt)
                if let data = extractJSONObjectData(from: output),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let value = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            } catch {
                if attempt == 1 { lastError = error.localizedDescription }
            }
        }
        return nil
    }

    /// Aggressively search for a poster/cover image (validated).
    /// Sources tried, in order: Wikipedia originalimage → trusted metadata (OMDb/iTunes/Jikan) → AI/API fallback.
    func findPoster(title: String, category: String, hint: String? = nil) async -> String? {
        // 1. Wikipedia originalimage (high resolution, stable Wikimedia URLs)
        if let article = await fetchWikipediaArticle(title: title, category: category, hint: hint),
           let url = article.posterURL, await validateImageURL(url) {
            return url
        }

        // 2. Trusted sources
        let trusted = await fetchTrustedMetadata(title: title, category: category, hint: hint)
        if let url = trusted.imageURL, await validateImageURL(url) {
            return url
        }

        // 3. AI/API fallback (already retries internally)
        return await fetchAlternativeImageURL(title: title, category: category)
    }

    /// Aggressively search for a trailer URL (validated).
    /// Sources tried, in order: DuckDuckGo → trusted metadata (iTunes preview) → AI fallback.
    func findTrailer(title: String, category: String, hint: String? = nil) async -> String? {
        // 1. DuckDuckGo → YouTube watch URL
        if let url = await scrapeTrailerFromDuckDuckGo(title: title, category: category, hint: hint) {
            return url
        }

        // 2. Trusted sources (iTunes previewUrl)
        let trusted = await fetchTrustedMetadata(title: title, category: category, hint: hint)
        if let url = trusted.trailerURL, await validateVideoURL(url) {
            return url
        }

        // 3. AI fallback
        return await fetchAlternativeTrailerURL(title: title, category: category)
    }

    /// Aggressively search for an overview/description.
    /// Sources tried, in order: Wikipedia extract → trusted metadata → AI fallback.
    func findOverview(title: String, category: String, hint: String? = nil) async -> String? {
        // 1. Wikipedia extract — usually 2-4 sentences, well-written, factual
        if let article = await fetchWikipediaArticle(title: title, category: category, hint: hint),
           let extract = article.extract?.trimmingCharacters(in: .whitespacesAndNewlines),
           !extract.isEmpty {
            // Trim to first 3 sentences for a tighter overview.
            let sentences = extract
                .split(whereSeparator: { ".!?".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(3)
            if !sentences.isEmpty {
                return sentences.joined(separator: ". ") + "."
            }
            return extract
        }

        // 2. Trusted sources
        let trusted = await fetchTrustedMetadata(title: title, category: category, hint: hint)
        if let overview = trusted.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty {
            return overview
        }

        // 3. AI fallback
        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        guard provider != .none else { return nil }

        let prompt = """
        Write a concise 2-3 sentence official-style overview for the \(category) titled "\(title)". Stick to facts about the canonical release.
        Return strictly:
        {"overview": "Two or three sentences here."}
        If you are not sure, return {"overview": ""}.
        \(promptHintClause(hint))
        \(Self.strictJSONRules)
        """

        for attempt in 0..<2 {
            if isCancellationRequested() { break }
            do {
                let output = try await runPrompt(provider: provider, prompt: prompt)
                if let data = extractJSONObjectData(from: output),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let value = (json["overview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            } catch {
                if attempt == 1 { lastError = error.localizedDescription }
            }
        }
        return nil
    }

    /// Aggressively search for the primary genre.
    /// Sources tried, in order: trusted metadata (OMDb has rich genre data) → Wikipedia description → AI fallback.
    func findGenre(title: String, category: String, hint: String? = nil) async -> String? {
        // 1. Trusted sources (OMDb has the cleanest genre data)
        let trusted = await fetchTrustedMetadata(title: title, category: category, hint: hint)
        if let genre = trusted.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty {
            return genre
        }

        // 2. Wikipedia description / extract — search for known genre words
        if let article = await fetchWikipediaArticle(title: title, category: category, hint: hint) {
            let haystack = ((article.description ?? "") + " " + (article.extract ?? "")).lowercased()
            let knownGenres = [
                "action", "adventure", "animation", "comedy", "crime", "documentary",
                "drama", "family", "fantasy", "horror", "mystery", "romance",
                "sci-fi", "science fiction", "thriller", "western", "slice of life",
                "mecha", "shonen", "shojo", "isekai", "sports", "musical"
            ]
            for genre in knownGenres where haystack.contains(genre) {
                let normalized: String
                switch genre {
                case "science fiction": normalized = "Sci-Fi"
                default: normalized = genre.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
                }
                return normalized
            }
        }

        // 3. AI fallback
        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        guard provider != .none else { return nil }

        let prompt = """
        For the \(category) titled "\(title)", what is the single primary genre?
        Use one of: Action, Adventure, Animation, Comedy, Crime, Documentary, Drama, Family, Fantasy, Horror, Mystery, Romance, Sci-Fi, Thriller, Western, Slice of Life, Mecha, Shonen, Shojo, Isekai, Sports, Musical.
        Return strictly:
        {"genre": "Sci-Fi"}
        If you are not sure, return {"genre": ""}.
        \(promptHintClause(hint))
        \(Self.strictJSONRules)
        """

        for attempt in 0..<2 {
            if isCancellationRequested() { break }
            do {
                let output = try await runPrompt(provider: provider, prompt: prompt)
                if let data = extractJSONObjectData(from: output),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let value = (json["genre"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            } catch {
                if attempt == 1 { lastError = error.localizedDescription }
            }
        }
        return nil
    }

    /// Aggressively search for the release year.
    /// Sources tried, in order: trusted metadata → Wikipedia (parsed from description/extract) → AI fallback.
    func findYear(title: String, category: String, hint: String? = nil) async -> Int? {
        // 1. Trusted sources
        let trusted = await fetchTrustedMetadata(title: title, category: category, hint: hint)
        if let year = trusted.year { return year }

        // 2. Wikipedia (description has "2010 film by ...", extract starts with "is a 2010 ...")
        if let article = await fetchWikipediaArticle(title: title, category: category, hint: hint),
           let year = article.year {
            return year
        }

        // 3. AI fallback
        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        guard provider != .none else { return nil }

        let prompt = """
        For the \(category) titled "\(title)", what is the canonical release year?
        Return strictly:
        {"year": 1999}
        If you are not sure, return {"year": null}.
        \(promptHintClause(hint))
        \(Self.strictJSONRules)
        """

        for attempt in 0..<2 {
            if isCancellationRequested() { break }
            do {
                let output = try await runPrompt(provider: provider, prompt: prompt)
                if let data = extractJSONObjectData(from: output),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let value = intValue(from: json["year"]) {
                    return value
                }
            } catch {
                if attempt == 1 { lastError = error.localizedDescription }
            }
        }
        return nil
    }

    /// Aggressively search for IMDb + Rotten Tomatoes ratings.
    func findRatings(title: String, category: String, hint: String? = nil) async -> FoundRatings? {
        let trusted = await fetchTrustedMetadata(title: title, category: category, hint: hint)
        var result = FoundRatings(imdbRating: trusted.imdbRating, rottenTomatoesScore: trusted.rottenTomatoesScore)

        if result.imdbRating != nil && result.rottenTomatoesScore != nil {
            return result
        }

        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        guard provider != .none else {
            return (result.imdbRating == nil && result.rottenTomatoesScore == nil) ? nil : result
        }

        let prompt = """
        For the \(category) titled "\(title)", provide its review aggregate scores.
        Return strictly:
        {"imdbRating": 8.2, "rottenTomatoesScore": 94}
        Use null for any value you are not certain about.
        \(promptHintClause(hint))
        \(Self.strictJSONRules)
        """

        for attempt in 0..<2 {
            if isCancellationRequested() { break }
            do {
                let output = try await runPrompt(provider: provider, prompt: prompt)
                if let data = extractJSONObjectData(from: output),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if result.imdbRating == nil, let imdb = doubleValue(from: json["imdbRating"]) {
                        result.imdbRating = imdb
                    }
                    if result.rottenTomatoesScore == nil, let rt = intValue(from: json["rottenTomatoesScore"]) {
                        result.rottenTomatoesScore = rt
                    }
                    if result.imdbRating != nil || result.rottenTomatoesScore != nil {
                        return result
                    }
                }
            } catch {
                if attempt == 1 { lastError = error.localizedDescription }
            }
        }

        return (result.imdbRating == nil && result.rottenTomatoesScore == nil) ? nil : result
    }

    // MARK: - Buddy Chat

    struct BuddyChatSeasonContext: Sendable {
        var seasonNumber: Int
        var name: String?
        var expectedEpisodeCount: Int?
        var existingEpisodeCount: Int
        var missingEpisodeNumbers: [Int]
    }

    func interpretBuddyChatItemCommand(
        input: String,
        item: WatchItem,
        seasonContext: [BuddyChatSeasonContext] = []
    ) async -> [BuddyChatItemPlan]? {
        let provider = AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "none") ?? .none
        guard provider != .none else {
            lastError = "No AI provider configured"
            return nil
        }

        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return nil }

        let escapedInput = trimmedInput
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let yearStr = item.year.map(String.init) ?? "unknown"
        let genreStr = (item.genre?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        let hasTrailer = (item.trailerURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? "yes" : "no"
        let platformList = item.availablePlatforms.map { $0.platform.label }.joined(separator: ", ")
        let platformsStr = platformList.isEmpty ? "none" : platformList

        var seasonsBlock = ""
        if !seasonContext.isEmpty {
            let lines = seasonContext.map { ctx -> String in
                let expected = ctx.expectedEpisodeCount.map(String.init) ?? "unknown"
                let missingStr: String
                if ctx.missingEpisodeNumbers.isEmpty {
                    missingStr = "none"
                } else {
                    let preview = ctx.missingEpisodeNumbers.prefix(20).map(String.init).joined(separator: ", ")
                    missingStr = ctx.missingEpisodeNumbers.count > 20 ? "\(preview), ..." : preview
                }
                let nameSuffix = (ctx.name?.isEmpty == false) ? " (\(ctx.name ?? ""))" : ""
                return "  - Season \(ctx.seasonNumber)\(nameSuffix): \(ctx.existingEpisodeCount)/\(expected) episodes saved, missing: \(missingStr)"
            }
            seasonsBlock = "\n- Seasons:\n" + lines.joined(separator: "\n")
        }

        let prompt = """
        You are a command interpreter for StreamVibes, an app that tracks movies, series, anime, and telenovelas (novelas).
        You translate the user's natural-language request into a list of tool calls that the app will execute.

        Current item context:
        - Title: "\(item.title)"
        - Category: \(item.category)
        - Year: \(yearStr)
        - Genre: \(genreStr)
        - Has trailer: \(hasTrailer)
        - Current platforms: \(platformsStr)\(seasonsBlock)

        The user said: "\(escapedInput)"

        Available tools (return ONE OR MORE in execution order):

        BROAD:
        - "refresh_all": refresh EVERY field (poster, overview, ratings, platforms, year, genre, trailer). Use ONLY when the user asks for a sweeping refresh ("fix everything", "refresh this", "improve it").

        FOCUSED FIELD DISCOVERY (each one searches trusted sources + AI for ONE specific field):
        - "find_title": find the canonical/official title.
        - "find_poster": find a better poster/cover image.
        - "find_trailer": find a better trailer URL.
        - "find_overview": find or rewrite the overview/description.
        - "find_genre": find/correct the primary genre.
        - "find_year": find/correct the release year.
        - "find_ratings": find IMDb and Rotten Tomatoes scores.
        - "find_platforms": exhaustively search for streaming services for this item.

        MANUAL EDITS (use when the user provides the exact value themselves):
        - "set_title": rename to a specific title. Requires "title".
        - "set_year": set the year. Requires "year".
        - "set_genre": set the genre. Requires "genre".
        - "set_overview": set the overview text. Requires "overview".
        - "add_platform": add ONE streaming service the user named. Requires "platform".
        - "remove_platform": remove ONE streaming service the user named. Requires "platform".

        SEASONS / EPISODES (series, anime, and novela only):
        - "fetch_seasons": fetch and save the season list.
        - "fetch_episodes": fetch episodes for ONE season. Requires "season". Use to fill missing episodes for a specific season.
        - "fetch_episode": fetch ONE single episode. Requires "season" and "episode".

        - "unknown": only when you cannot confidently map the user's request.

        Rules:
        - PREFER focused find_* tools over refresh_all. If the user only mentions ONE field (e.g. "the trailer is wrong"), pick the matching find_* tool, NOT refresh_all.
        - If the user asks for multiple things, return MULTIPLE actions in the "actions" array, in the order they should run.
        - If the user says "fix everything", "make this perfect", or similar broad requests, expand into refresh_all + (for series/anime/novela with missing episodes) fetch_seasons + fetch_episodes per missing season.
        - Use set_* (not find_*) when the user provides the exact value themselves (e.g. "change the year to 1985" → set_year with year=1985).
        - Use find_* (not set_*) when the user wants the AI to figure out the value (e.g. "what year is this?" or "fix the year" → find_year).
        - For fetch_episodes / fetch_episode, only emit when category is series, anime, or novela.
        - Use null for any field that does not apply to a given action.
        - Available platform labels: Apple TV+, Netflix, Max, Disney+, Hulu, Prime Video, Peacock, Paramount+, Crunchyroll, YouTube, Theaters, Other.

        Respond with this exact JSON shape:
        {
          "actions": [
            {
              "action": "find_trailer",
              "title": null,
              "platform": null,
              "year": null,
              "genre": null,
              "overview": null,
              "season": null,
              "episode": null,
              "hint": "optional disambiguation context the user provided",
              "explanation": "Brief sentence describing what you will do for this step"
            }
          ]
        }
        \(Self.strictJSONRules)
        """

        do {
            let output = try await runPrompt(provider: provider, prompt: prompt)
            return parseBuddyChatItemPlans(output)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func parseBuddyChatItemPlans(_ raw: String) -> [BuddyChatItemPlan]? {
        var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if jsonStr.contains("```") {
            let lines = jsonStr.components(separatedBy: "\n")
            jsonStr = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let start = jsonStr.firstIndex(of: "{"), let end = jsonStr.lastIndex(of: "}") {
            jsonStr = String(jsonStr[start...end])
        }

        guard let data = jsonStr.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Accept both {"actions": [...]} and a single {action: ...} for resilience.
        let rawActions: [[String: Any]]
        if let arr = root["actions"] as? [[String: Any]] {
            rawActions = arr
        } else if root["action"] is String {
            rawActions = [root]
        } else {
            return nil
        }

        let plans = rawActions.compactMap { dict -> BuddyChatItemPlan? in
            let actionRaw = (dict["action"] as? String)?.lowercased() ?? "unknown"
            // Skip the action key itself if the model put the title there.
            let title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let action = BuddyChatItemActionType(rawValue: actionRaw) ?? .unknown
            let platform = (dict["platform"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let year = intValue(from: dict["year"])
            let genre = (dict["genre"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let overview = (dict["overview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let season = intValue(from: dict["season"] ?? dict["seasonNumber"] ?? dict["season_number"])
            let episode = intValue(from: dict["episode"] ?? dict["episodeNumber"] ?? dict["episode_number"])
            let hint = (dict["hint"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let explanation = (dict["explanation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return BuddyChatItemPlan(
                action: action,
                title: (title?.isEmpty == false) ? title : nil,
                platform: (platform?.isEmpty == false) ? platform : nil,
                year: year,
                genre: (genre?.isEmpty == false) ? genre : nil,
                overview: (overview?.isEmpty == false) ? overview : nil,
                seasonNumber: season,
                episodeNumber: episode,
                hint: (hint?.isEmpty == false) ? hint : nil,
                explanation: explanation.isEmpty ? "Working on it..." : explanation
            )
        }

        return plans.isEmpty ? nil : plans
    }

    enum AIError: LocalizedError {
        case noProvider
        case cancelled
        case cliError(String)
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .noProvider: return "No AI provider configured"
            case .cancelled: return "AI request canceled."
            case .cliError(let msg): return "CLI error: \(msg)"
            case .apiError(let msg): return "API error: \(msg)"
            }
        }
    }
}
