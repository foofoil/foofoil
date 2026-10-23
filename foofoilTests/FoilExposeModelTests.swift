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
            cancelFiles: {}, musicEnabled: { false }
        )
    }

    private func makeModel(items: [FoilExposeItem], historyItems: [FoilExposeItem]) -> FoilExposeModel {
        FoilExposeModel(items: items, historyItems: historyItems, fileSearch: { _, _ in }, cancelFiles: {}, musicEnabled: { false })
    }

    @Test func renameRefreshKeepsSelectionAndUpdatesSearchMatches() {
        let open = makeItem(title: "Old title")
        let history = makeItem(title: "History title", isHistoryEntry: true)
        let model = makeModel(items: [open], historyItems: [history])
        model.selectedIndex = 1
        let renamed = makeItem(id: history.id, title: "New history title", isHistoryEntry: true)
        model.refreshItems(open: [open], history: [renamed])
        #expect(model.currentItems[model.selectedIndex].id == history.id)
        #expect(model.currentItems[model.selectedIndex].title == "New history title")
        model.searchText = "Old"
        let renamedOpen = makeItem(id: open.id, title: "New open title")
        model.refreshItems(open: [renamedOpen], history: [renamed])
        #expect(model.currentItems.isEmpty)
        #expect(model.selectedIndex == 0)
        model.searchText = "New"
        #expect(model.currentItems.map(\.id) == [open.id, history.id])
    }

    @Test func deletingHistorySelectsNextThenPreviousAndHandlesEmptyResults() {
        let open = makeItem(title: "Open")
        let history = (0..<3).map { makeItem(title: "History \($0)", isHistoryEntry: true) }
        let model = makeModel(items: [open], historyItems: history)
        model.selectedIndex = 2
        model.replaceHistoryItems([history[0], history[2]], deleting: history[1].id)
        #expect(model.highlightedItem?.id == history[2].id)
        model.replaceHistoryItems([history[0]], deleting: history[2].id)
        #expect(model.highlightedItem?.id == history[0].id)
        model.replaceHistoryItems([], deleting: history[0].id)
        #expect(model.highlightedItem?.id == open.id)

        let filtered = makeModel(items: [open], historyItems: [history[0]])
        filtered.searchText = "History"
        filtered.replaceHistoryItems([], deleting: history[0].id)
        #expect(filtered.currentItems.isEmpty)
        #expect(filtered.selectedIndex == 0)
        #expect(filtered.highlightedItem == nil)
        var activated = false
        filtered.onSelect = { _ in activated = true }
        filtered.onOpenFile = { _ in activated = true }
        for direction in [FoilExposeMoveDirection.up, .down, .left, .right] {
            filtered.moveSelection(direction)
        }
        filtered.moveSelectionToRowStart()
        filtered.moveSelectionToRowEnd()
        filtered.openHighlightedResult()
        #expect(!activated)
        #expect(filtered.selectedIndex == 0)
    }

    @Test func deletingFirstHistorySelectsItsSuccessor() {
        let history = (0..<2).map { _ in makeItem(isHistoryEntry: true) }
        let model = makeModel(items: [], historyItems: history)
        model.replaceHistoryItems([history[1]], deleting: history[0].id)
        #expect(model.highlightedItem?.id == history[1].id)
        model.replaceHistoryItems([], deleting: history[1].id)
        #expect(model.currentItems.isEmpty)
        #expect(model.highlightedItem == nil)
    }

    @Test func onlyPinnedHistoryRequiresSingleItemClearConfirmation() {
        for kind in [HistoryContentKind.note, .text, .markdown, .csv, .image, .web, .pdf,
                     .video, .audio, .extensionContent, .ebook, .quickLook, .camera] {
            let history = FoilExposeItem(id: UUID(), controller: nil, isHistoryEntry: true,
                                        title: "History", symbolName: kind.symbolName, contentKind: kind, thumbnailPath: nil)
            #expect(!history.requiresHistoryClearConfirmation)
            var pinned = history
            pinned.historyIsPinned = true
            #expect(pinned.requiresHistoryClearConfirmation)
        }
        #expect(!makeItem().requiresHistoryClearConfirmation)
    }

    @Test func emptyHistoryCategoriesAreHiddenAndSelectionFallsBack() {
        let model = makeModel(items: [], historyItems: [makeItem(title: "Document", isHistoryEntry: true)])
        #expect(model.visibleHistoryCategories == [.all, .documents])
        model.historyCategory = .documents
        model.searchText = "Missing"
        #expect(model.visibleHistoryCategories.isEmpty)
        #expect(model.historyCategory == .all)
        model.searchText = ""
        model.historyCategory = .documents
        model.replaceHistoryItems([])
        #expect(model.visibleHistoryCategories.isEmpty)
        #expect(model.historyCategory == .all)
        #expect(model.currentItems.isEmpty)
    }

    @Test func terminalHistoryCategoryFiltersAndClearsOnlyClosedTerminals() {
        let open = makeItem(title: "Open document")
        let terminal = FoilExposeItem(id: UUID(), controller: nil, isHistoryEntry: true,
                                     title: "Terminal", symbolName: "terminal", contentKind: .terminal, thumbnailPath: nil)
        let document = makeItem(title: "Document", isHistoryEntry: true)
        let model = makeModel(items: [open], historyItems: [document, terminal])
        #expect(model.visibleHistoryCategories == [.all, .documents, .terminal])
        #expect(model.historyCount(in: .terminal) == 1)
        model.historyCategory = .terminal
        #expect(model.currentItems.map(\.id) == [open.id, terminal.id])

        let closed = WindowConfig(id: terminal.id, contentKind: .terminal)
        let active = WindowConfig(id: UUID(), contentKind: .terminal)
        var pinned = WindowConfig(id: UUID(), contentKind: .terminal)
        pinned.historyIsPinned = true
        let other = WindowConfig(id: document.id, contentKind: .text)
        #expect(FoilExposeModel.historyToClear([closed, active, pinned, other], category: .terminal,
                                             openIDs: [active.id]).map(\.id) == [closed.id])
        model.replaceHistoryItems([document])
        #expect(model.historyCategory == .all)
    }

    @Test func clearingCategoryUsesAllClosedRecordsAndInfersKinds() {
        let open = WindowConfig(id: UUID(), text: "Open", contentKind: .note)
        let note = WindowConfig(id: UUID(), text: "Closed", contentKind: .note)
        let inferred = WindowConfig(id: UUID(), originalImageName: "book.epub")
        let document = WindowConfig(id: UUID(), text: "Document", contentKind: .text)
        let camera = WindowConfig(id: UUID(), isCamera: true, contentKind: .camera)
        let configs = [open, note, inferred, document, camera]
        #expect(FoilExposeModel.historyToClear(configs, category: .documents, openIDs: [open.id]).map(\.id) == [inferred.id, document.id])
        #expect(FoilExposeModel.historyToClear(configs, category: .notes, openIDs: [open.id]).map(\.id) == [note.id])
        #expect(FoilExposeModel.historyToClear(configs, category: .all, openIDs: [open.id]).count == 4)
    }

    @Test func historyCategoriesCoverSupportedKinds() {
        #expect(FoilExposeHistoryCategory.allCases.count == 7)
        for kind in [HistoryContentKind.audio, .video] {
            #expect(FoilExposeHistoryCategory.media.includes(kind))
        }
        for kind in [HistoryContentKind.text, .markdown, .csv, .pdf, .quickLook, .ebook] {
            #expect(FoilExposeHistoryCategory.documents.includes(kind))
        }
        #expect(FoilExposeHistoryCategory.images.includes(.image))
        #expect(FoilExposeHistoryCategory.web.includes(.web))
        #expect(FoilExposeHistoryCategory.notes.includes(.note))
        #expect(FoilExposeHistoryCategory.terminal.includes(.terminal))
        for kind in [HistoryContentKind.camera, .extensionContent] {
            #expect(FoilExposeHistoryCategory.all.includes(kind))
            #expect(FoilExposeHistoryCategory.allCases.dropFirst().allSatisfy { !$0.includes(kind) })
        }
    }

    @Test func historyCategoryFiltersOnlyHistoryAndKeepsCountsStable() {
        let open = makeItem(title: "Open document")
        let duplicate = makeItem(id: open.id, title: "Open document", isHistoryEntry: true)
        let document = makeItem(title: "Archive", isHistoryEntry: true)
        let image = FoilExposeItem(id: UUID(), controller: nil, isHistoryEntry: true,
                                  title: "Archive image", symbolName: "photo", contentKind: .image, thumbnailPath: nil)
        let model = makeModel(items: [open], historyItems: [duplicate, document, image])
        #expect(model.historyCategory == .all)
        #expect(model.historyCount(in: .all) == 2)
        model.historyCategory = .images
        #expect(model.currentItems.map(\.id) == [open.id, image.id])
        #expect(model.selectedIndex == 1)
        #expect(model.historyCount(in: .documents) == 1)
        model.searchText = "Archive"
        #expect(model.historyCount(in: .all) == 2)
        #expect(model.currentItems.map(\.id) == [image.id])
        model.historyCategory = .notes
        #expect(model.currentItems.isEmpty)
        #expect(model.showsHistorySection)
        #expect(model.historyCount(in: .images) == 1)
        model.resultFilter = .files
        #expect(!model.showsHistorySection)
    }

    @Test func favoritesFilterOnlyHistoryAndKeepsOpenFoils() {
        let open = makeItem(title: "Match open")
        let history = makeItem(title: "Match history", isHistoryEntry: true)
        var favorite = makeItem(title: "Match favorite", isHistoryEntry: true)
        favorite.historyIsPinned = true
        let model = makeModel(items: [open], historyItems: [history, favorite])

        model.pinnedOnly = true
        #expect(model.currentItems.map(\.id) == [open.id, favorite.id])
        #expect(model.historyCount(in: .all) == 1)
        model.searchText = "Match"
        #expect(model.currentItems.map(\.id) == [open.id, favorite.id])
        model.historyCategory = .images
        #expect(model.currentItems.map(\.id) == [open.id])
        model.historyCategory = .all
        model.pinnedOnly = false
        #expect(model.currentItems.map(\.id) == [open.id, history.id, favorite.id])
        #expect(model.historyCount(in: .all) == 2)
    }

    @Test func historyCountsPrecedeSearchLimitAndCategoryFiltering() {
        let documents = (0..<70).map { _ in makeItem(title: "Match", isHistoryEntry: true) }
        let image = FoilExposeItem(id: UUID(), controller: nil, isHistoryEntry: true,
                                  title: "Match image", symbolName: "photo", contentKind: .image, thumbnailPath: nil)
        let model = makeModel(items: [], historyItems: documents + [image])
        model.searchText = "Match"
        #expect(model.historyCount(in: .all) == 71)
        #expect(model.currentItems.count == 60)
        #expect(model.showsResultLimitNotice)
        model.historyCategory = .images
        #expect(model.currentItems.map(\.id) == [image.id])
        #expect(model.historyCount(in: .documents) == 70)
        #expect(!model.showsResultLimitNotice)
    }

    @Test func tabSwitchesBetweenFirstItemsOfOpenAndHistorySections() {
        let model = makeModel(openCount: 3, historyCount: 2)
        model.selectedIndex = 1
        model.switchFoilSection()
        #expect(model.selectedIndex == 3)
        model.selectedIndex = 4
        model.switchFoilSection()
        #expect(model.selectedIndex == 0)
        model.searchText = "no matching foil"
        model.switchFoilSection()
        #expect(model.selectedIndex == 0)
    }

    @Test func sectionSwitchKeepsSelectionWhenOtherSectionIsEmpty() {
        let openOnly = makeModel(openCount: 3, historyCount: 0)
        openOnly.selectedIndex = 1
        openOnly.switchFoilSection()
        #expect(openOnly.selectedIndex == 1)
        let historyOnly = makeModel(openCount: 0, historyCount: 2)
        historyOnly.selectedIndex = 1
        historyOnly.switchFoilSection()
        #expect(historyOnly.selectedIndex == 1)
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

    @Test func verticalSelectionAlignsLeftAcrossPartialSectionRows() {
        let model = makeModel(openCount: 6, historyCount: 2)
        model.columnCount = 4
        // 第一分区末行只有两项，下一分区从左侧重新排列。
        model.selectedIndex = 4
        model.moveSelection(.down)
        #expect(model.selectedIndex == 6)
        model.moveSelection(.up)
        #expect(model.selectedIndex == 4)
        model.selectedIndex = 5
        model.moveSelection(.down)
        #expect(model.selectedIndex == 7)
        model.moveSelection(.up)
        #expect(model.selectedIndex == 5)
        model.selectedIndex = 3
        model.moveSelection(.down)
        #expect(model.selectedIndex == 5)
        model.selectedIndex = 1
        model.moveSelection(.up)
        #expect(model.selectedIndex == 1)
        model.selectedIndex = 6
        model.moveSelection(.down)
        #expect(model.selectedIndex == 6)
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

    @Test func searchIsAlwaysActiveAndRefocusingKeepsResults() {
        let model = makeModel()
        #expect(model.isSearching)
        model.beginSearch()
        model.searchText = "item"
        model.requestSearchFieldFocus()
        #expect(model.isSearching)
        #expect(model.searchQuery == "item")
        #expect(model.currentItems.count == 8)
    }

    @Test func clearSearchRestoresFullList() {
        let model = makeModel()
        model.beginSearch()
        model.searchText = "不存在的关键字"
        #expect(model.currentItems.isEmpty)
        model.clearSearch()
        #expect(model.isSearching)
        #expect(model.searchQuery.isEmpty)
        #expect(model.currentItems.count == 8)
        #expect(model.selectedIndex == 0)
    }

    @Test func itemForKeyUsesFixedListOrderAcrossNavigationAndPaging() {
        let model = makeModel(openCount: 38)
        let items = model.currentItems
        model.selectedIndex = 20
        model.requestPageScroll(direction: .down)
        #expect(model.item(forKey: "1")?.id == items[0].id)
        #expect(model.item(forKey: "6")?.id == items[5].id)
        #expect(model.item(forKey: "0")?.id == items[9].id)
        #expect(model.item(forKey: "A")?.id == items[10].id)
        #expect(model.item(forKey: "a")?.id == items[10].id)
        #expect(model.item(forKey: "Z")?.id == items[35].id)
        #expect(model.item(forKey: "!") == nil)
        #expect(model.item(forKey: "") == nil)
    }

    @Test func itemForKeyMatchesHistoryEntriesInCombinedList() {
        let model = makeModel()
        #expect(model.item(forKey: "7")?.id == model.historyItems[0].id)
        #expect(model.item(forKey: "8")?.id == model.historyItems[1].id)
        #expect(model.item(forKey: "9") == nil)
    }

    @Test func fixedNumberingFollowsFilteredResults() {
        let open = makeItem(title: "Open")
        let history = makeItem(title: "History", isHistoryEntry: true)
        let model = makeModel(items: [open], historyItems: [history])
        #expect(model.item(forKey: "1")?.id == open.id)
        #expect(model.item(forKey: "2")?.id == history.id)
        model.searchText = "History"
        #expect(model.item(forKey: "1")?.id == history.id)
        #expect(model.item(forKey: "2") == nil)
    }

    @Test func bodyPreviewOnlyForDocumentKindsWithContent() {
        #expect(FoilExposeItem.makeBodyPreview(kind: .text, text: "hello") == "hello")
        // 首尾空白与空行跳过，预览从正文第一行开始。
        #expect(FoilExposeItem.makeBodyPreview(kind: .markdown, text: "\n\n  hello \n") == "hello")
        // 空白正文没有可展示的内容。
        #expect(FoilExposeItem.makeBodyPreview(kind: .note, text: "  \n\t ") == nil)
        // 非文档类型一律不给正文预览，卡片保持类型图标占位。
        #expect(FoilExposeItem.makeBodyPreview(kind: .image, text: "hello") == nil)
        #expect(FoilExposeItem.makeBodyPreview(kind: .pdf, text: "hello") == nil)
    }

    @Test func bodyPreviewTruncatesLongTextWithEllipsis() {
        let long = String(repeating: "字", count: FoilExposeItem.bodyPreviewCharacterLimit + 50)
        let preview = FoilExposeItem.makeBodyPreview(kind: .csv, text: long)
        #expect(preview?.count == FoilExposeItem.bodyPreviewCharacterLimit + 1)
        #expect(preview?.hasSuffix("…") == true)
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
            cancelFiles: { cancellations += 1 }, musicEnabled: { false }
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

    @Test func spotlightResultsParticipateInKeyboardNavigationAndOpening() async throws {
        var callback: ((SpotlightSearchOutcome) -> Void)?
        let model = FoilExposeModel(items: [makeItem(title: "Alpha")], historyItems: [],
                                    fileSearch: { _, value in callback = value }, cancelFiles: {}, musicEnabled: { false })
        model.columnCount = 4
        model.musicColumnCount = 2
        model.searchText = "alpha"
        try await eventually { callback != nil }
        callback?(.results((1...3).map { file("/docs/alpha-\($0).txt") }))
        let firstFile = model.currentItems.count
        model.moveSelection(.down)
        #expect(model.selectedIndex == firstFile)
        #expect(model.highlightedItem == nil)
        model.moveSelection(.right)
        #expect(model.selectedIndex == firstFile + 1)
        model.moveSelectionToRowStart()
        #expect(model.selectedIndex == firstFile)
        model.moveSelectionToRowEnd()
        #expect(model.selectedIndex == firstFile + 1)
        model.moveSelection(.down)
        #expect(model.selectedIndex == firstFile + 2)
        var opened: URL?
        model.onOpenFile = { opened = $0 }
        model.openHighlightedResult()
        #expect(opened == model.visibleFiles[2].url)
        model.moveSelection(.up)
        model.moveSelection(.up)
        #expect(model.selectedIndex == 0)
        callback = nil
        model.resultFilter = .files
        try await eventually { callback != nil }
        callback?(.results([file("/docs/alpha.txt"), file("/docs/alpha-next.txt")]))
        model.moveSelection(.right)
        #expect(model.selectedIndex == 1)
        #expect(model.currentItems.isEmpty)
    }

    @Test func lateFileResultsCannotOverwriteANewQuery() async throws {
        var callbacks: [String: (SpotlightSearchOutcome) -> Void] = [:]
        let model = FoilExposeModel(items: [], historyItems: [],
                                    fileSearch: { callbacks[$0] = $1 }, cancelFiles: {}, musicEnabled: { false })
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
                                    fileSearch: { _, value in callback = value }, cancelFiles: {}, musicEnabled: { false })
        model.searchText = "report"
        try await eventually { callback != nil }
        callback?(.results([file("/docs/report.txt"), file("/docs/report-old.txt", date: 5)]))
        #expect(model.files.map(\.name) == ["report-old.txt"])
    }

    @Test func fileStatusReportsMissingAuthorization() async throws {
        var callback: ((SpotlightSearchOutcome) -> Void)?
        let model = FoilExposeModel(items: [], historyItems: [],
                                    fileSearch: { _, value in callback = value }, cancelFiles: {}, musicEnabled: { false })
        model.searchText = "report"
        try await eventually { callback != nil }
        callback?(.disabled)
        #expect(model.fileStatus == .disabled)
        #expect(!model.isFileSearching)
        // 重新开启后重新查询并清掉旧状态。
        model.restartFileSearch()
        #expect(model.fileStatus == nil)
        #expect(model.isFileSearching)
    }
}
