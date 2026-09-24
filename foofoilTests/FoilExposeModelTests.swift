//
//  FoilExposeModelTests.swift
//  foofoil
//
//  Created by tolg on 2026/9/15.
//

import Foundation
import Testing
@testable import foofoil

@MainActor
struct FoilExposeModelTests {
    private func makeItem(
        id: UUID = UUID(),
        title: String = "item",
        isHistoryEntry: Bool = false,
        sourcePath: String? = nil
    ) -> FoilExposeItem {
        FoilExposeItem(
            id: id,
            controller: nil,
            isHistoryEntry: isHistoryEntry,
            title: title,
            symbolName: "doc",
            contentKind: .text,
            thumbnailPath: nil,
            sourcePath: sourcePath
        )
    }

    private func makeModel(openCount: Int = 6, historyCount: Int = 2) -> FoilExposeModel {
        FoilExposeModel(
            items: (0..<openCount).map { _ in makeItem() },
            historyItems: (0..<historyCount).map { _ in makeItem(isHistoryEntry: true) },
            fileSearch: { _, _ in },
            cancelFiles: {}
        )
    }

    private func makeModel(items: [FoilExposeItem], historyItems: [FoilExposeItem]) -> FoilExposeModel {
        FoilExposeModel(items: items, historyItems: historyItems, fileSearch: { _, _ in }, cancelFiles: {})
    }

    @Test func currentItemsCombineOpenFoilsBeforeHistory() {
        let model = makeModel()
        #expect(model.currentItems.count == 8)
        #expect(model.currentItems.prefix(6).allSatisfy { !$0.isHistoryEntry })
        #expect(model.currentItems.suffix(2).allSatisfy { $0.isHistoryEntry })
    }

    @Test func historyEntriesAlreadyOpenAreNotShownTwice() {
        let openID = UUID()
        let model = makeModel(
            items: [makeItem(id: openID, title: "Open")],
            historyItems: [
                makeItem(id: openID, title: "Open", isHistoryEntry: true),
                makeItem(title: "Archive", isHistoryEntry: true)
            ]
        )
        #expect(model.currentItems.count == 2)
        #expect(model.currentItems.filter { $0.id == openID }.count == 1)
        #expect(model.currentItems.last?.title == "Archive")
    }

    @Test func moveSelectionClampsToBoundaries() {
        let model = makeModel()
        model.moveSelection(.left)
        #expect(model.selectedIndex == 0)
        model.selectedIndex = model.currentItems.count - 1
        model.moveSelection(.right)
        #expect(model.selectedIndex == model.currentItems.count - 1)
    }

    @Test func moveSelectionUsesColumnCountForVerticalJumps() {
        let model = makeModel()
        model.columnCount = 4
        model.moveSelection(.down)
        #expect(model.selectedIndex == 4)
        model.moveSelection(.up)
        #expect(model.selectedIndex == 0)
    }

    @Test func rowEdgeJumpsFollowColumnCount() {
        let model = makeModel(historyCount: 0)
        model.columnCount = 4
        // 第二行（下标 4-5，不满一整行）：行首 4，行尾夹紧到 5。
        model.selectedIndex = 5
        model.moveSelectionToRowStart()
        #expect(model.selectedIndex == 4)
        model.moveSelectionToRowEnd()
        #expect(model.selectedIndex == 5)
        // 第一行：行首 0，行尾 3。
        model.selectedIndex = 2
        model.moveSelectionToRowStart()
        #expect(model.selectedIndex == 0)
        model.moveSelectionToRowEnd()
        #expect(model.selectedIndex == 3)
    }

    @Test func searchFiltersOpenFoilsAndHistoryByTitle() {
        let model = makeModel(
            items: [makeItem(title: "Alpha"), makeItem(title: "Beta")],
            historyItems: [makeItem(title: "Alphabet", isHistoryEntry: true)]
        )
        model.searchText = "alp"
        #expect(model.currentItems.map(\.title) == ["Alpha", "Alphabet"])
        // 过滤结果变化后高亮回到第一项。
        model.selectedIndex = 1
        model.searchText = "alphab"
        #expect(model.selectedIndex == 0)
        #expect(model.currentItems.map(\.title) == ["Alphabet"])
    }

    @Test func searchIsCaseAndWhitespaceInsensitive() {
        let model = makeModel(items: [makeItem(title: "Hello World")], historyItems: [])
        model.searchText = "  hello  "
        #expect(model.currentItems.count == 1)
        model.searchText = "   "
        #expect(model.currentItems.count == 1)
    }

    @Test func endSearchKeepsQueryAndFilteredResults() {
        let model = makeModel()
        model.beginSearch()
        model.searchText = "item"
        model.endSearch()
        #expect(model.isSearching == false)
        #expect(model.searchQuery == "item")
        #expect(model.currentItems.count == 8)
    }

