//
//  FoilExposeModelTests.swift
//  foofoil
//
//  Created by tolg on 2026/9/15.
//

import Foundation
import AppKit
import Testing
@testable import foofoil

@MainActor
struct FoilExposeModelTests {
    private let screen = NSScreen()

    private func makeItem(id: UUID) -> FoilExposeItem {
        FoilExposeItem(
            id: id,
            controller: nil,
            isHistoryEntry: false,
            screen: screen,
            title: "item",
            symbolName: "doc",
            contentKind: .text,
            thumbnailPath: nil
        )
    }

    private func makeModel(openCount: Int = 6, historyCount: Int = 2) -> FoilExposeModel {
        FoilExposeModel(
            items: (0..<openCount).map { _ in makeItem(id: UUID()) },
            historyItems: (0..<historyCount).map { _ in makeItem(id: UUID()) }
        )
    }

    @Test func moveSelectionClampsToBoundaries() {
        let model = makeModel()
        model.moveSelection(.left)
        #expect(model.selectedIndex == 0)
        model.selectedIndex = model.items.count - 1
        model.moveSelection(.right)
        #expect(model.selectedIndex == model.items.count - 1)
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
        let model = makeModel()
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

    @Test func switchTabResetsHighlightAndSwapsItems() {
        let model = makeModel()
        model.selectedIndex = 3
        model.switchTab(to: .history)
        #expect(model.selectedIndex == 0)
        #expect(model.currentItems.count == 2)
        #expect(model.highlightedItem?.id == model.historyItems[0].id)
        model.switchTab(to: .openFoils)
        #expect(model.currentItems.count == 6)
    }

    @Test func cycleTabWrapsAroundBothDirections() {
        let model = makeModel()
        model.cycleTab(backward: false)
        #expect(model.selectedTab == .history)
        model.cycleTab(backward: false)
        #expect(model.selectedTab == .openFoils)
        model.cycleTab(backward: true)
        #expect(model.selectedTab == .history)
    }

    @Test func itemForKeyOnlyMatchesVisibleEntries() {
        let model = makeModel()
        let first = model.items[0].id
        let second = model.items[1].id
        let hidden = model.items[5].id
        model.setVisibleIDs([first, second], for: screen)

        #expect(model.item(forKey: "1", preferredScreen: screen)?.id == first)
        #expect(model.item(forKey: "2", preferredScreen: screen)?.id == second)
        // 不可见项没有编号，直选不命中。
        #expect(model.item(forKey: "6", preferredScreen: screen) == nil)
        // 大小写不敏感：字母编号转大写后匹配。
        model.setVisibleIDs([hidden], for: screen)
        #expect(model.item(forKey: "1", preferredScreen: screen)?.id == hidden)
    }
}
