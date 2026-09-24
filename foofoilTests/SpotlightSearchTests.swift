import Foundation
import Testing
@testable import foofoil

@MainActor
struct SpotlightSearchTests {
    private func file(_ path: String, date: Double = 0) -> SpotlightFileResult {
        .init(url: URL(fileURLWithPath: path), modifiedAt: Date(timeIntervalSince1970: date))
    }

    private func history(_ title: String, path: String? = nil, kind: HistoryContentKind = .text) -> HistorySearchResult {
        .init(id: UUID(), title: title, contentKind: kind, thumbnailPath: nil,
              matchedSnippet: nil, matchedPageNumber: nil, score: 1, sourcePath: path)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Search did not reach expected state")
    }

    @Test func rankingDeduplicatesPathsWithoutFoldingCase() {
        let files = [file("/docs/my report.txt", date: 50), file("/docs/report-old.txt", date: 40),
                     file("/docs/report.txt"), file("/other/report.txt"), file("/docs/Report.txt"),
                     file("/docs/report.txt")]
        let ranked = SpotlightFileResult.ranked(files, query: "report", excluding: ["/docs/report.txt"])
        #expect(ranked.count == 4)
        #expect(ranked.prefix(2).allSatisfy { $0.name.lowercased() == "report.txt" })
        #expect(ranked.last?.name == "my report.txt")
        let many = (0..<30).map { file("/docs/report-\($0).txt") }
        #expect(SpotlightFileResult.ranked(many, query: "report").count == 20)
    }

    @Test func predicateTreatsUserInputLiterally() {
        for text in ["中文", "a*b", "a?b", "quote'\"", "a\\b"] {
            let predicate = SpotlightFileSearch.predicate(for: text)
            #expect(predicate.evaluate(with: ["kMDItemFSName": "prefix-\(text).txt", "kMDItemContentType": "public.plain-text"]))
        }
        #expect(!SpotlightFileSearch.predicate(for: "a*b").evaluate(with: ["kMDItemFSName": "axyzb.txt", "kMDItemContentType": "public.plain-text"]))
    }

    @Test func capabilityFilteringExcludesApplicationsAndDirectories() {
        #expect(SpotlightFileSearch.supports(url: URL(fileURLWithPath: "/a.txt"), typeIdentifier: "public.plain-text", extensions: []))
        #expect(!SpotlightFileSearch.supports(url: URL(fileURLWithPath: "/a.app"), typeIdentifier: "com.apple.application-bundle", extensions: ["app"]))
        #expect(!SpotlightFileSearch.supports(url: URL(fileURLWithPath: "/a.txt"), typeIdentifier: "public.folder", extensions: ["txt"]))
        #expect(SpotlightFileSearch.supports(url: URL(fileURLWithPath: "/a.custom"), typeIdentifier: "public.data", extensions: ["custom"]))
    }

    @Test func lateResultsCannotOverwriteNewQueryOrClosedPanel() async throws {
        var callbacks: [String: (SpotlightSearchOutcome) -> Void] = [:]
        var cancellations = 0
        let model = HistorySearchViewModel(historySearch: { _ in [] }, fileSearch: { callbacks[$0] = $1 }, cancelFiles: { cancellations += 1 })
        model.query = "old"
        try await eventually { callbacks["old"] != nil }
        model.query = "new"
        try await eventually { callbacks["new"] != nil }
        callbacks["old"]?(.results([file("/old.txt")]))
        #expect(model.files.isEmpty)
        callbacks["new"]?(.results([file("/new.txt")]))
        #expect(model.files.map(\.name) == ["new.txt"])
        model.stop()
        callbacks["new"]?(.results([file("/late.txt")]))
        #expect(model.files.map(\.name) == ["new.txt"])
        #expect(!model.isSearching)
        #expect(cancellations >= 3)
    }

    @Test func historyArrivingLaterPreservesUserSelectionAndDeduplicates() async throws {
        var historyContinuation: CheckedContinuation<[HistorySearchResult], Never>?
        var callback: ((SpotlightSearchOutcome) -> Void)?
        let model = HistorySearchViewModel(historySearch: { _ in
            await withCheckedContinuation { historyContinuation = $0 }
        }, fileSearch: { _, value in callback = value }, cancelFiles: {})
        model.query = "report"
        try await eventually { callback != nil && historyContinuation != nil }
        callback?(.progress([file("/a/report.txt"), file("/b/report.txt")]))
        #expect(model.isFileSearching)
        model.moveSelection(by: 1)
        let selected = model.selectedID
        historyContinuation?.resume(returning: [history("report", path: "/a/report.txt")])
        try await eventually { !model.isHistorySearching }
        #expect(model.files.map(\.id) == ["/b/report.txt"])
        #expect(model.selectedID == selected)
        #expect(model.selectedIndex == 1)
        callback?(.results([file("/a/report.txt"), file("/b/report.txt")]))
        #expect(!model.isFileSearching)
        #expect(model.selectedID == selected)
        var opened: URL?
        model.openFile = { opened = $0 }
        model.openSelected()
        #expect(opened?.path == "/b/report.txt")
        model.stop()
    }