    @Test func clearSearchRestoresFullList() {
        let model = makeModel()
        model.beginSearch()
        model.searchText = "不存在的关键字"
        #expect(model.currentItems.isEmpty)
        model.clearSearch()
        #expect(model.isSearching == false)
        #expect(model.searchQuery.isEmpty)
        #expect(model.currentItems.count == 8)
        #expect(model.selectedIndex == 0)
    }

    @Test func itemForKeyOnlyMatchesVisibleEntries() {
        let model = makeModel()
        let first = model.items[0].id
        let second = model.items[1].id
        let hidden = model.items[5].id
        model.setVisibleIDs([first, second])

        #expect(model.item(forKey: "1")?.id == first)
        #expect(model.item(forKey: "2")?.id == second)
        // 不可见项没有编号，直选不命中。
        #expect(model.item(forKey: "6") == nil)
        // 大小写不敏感：字母编号转大写后匹配。
        model.setVisibleIDs([hidden])
        #expect(model.item(forKey: "1")?.id == hidden)
    }

    @Test func itemForKeyMatchesHistoryEntriesInCombinedList() {
        let model = makeModel()
        let history = model.historyItems[0].id
        model.setVisibleIDs([history])
        #expect(model.item(forKey: "1")?.id == history)
    }

    private func file(_ path: String, date: Double = 0) -> SpotlightFileResult {
        .init(url: URL(fileURLWithPath: path), modifiedAt: Date(timeIntervalSince1970: date))
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "File search did not reach expected state")
    }

    @Test func fileSearchOnlyRunsWithAQueryAndClearsOnEmptyInput() async throws {
        var callbacks: [String: (SpotlightSearchOutcome) -> Void] = [:]
        var cancellations = 0
        let model = FoilExposeModel(
            items: [makeItem(title: "Alpha")],
            historyItems: [],
            fileSearch: { callbacks[$0] = $1 },
            cancelFiles: { cancellations += 1 }
        )
        // 空关键字不查询、不呈现文件结果区。
        #expect(!model.showsFileResults)
        model.searchText = "   "
        #expect(!model.showsFileResults)
        #expect(callbacks.isEmpty)

        model.searchText = "alpha"
        #expect(model.showsFileResults)
        try await eventually { callbacks["alpha"] != nil }
        #expect(model.isFileSearching)
        callbacks["alpha"]?(.progress([file("/docs/alpha.txt")]))
        #expect(model.files.map(\.name) == ["alpha.txt"])
        #expect(model.isFileSearching)
        callbacks["alpha"]?(.results([file("/docs/alpha.txt"), file("/docs/alpha-old.txt", date: 5)]))
        #expect(!model.isFileSearching)
        #expect(model.files.map(\.name) == ["alpha.txt", "alpha-old.txt"])

        model.searchText = ""
        #expect(!model.showsFileResults)
        #expect(model.files.isEmpty)
        #expect(cancellations >= 1)
    }

    @Test func lateFileResultsCannotOverwriteANewQuery() async throws {
        var callbacks: [String: (SpotlightSearchOutcome) -> Void] = [:]
        let model = FoilExposeModel(items: [], historyItems: [],
                                    fileSearch: { callbacks[$0] = $1 }, cancelFiles: {})
        model.searchText = "old"
        try await eventually { callbacks["old"] != nil }
        model.searchText = "new"
        try await eventually { callbacks["new"] != nil }
        callbacks["old"]?(.results([file("/old.txt")]))
        #expect(model.files.isEmpty)
        callbacks["new"]?(.results([file("/new.txt")]))
        #expect(model.files.map(\.name) == ["new.txt"])
        // 覆盖层关闭后晚到的回调同样被丢弃。
        model.stopFileSearch()
        callbacks["new"]?(.results([file("/late.txt")]))
        #expect(model.files.map(\.name) == ["new.txt"])
        #expect(!model.isFileSearching)
    }

    @Test func fileResultsSkipFilesAlreadyShownAsHistoryItems() async throws {
        var callback: ((SpotlightSearchOutcome) -> Void)?
        let history = makeItem(title: "Report", isHistoryEntry: true, sourcePath: "/docs/report.txt")
        let model = FoilExposeModel(items: [], historyItems: [history],
                                    fileSearch: { _, value in callback = value }, cancelFiles: {})
        model.searchText = "report"
        try await eventually { callback != nil }
        callback?(.results([file("/docs/report.txt"), file("/docs/report-old.txt", date: 5)]))
        #expect(model.files.map(\.name) == ["report-old.txt"])
    }

    @Test func fileStatusReportsMissingAuthorization() async throws {
        var callback: ((SpotlightSearchOutcome) -> Void)?
        let model = FoilExposeModel(items: [], historyItems: [],
                                    fileSearch: { _, value in callback = value }, cancelFiles: {})
        model.searchText = "report"
        try await eventually { callback != nil }
        callback?(.needsAuthorization)
        #expect(model.fileStatus == .needsAuthorization)
        #expect(!model.isFileSearching)
        // 重新开启后重新查询并清掉旧状态。
        model.restartFileSearch()
        #expect(model.fileStatus == nil)
        #expect(model.isFileSearching)
    }
}
