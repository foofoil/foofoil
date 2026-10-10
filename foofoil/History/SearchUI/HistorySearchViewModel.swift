import Foundation
import Combine

enum HistorySearchMode {
    case history
    case url
}

/// 文件来源的结束状态；只有明确原因时才展示具体说明，正常零结果不解释为故障。
enum FileSearchStatus: Equatable {
    case needsAuthorization
    case authorizationUnavailable
    case unavailable
    case timedOut

    var localizationKey: String {
        switch self {
        case .needsAuthorization: "File Search Needs Authorization"
        case .authorizationUnavailable: "File Search Authorization Unavailable"
        case .unavailable: "File Search Unavailable"
        case .timedOut: "File Search Timed Out"
        }
    }

    var isRetryable: Bool { self == .unavailable || self == .timedOut }
}

@MainActor
final class HistorySearchViewModel: ObservableObject {
    @Published var query = "" { didSet { if !isResetting { performSearch() } } }
    @Published private(set) var mode: HistorySearchMode = .history
    @Published private(set) var results: [HistorySearchResult] = []
    @Published private(set) var musicResults: [AppleMusicLibraryItem] = []
    @Published private(set) var expandedMusicCategories: Set<AppleMusicSearchCategory> = []
    @Published var resultFilter: SearchResultFilter = .all { didSet { if oldValue != resultFilter && !isResetting { performSearch() } } }
    @Published private(set) var musicDisplayCounts: [AppleMusicSearchCategory: Int] = [:]
    private var musicHasMoreCategories: Set<AppleMusicSearchCategory> = []
    @Published private(set) var isMusicSearching = false
    @Published private(set) var musicError: String?
    @Published private(set) var isMusicAuthorized = false
    @Published private(set) var isMusicSearchEnabled = false
    var openMusic: ((AppleMusicLibraryItem) -> Void)?
    var enableMusicSearch: (() -> Void)?
    private var musicTask: Task<Void, Never>?
    private let musicSearch: @MainActor (String, SearchResultFilter) async throws -> AppleMusicSearchPage
    private let musicAuthorized: @MainActor () -> Bool
    private let musicEnabled: @MainActor () -> Bool
    private var musicSettingsCancellable: AnyCancellable?
    private var isActive = false
    @Published private(set) var files: [SpotlightFileResult] = []
    @Published private(set) var openURL: URL?
    @Published private(set) var selectedID: String?
    @Published private(set) var isHistorySearching = false
    @Published private(set) var isFileSearching = false
    @Published private(set) var fileStatus: FileSearchStatus?
    @Published var openError: String?
    @Published private(set) var focusRequest = 0
    @Published private(set) var shouldSelectAll = false

    private let historySearch: (String) async -> [HistorySearchResult]
    private let fileSearch: (String, @escaping (SpotlightSearchOutcome) -> Void) -> Void
    private let cancelFiles: () -> Void
    private var authCancellable: AnyCancellable?
    private var searchTask: Task<Void, Never>?
    private var generation = 0
    private var rawFiles: [SpotlightFileResult] = []
    private var userMovedSelection = false
    private var isResetting = false
    var openCamera: (() -> Void)?
    private let cameraAvailable: () -> Bool
    var showsOpenCamera: Bool { mode == .history && resultFilter == .all && CameraCaptureController.matches(query, available: cameraAvailable()) }
    var openResult: ((UUID) -> Void)?
    var openWebURL: ((URL) -> Void)?
    var openFile: ((URL) -> Void)?
    var enableFileSearch: (() -> Void)?
    var isFileSearchAuthorized: Bool { SpotlightSearchAccess.shared.isAuthorized }