    @Test func timeoutDoesNotDiscardHistoryAndURLModeNeverStartsFiles() async throws {
        let hit = history("report")
        var callback: ((SpotlightSearchOutcome) -> Void)?
        var starts = 0
        let model = HistorySearchViewModel(historySearch: { _ in [hit] }, fileSearch: { _, value in starts += 1; callback = value }, cancelFiles: {})
        model.query = "report"
        try await eventually { callback != nil && !model.isHistorySearching }
        callback?(.timedOut)
        #expect(model.results == [hit])
        #expect(model.fileStatus == .timedOut)
        #expect(!model.isSearching)
        model.reset(mode: .url, initialQuery: "example.com")
        try await eventually { !model.isHistorySearching }
        #expect(starts == 1)
        #expect(model.results.isEmpty)
        #expect(model.openURL?.host == "example.com")
        #expect(model.selectedIndex == 0)
        model.query = "  "
        #expect(model.resultCount == 0)
        #expect(!model.isSearching)
        model.stop()
    }

    @Test func overallEmptyStateWaitsForBothSourcesAndFolderStatus() async throws {
        var historyContinuation: CheckedContinuation<[HistorySearchResult], Never>?
        var callback: ((SpotlightSearchOutcome) -> Void)?
        let model = HistorySearchViewModel(historySearch: { _ in
            await withCheckedContinuation { historyContinuation = $0 }
        }, fileSearch: { _, value in callback = value }, cancelFiles: {})
        model.query = "nothing"
        try await eventually { callback != nil && historyContinuation != nil }
        // 历史仍在加载时不能抢先显示空态。
        #expect(!model.showsOverallEmptyState)
        callback?(.results([]))
        #expect(!model.showsOverallEmptyState)
        historyContinuation?.resume(returning: [])
        try await eventually { !model.isHistorySearching }
        #expect(model.showsOverallEmptyState)
        // 文件来源给出明确状态时展示具体说明而不是笼统空态。
        callback?(.foldersUnavailable)
        #expect(!model.showsOverallEmptyState)
        #expect(model.fileStatus == .foldersUnavailable)
        #expect(model.fileStatus?.isRetryable == false)
        #expect(model.fileStatus?.localizationKey == "File Search Folders Unavailable")
        model.stop()
    }
    @Test func fileAccessDistinguishesReadableAndMissingFiles() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("Spotlight open validation".utf8).write(to: url)
        #expect(await HistorySearchWindowController.fileAccess(url) == .readable)
        try FileManager.default.removeItem(at: url)
        #expect(await HistorySearchWindowController.fileAccess(url) == .unavailable)
    }

    @Test func historyQueryProjectsSourceIdentityForCrossSourceDeduplication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        var config = WindowConfig(id: UUID(), originalImageName: "spotlight-report", text: "report")
        config.sourceFingerprint = "file:/documents/Report.txt"
        #expect(repository.upsert(config))
        let results = await repository.search("spotlight-report")
        #expect(results.first?.sourcePath == "/documents/Report.txt")
    }

    @Test func explicitScopesRejectSiblingAndOutsidePaths() {
        let scopes = [URL(fileURLWithPath: "/Users/test/Documents")]
        #expect(SpotlightFileSearch.isWithinScopes(URL(fileURLWithPath: "/Users/test/Documents/a.txt"), scopes: scopes))
        #expect(!SpotlightFileSearch.isWithinScopes(URL(fileURLWithPath: "/Users/test/Documents-other/a.txt"), scopes: scopes))
        #expect(!SpotlightFileSearch.isWithinScopes(URL(fileURLWithPath: "/Library/a.txt"), scopes: scopes))
        #expect(!SpotlightFileSearch.isWithinScopes(URL(fileURLWithPath: "/Users/test/Documents/../a.txt"), scopes: scopes))
    }

    @Test func missingScopeDoesNotStartAnUnrestrictedQuery() {
        let service = SpotlightFileSearch()
        var needsFolder = false
        service.start(text: "report", scopes: [], extensions: []) { outcome in
            if case .needsFolder = outcome { needsFolder = true }
        }
        #expect(needsFolder)
        service.cancel()
    }

    @Test func searchFolderBookmarksRoundTripThroughDefaults() throws {
        let suiteName = "SpotlightSearchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folders = SpotlightSearchFolders(defaults: defaults)
        #expect(!folders.hasFolders)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try folders.replace(with: [directory])
        #expect(folders.hasFolders)
        let restored = try folders.beginAccess()
        defer { restored.forEach { $0.stopAccessingSecurityScopedResource() } }
        #expect(restored.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
            == [directory.resolvingSymlinksInPath().standardizedFileURL.path])

        folders.clear()
        #expect(!folders.hasFolders)
        #expect(try folders.beginAccess().isEmpty)
    }

}

