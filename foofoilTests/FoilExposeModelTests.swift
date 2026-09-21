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
        isHistoryEntry: Bool = false
    ) -> FoilExposeItem {
        FoilExposeItem(
            id: id,
            controller: nil,
            isHistoryEntry: isHistoryEntry,
            title: title,
            symbolName: "doc",
            contentKind: .text,
            thumbnailPath: nil
        )
    }

    private func makeModel(openCount: Int = 6, historyCount: Int = 2) -> FoilExposeModel {
        FoilExposeModel(
            items: (0..<openCount).map { _ in makeItem() },
            historyItems: (0..<historyCount).map { _ in makeItem(isHistoryEntry: true) }
        )
    }

    @Test func currentItemsCombineOpenFoilsBeforeHistory() {
        let model = makeModel()
        #expect(model.currentItems.count == 8)
        #expect(model.currentItems.prefix(6).allSatisfy { !$0.isHistoryEntry })
        #expect(model.currentItems.suffix(2).allSatisfy { $0.isHistoryEntry })
        #expect(model.historyStartIndex == 6)
    }

    @Test func historyEntriesAlreadyOpenAreNotShownTwice() {
        let openID = UUID()
        let model = FoilExposeModel(
            items: [makeItem(id: openID, title: "Open")],
            historyItems: [
                makeItem(id: openID, title: "Open", isHistoryEntry: true),
                makeItem(title: "Archive", isHistoryEntry: true)
            ]
        )
        #expect(model.currentItems.count == 2)
        #expect(model.currentItems.filter { $0.id == openID }.count == 1)
        #expect(model.historyStartIndex == 1)
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
        let model = FoilExposeModel(
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
        #expect(model.historyStartIndex == 0)
    }

    @Test func searchIsCaseAndWhitespaceInsensitive() {
        let model = FoilExposeModel(
            items: [makeItem(title: "Hello World")],
            historyItems: []
        )
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

    @Test func focusFirstHistoryEntryMovesHighlightToHistory() {
        let model = makeModel()
        #expect(model.focusFirstHistoryEntry())
        #expect(model.selectedIndex == 6)
        #expect(model.highlightedItem?.isHistoryEntry == true)
    }

    @Test func focusFirstHistoryEntryFailsWhenFilteredOut() {
        let model = FoilExposeModel(
            items: [makeItem(title: "Open")],
            historyItems: [makeItem(title: "Archive", isHistoryEntry: true)]
        )
        model.searchText = "open"
        #expect(model.focusFirstHistoryEntry() == false)
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
}
