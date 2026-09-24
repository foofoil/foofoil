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
    private var searchTask: Task<Void, Never>?
    private var generation = 0
    private var rawFiles: [SpotlightFileResult] = []
    private var userMovedSelection = false
    private var isResetting = false
    var openResult: ((UUID) -> Void)?
    var openWebURL: ((URL) -> Void)?
    var openFile: ((URL) -> Void)?
    var enableFileSearch: (() -> Void)?
    var isFileSearchAuthorized: Bool { SpotlightSearchAccess.shared.isAuthorized }

    func disableFileSearch() {
        stop()
        SpotlightSearchAccess.shared.clear()
        performSearch()
    }

    init(historySearch: @escaping (String) async -> [HistorySearchResult] = { await HistoryRepository.shared.search($0) },
         fileSearch: ((String, @escaping (SpotlightSearchOutcome) -> Void) -> Void)? = nil,
         cancelFiles: (() -> Void)? = nil) {
        self.historySearch = historySearch
        let service = SpotlightFileSearch()
        self.fileSearch = fileSearch ?? { text, completion in
            service.start(text: text, completion: completion)
        }
        self.cancelFiles = cancelFiles ?? { service.cancel() }
    }

    var isSearching: Bool { isHistorySearching || isFileSearching }
    /// 两个来源都结束且没有任何候选时显示整体空态；来源仍加载或已给出具体状态时不抢先下结论。
    var showsOverallEmptyState: Bool {
        guard !isSearching else { return false }
        if mode == .url { return resultCount == 0 }
        return results.isEmpty && files.isEmpty && openURL == nil && fileStatus == nil
    }
    var itemIDs: [String] {
        results.map { "history:\($0.id)" } + files.map { "file:\($0.id)" }
            + (openURL.map { ["url:\($0.absoluteString)"] } ?? [])
    }
    var resultCount: Int { itemIDs.count }
    var selectedIndex: Int? { selectedID.flatMap { itemIDs.firstIndex(of: $0) } }

    func reset(mode: HistorySearchMode = .history, initialQuery: String? = nil) {
        stop()
        isResetting = true
        self.mode = mode
        query = initialQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        isResetting = false
        shouldSelectAll = !query.isEmpty
        focusRequest += 1
        performSearch()
    }

    func stop() {
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
        guard let index = selectedIndex else { return }
        if results.indices.contains(index) { open(results[index]) }
        else if files.indices.contains(index - results.count) { openFile?(files[index - results.count].url) }
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
        files = SpotlightFileResult.ranked(rawFiles, query: query.trimmingCharacters(in: .whitespacesAndNewlines), excluding: paths)
    }

    private func performSearch() {
        stop()
        let currentGeneration = generation
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []; files = []; rawFiles = []
        fileStatus = nil; openError = nil
        userMovedSelection = false
        openURL = trimmed.isEmpty ? nil : Self.url(from: trimmed)
        selectedID = itemIDs.first
        guard !trimmed.isEmpty else { return }
        isHistorySearching = true
        isFileSearching = mode == .history
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !Task.isCancelled, currentGeneration == self.generation else { return }
            if self.mode == .history {
                self.fileSearch(trimmed) { [weak self] outcome in
                    guard let self, currentGeneration == self.generation else { return }
                    let previousIndex = self.selectedIndex
                    switch outcome {
                    case .progress(let files):
                        self.rawFiles = files
                        self.mergeFiles()
                        self.reconcileSelection(previousIndex: previousIndex)
                        return
                    case .results(let files): self.rawFiles = files
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
            let values = await self.historySearch(trimmed)
            guard !Task.isCancelled, currentGeneration == self.generation else { return }
            let previousIndex = self.selectedIndex
            self.results = self.mode == .url ? values.filter { $0.contentKind == .web } : values
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