/// 用通知驱动真正的查询服务，复现“已有结果但 gathering 尚未结束”的时序。
nonisolated private final class PendingMetadataItem: NSMetadataItem {
    var values: [String: Any] = [:]
    override func value(forAttribute key: String) -> Any? { values[key] }
}

nonisolated private final class PendingMetadataQuery: NSMetadataQuery {
    var rows: [[String: Any]] = []
    var stopCount = 0
    override var resultCount: Int { rows.count }
    override func start() -> Bool { true }
    override func stop() { stopCount += 1 }
    override func disableUpdates() {}
    override func enableUpdates() {}
    override func result(at idx: Int) -> Any {
        let item = PendingMetadataItem()
        item.values = rows[idx]
        return item
    }
}

@MainActor
struct SpotlightGatheringTests {
    private func row(_ index: Int) -> [String: Any] {
        ["kMDItemPath": "/chosen/report-\(index).txt", "kMDItemContentType": "public.plain-text"]
    }

    @Test func broadQueryFinishesAtCandidateBudgetWithoutWaitingForGathering() async throws {
        let query = PendingMetadataQuery()
        let service = SpotlightFileSearch(makeQuery: { query }, deadline: .milliseconds(30))
        var results: [SpotlightFileResult] = []
        var callbacks = 0
        service.start(text: "report", scopes: [URL(fileURLWithPath: "/chosen")], extensions: []) { outcome in
            callbacks += 1
            if case .results(let files) = outcome { results = files }
        }
        query.rows = (0..<16_932).map(row)
        NotificationCenter.default.post(name: .NSMetadataQueryGatheringProgress, object: query)
        #expect(results.count == 200)
        #expect(query.stopCount == 1)
        try await Task.sleep(for: .milliseconds(60))
        #expect(callbacks == 1)
    }

    @Test func sparseProgressIsVisibleBeforeCompletion() {
        let query = PendingMetadataQuery()
        let service = SpotlightFileSearch(makeQuery: { query })
        var events: [String] = []
        service.start(text: "report", scopes: [URL(fileURLWithPath: "/chosen")], extensions: []) { outcome in
            switch outcome {
            case .progress(let files): events.append("progress:\(files.count)")
            case .results(let files): events.append("complete:\(files.count)")
            default: events.append("failure")
            }
        }
        query.rows = [row(1)]
        NotificationCenter.default.post(name: .NSMetadataQueryGatheringProgress, object: query)
        #expect(events == ["progress:1"])
        #expect(query.stopCount == 0)
        NotificationCenter.default.post(name: .NSMetadataQueryDidFinishGathering, object: query)
        #expect(events == ["progress:1", "complete:1"])
        #expect(query.stopCount == 1)
    }

    @Test func deadlineKeepsResultsEvenWhenNoProgressNotificationArrives() async throws {
        let query = PendingMetadataQuery()
        let service = SpotlightFileSearch(makeQuery: { query }, deadline: .milliseconds(20))
        let outcome: SpotlightSearchOutcome = await withCheckedContinuation { continuation in
            service.start(text: "report", scopes: [URL(fileURLWithPath: "/chosen")], extensions: []) { continuation.resume(returning: $0) }
            query.rows = [row(1)]
        }
        guard case .results(let files) = outcome else { Issue.record("Available results were incorrectly discarded at deadline"); return }
        #expect(files.count == 1)
        #expect(query.stopCount == 1)
    }

    @Test func stalledEmptyQueryStillTimesOut() async {
        let query = PendingMetadataQuery()
        let service = SpotlightFileSearch(makeQuery: { query }, deadline: .milliseconds(20))
        let outcome: SpotlightSearchOutcome = await withCheckedContinuation { continuation in
            service.start(text: "report", scopes: [URL(fileURLWithPath: "/chosen")], extensions: []) { continuation.resume(returning: $0) }
        }
        guard case .timedOut = outcome else { Issue.record("An unfinished empty query must not claim completion"); return }
        #expect(query.stopCount == 1)
    }
}