    init(historySearch: @escaping (String) async -> [HistorySearchResult] = { await HistoryRepository.shared.search($0, limit: SearchResultLimits.probe) },
         fileSearch: ((String, @escaping (SpotlightSearchOutcome) -> Void) -> Void)? = nil,
         cancelFiles: (() -> Void)? = nil,
         cameraAvailable: @escaping () -> Bool = { CameraCaptureController.isAvailable },
         musicSearch: (@MainActor (String) async throws -> [AppleMusicLibraryItem])? = nil,
         musicAuthorized: @escaping @MainActor () -> Bool = { AppleMusicLibrary.shared.isAuthorized },
         musicEnabled: @escaping @MainActor () -> Bool = { SettingsStore.shared.appleMusicSearchEnabled }) {
        self.musicSearch = { term, filter in
            if let musicSearch { return .init(items: try await musicSearch(term)) }
            return try await AppleMusicLibrary.shared.searchPage(term, filter: filter)
        }
        self.musicAuthorized = musicAuthorized
        self.musicEnabled = musicEnabled
        self.isMusicSearchEnabled = musicEnabled()
        self.cameraAvailable = cameraAvailable
        self.historySearch = historySearch
        let service = SpotlightFileSearch()
        self.fileSearch = fileSearch ?? { text, completion in
            service.start(text: text, completion: completion)
        }
        self.cancelFiles = cancelFiles ?? { service.cancel() }
        self.authCancellable = NotificationCenter.default.publisher(for: .spotlightSearchAuthorizationDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        musicSettingsCancellable = NotificationCenter.default.publisher(for: .appleMusicSearchDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isMusicSearchEnabled = self.musicEnabled()
                if !self.isMusicSearchEnabled && self.resultFilter.musicCategory != nil {
                    self.isResetting = true
                    self.resultFilter = .all
                    self.isResetting = false
                }
                if self.isActive { self.performSearch() }
            }
    }

    var isSearching: Bool { isHistorySearching || isFileSearching || isMusicSearching }
    func musicResults(in category: AppleMusicSearchCategory) -> [AppleMusicLibraryItem] {
        musicResults.filter { $0.searchCategory == category }
    }
    private static let initialCount = 12
    @Published private(set) var historyDisplayCount = 12
    @Published private(set) var fileDisplayCount = 12
    var hasExpandedResults: Bool { !expandedMusicCategories.isEmpty || historyDisplayCount > Self.initialCount || fileDisplayCount > Self.initialCount }
    var canExpandHistoryResults: Bool { resultCount < SearchResultLimits.maximum && visibleResults.count < results.count }
    var canExpandFileResults: Bool { resultCount < SearchResultLimits.maximum && visibleFiles.count < files.count }
    func expandHistoryResults() {
        guard canExpandHistoryResults else { return }
        historyDisplayCount = min(SearchResultLimits.maximum, historyDisplayCount + SearchResultLimits.increment)
    }
    func expandFileResults() {
        guard canExpandFileResults else { return }
        fileDisplayCount = min(SearchResultLimits.maximum, fileDisplayCount + SearchResultLimits.increment)
    }
    var budget: SearchResultBudget {
        SearchResultBudget(baseCount: results.count + (showsOpenCamera ? 1 : 0) + (openURL == nil ? 0 : 1),
                           fileCount: files.count,
                           musicCounts: Dictionary(uniqueKeysWithValues: AppleMusicSearchCategory.allCases.map { ($0, musicResults(in: $0).count) }),
                           desiredMusicCounts: musicDisplayCounts, filter: resultFilter,
                           initialCount: resultFilter == .all ? Self.initialCount : SearchResultLimits.initial,
                           desiredBaseCount: mode == .history ? historyDisplayCount + (showsOpenCamera ? 1 : 0) + (openURL == nil ? 0 : 1) : nil,
                           desiredFileCount: resultFilter == .all ? fileDisplayCount : nil)
    }
    var visibleResults: [HistorySearchResult] {
        Array(results.prefix(max(0, budget.base - (showsOpenCamera ? 1 : 0) - (openURL == nil ? 0 : 1))))
    }
    var visibleFiles: [SpotlightFileResult] { Array(files.prefix(budget.files)) }
    func visibleMusicResults(in category: AppleMusicSearchCategory) -> [AppleMusicLibraryItem] {
        Array(musicResults(in: category).prefix(budget.music[category, default: 0]))
    }
    var visibleMusicResults: [AppleMusicLibraryItem] {
        AppleMusicSearchCategory.allCases.flatMap { visibleMusicResults(in: $0) }
    }
    func canExpandMusicResults(in category: AppleMusicSearchCategory) -> Bool {
        resultCount < SearchResultLimits.maximum && visibleMusicResults(in: category).count < musicResults(in: category).count
    }
    func expandMusicResults(in category: AppleMusicSearchCategory) {
        guard canExpandMusicResults(in: category) else { return }
        expandedMusicCategories.insert(category)
        musicDisplayCounts[category] = min(SearchResultLimits.maximum, musicDisplayCounts[category, default: resultFilter == .all ? Self.initialCount : SearchResultLimits.initial] + SearchResultLimits.increment)
    }
    var showsResultLimitNotice: Bool {
        let hasExtra = visibleResults.count < results.count || visibleFiles.count < files.count
            || AppleMusicSearchCategory.allCases.contains { resultFilter.includes($0) && (visibleMusicResults(in: $0).count < musicResults(in: $0).count || musicHasMoreCategories.contains($0)) }
        return hasExtra && (resultCount == SearchResultLimits.maximum || (!canExpandHistoryResults && !canExpandFileResults && !AppleMusicSearchCategory.allCases.contains { canExpandMusicResults(in: $0) }))
    }
    /// 所有来源都结束且没有任何候选时显示整体空态；来源仍加载或已给出具体状态时不抢先下结论。
    var showsOverallEmptyState: Bool {
        guard !isSearching else { return false }
        if mode == .url { return resultCount == 0 }
        return results.isEmpty && files.isEmpty && musicResults.isEmpty && musicError == nil && openURL == nil && !showsOpenCamera && fileStatus == nil
    }
    var itemIDs: [String] {
        (showsOpenCamera ? ["camera"] : []) + visibleResults.map { "history:\($0.id)" } + visibleFiles.map { "file:\($0.id)" }
            + visibleMusicResults.map { "music:\($0.id)" }
            + (openURL.map { ["url:\($0.absoluteString)"] } ?? [])
    }
    var resultCount: Int { itemIDs.count }
    var selectedIndex: Int? { selectedID.flatMap { itemIDs.firstIndex(of: $0) } }

    func reset(mode: HistorySearchMode = .history, initialQuery: String? = nil) {
        stop()
        isResetting = true
        self.mode = mode
        resultFilter = .all
        query = initialQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        isResetting = false
        shouldSelectAll = !query.isEmpty
        focusRequest += 1
        performSearch()
    }

    func stop() {
        isActive = false
        musicTask?.cancel()
        musicTask = nil
        isMusicSearching = false
        searchTask?.cancel()
        searchTask = nil
        generation += 1
        cancelFiles()
        isHistorySearching = false
        isFileSearching = false
    }

    func resume() { focusRequest += 1; performSearch() }
    func retry() { performSearch() }

    func moveSelection(by offset: Int) {
        guard resultCount > 0 else { return }
        userMovedSelection = true
        selectedID = itemIDs[min(max((selectedIndex ?? 0) + offset, 0), resultCount - 1)]
    }

    func openSelected() {
        if selectedID == "camera" { openCamera?(); return }
        guard let selectedID else { return }
        if let row = visibleResults.first(where: { "history:\($0.id)" == selectedID }) { open(row) }
        else if let file = visibleFiles.first(where: { "file:\($0.id)" == selectedID }) { openFile?(file.url) }
        else if let music = visibleMusicResults.first(where: { "music:\($0.id)" == selectedID }) { openMusic?(music) }
        else { openURLResult() }
    }

    func open(_ result: HistorySearchResult) { openResult?(result.id) }
    func openURLResult() { if let openURL { openWebURL?(openURL) } }

    func delete(_ result: HistorySearchResult) {
        if let config = HistoryRepository.shared.config(id: result.id) {
            HistoryManager.shared.removeFromHistory(config)
        }
        performSearch()
    }

    private func reconcileSelection(previousIndex: Int?) {
        if userMovedSelection, let selectedID, itemIDs.contains(selectedID) { return }
        let index = userMovedSelection ? (previousIndex ?? 0) : 0
        selectedID = itemIDs.isEmpty ? nil : itemIDs[min(index, itemIDs.count - 1)]
    }

    private func mergeFiles() {
        let paths = Set(results.compactMap(\.sourcePath).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        files = SpotlightFileResult.ranked(rawFiles, query: query.trimmingCharacters(in: .whitespacesAndNewlines), excluding: paths, limit: SearchResultLimits.probe)
    }

    private func performSearch() {
        stop()
        isActive = true
        let currentGeneration = generation
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []; files = []; rawFiles = []
        musicResults = []; musicError = nil
        expandedMusicCategories = []; musicDisplayCounts = [:]; musicHasMoreCategories = []
        historyDisplayCount = Self.initialCount; fileDisplayCount = Self.initialCount
        isMusicAuthorized = musicAuthorized()
        isMusicSearchEnabled = musicEnabled()
        fileStatus = nil; openError = nil
        userMovedSelection = false
        openURL = trimmed.isEmpty || resultFilter != .all ? nil : Self.url(from: trimmed)
        selectedID = itemIDs.first
        guard !trimmed.isEmpty else { return }
        if mode == .history && resultFilter != .files && isMusicSearchEnabled && isMusicAuthorized {
            isMusicSearching = true
            musicTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled else { return }
                    let page = try await self.musicSearch(trimmed, self.resultFilter)
                    guard !Task.isCancelled, currentGeneration == self.generation else { return }
                    let previousIndex = self.selectedIndex
                    self.musicResults = AppleMusicSearchCategory.allCases.filter { self.resultFilter.includes($0) }.flatMap { category in
                        page.items.lazy.filter { $0.searchCategory == category }.prefix(SearchResultLimits.probe)
                    }
                    self.musicHasMoreCategories = page.hasMoreCategories
                    self.isMusicSearching = false
                    self.reconcileSelection(previousIndex: previousIndex)
                } catch {
                    guard let self, !Task.isCancelled, currentGeneration == self.generation else { return }
                    self.musicError = error.localizedDescription
                    self.isMusicSearching = false
                }
            }
        }
        isHistorySearching = resultFilter == .all
        isFileSearching = mode == .history && resultFilter.includesFiles
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !Task.isCancelled, currentGeneration == self.generation else { return }
            if self.mode == .history && self.resultFilter.includesFiles {
                self.fileSearch(trimmed) { [weak self] outcome in
                    guard let self, currentGeneration == self.generation else { return }
                    let previousIndex = self.selectedIndex
                    switch outcome {
                    case .progress(let files):
                        self.rawFiles = Array(files.prefix(SearchResultLimits.probe))
                        self.mergeFiles()
                        self.reconcileSelection(previousIndex: previousIndex)
                        return
                    case .results(let files): self.rawFiles = Array(files.prefix(SearchResultLimits.probe))
                    case .needsAuthorization: self.fileStatus = .needsAuthorization
                    case .authorizationUnavailable: self.fileStatus = .authorizationUnavailable
                    case .unavailable: self.fileStatus = .unavailable
                    case .timedOut: self.fileStatus = .timedOut
                    }
                    self.isFileSearching = false
                    self.mergeFiles()
                    self.reconcileSelection(previousIndex: previousIndex)
                }
            }
            let values = self.resultFilter == .all ? await self.historySearch(trimmed) : []
            guard !Task.isCancelled, currentGeneration == self.generation else { return }
            let previousIndex = self.selectedIndex
            self.results = Array((self.mode == .url ? values.filter { $0.contentKind == .web } : values).prefix(SearchResultLimits.probe))
            self.isHistorySearching = false
            self.mergeFiles()
            self.reconcileSelection(previousIndex: previousIndex)
        }
    }

    private static func url(from input: String) -> URL? {
        guard !input.isEmpty, !input.contains(where: \.isWhitespace) else { return nil }
        let candidate: String
        if input.lowercased().hasPrefix("http://") || input.lowercased().hasPrefix("https://") {
            candidate = input
        } else if input == "localhost" || input.contains(".") {
            candidate = "https://\(input)"
        } else {
            return nil
        }
        guard let url = URL(string: candidate), let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
