//
//  NavigatorSearchTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/13.
//

import AppKit
import FoofoilExtensionKit
import Foundation
import Testing
@testable import foofoil

@MainActor
@Suite(.serialized)
struct NavigatorSearchTests {
    private func contribution(
        titles: [String],
        style: NavigatorPresentationStyle = .flat,
        items: [NavigatorItem]? = nil
    ) -> NavigatorContribution {
        let rows = items ?? titles.enumerated().map { index, title in
            NavigatorItem(id: "item-\(index)", title: title, symbolName: "music.note")
        }
        return NavigatorContribution(
            id: AppState.fileListNavigatorID,
            titleLocalizationKey: "Audio List",
            style: style,
            items: rows
        )
    }

    private func makeState(titles: [String]) -> AppState {
        let state = AppState()
        state.builtInNavigatorContributions = [contribution(titles: titles)]
        return state
    }

    private func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ))
    }

    @Test func searchRequiresMoreThanTwelveItems() {
        let twelve = makeState(titles: (0..<12).map { "Track \($0)" })
        #expect(!twelve.canSearchActiveNavigator)
        twelve.beginNavigatorSearch()
        #expect(!twelve.isNavigatorSearchActive)

        let thirteen = makeState(titles: (0..<13).map { "Track \($0)" })
        #expect(thirteen.canSearchActiveNavigator)
        thirteen.beginNavigatorSearch()
        #expect(thirteen.isNavigatorSearchActive)
    }

    @Test func matchesIgnoreCaseAndDiacriticsInDisplayOrder() {
        let titles = ["Alpha", "álbum", "beta", "ALPINE"]
            + (4..<16).map { "Track \($0)" }
        let state = makeState(titles: titles)
        state.beginNavigatorSearch()
        state.navigatorSearchQuery = "al"
        #expect(state.navigatorSearchMatchIDs() == ["item-0", "item-1", "item-3"])
    }

    @Test func nextAndPreviousCycleThroughMatches() {
        let state = makeState(titles: (0..<13).map { "Track \($0)" })
        state.beginNavigatorSearch()
        state.navigatorSearchQuery = "track"

        state.advanceNavigatorSearchMatch(delta: 1)
        #expect(state.navigatorSearchCurrentMatchID == "item-0")
        state.advanceNavigatorSearchMatch(delta: 1)
        #expect(state.navigatorSearchCurrentMatchID == "item-1")
        state.advanceNavigatorSearchMatch(delta: -1)
        #expect(state.navigatorSearchCurrentMatchID == "item-0")
        state.advanceNavigatorSearchMatch(delta: -1)
        #expect(state.navigatorSearchCurrentMatchID == "item-12")
    }

    @Test func noMatchesClearSelection() {
        let state = makeState(titles: (0..<13).map { "Track \($0)" })
        state.beginNavigatorSearch()
        state.navigatorSearchQuery = "missing"
        #expect(state.navigatorSearchMatchIDs().isEmpty)
        state.navigatorSearchCurrentMatchID = "item-0"
        state.advanceNavigatorSearchMatch(delta: 1)
        #expect(state.navigatorSearchCurrentMatchID == nil)
    }

    @Test func matchingChildExpandsCollapsedSectionBeforeLocating() {
        let items = [
            NavigatorItem(id: "section", title: "Album"),
            NavigatorItem(id: "track-1", parentID: "section", title: "Song A"),
            NavigatorItem(id: "track-2", parentID: "section", title: "Song B")
        ]
        let state = AppState()
        state.builtInNavigatorContributions = [
            contribution(titles: [], style: .outline, items: items)
        ]
        state.isNavigatorSearchActive = true
        state.navigatorSearchQuery = "song b"
        state.advanceNavigatorSearchMatch(delta: 1)
        #expect(state.navigatorSearchCurrentMatchID == "track-2")
        #expect(state.expandedNavigatorItemIDs.contains("section"))
    }

    /// 专辑/分段目录行本身可被查找命中，回车展开/收起目录。
    @Test func directoryRowsAreSearchableAndOpenTogglesExpansion() {
        let items = [
            NavigatorItem(id: "album-a", title: "Album A"),
            NavigatorItem(id: "album-a-track", parentID: "album-a", title: "Song One"),
            NavigatorItem(id: "album-b", title: "Album B"),
            NavigatorItem(id: "album-b-track", parentID: "album-b", title: "Song Two")
        ]
        let state = AppState()
        state.builtInNavigatorContributions = [
            contribution(titles: [], style: .outline, items: items)
        ]
        state.isNavigatorSearchActive = true
        state.navigatorSearchQuery = "album"
        #expect(state.navigatorSearchMatchIDs() == ["album-a", "album-b"])

        state.openNavigatorSearchMatch()
        #expect(state.navigatorSearchCurrentMatchID == "album-a")
        #expect(state.expandedNavigatorItemIDs.contains("album-a"))

        state.openNavigatorSearchMatch()
        #expect(!state.expandedNavigatorItemIDs.contains("album-a"))
    }

    /// 回车打开定位到的曲目/文件，走贡献的激活行为。
    @Test func enterActivateLeafMatchThroughContributionAction() {
        let state = makeState(titles: (0..<13).map { "Track \($0)" })
        var activated: NavigatorAction?
        state.builtInNavigatorActionHandler = { activated = $0 }
        state.isNavigatorSearchActive = true
        state.navigatorSearchQuery = "track"
        state.openNavigatorSearchMatch()
        #expect(state.navigatorSearchCurrentMatchID == "item-0")
        #expect(activated?.kind == .activate)
        #expect(activated?.itemIDs == ["item-0"])
    }

    @Test func queryChangeClearsCurrentMatch() {
        let state = makeState(titles: (0..<13).map { "Track \($0)" })
        state.beginNavigatorSearch()
        state.navigatorSearchQuery = "track"
        state.advanceNavigatorSearchMatch(delta: 1)
        #expect(state.navigatorSearchCurrentMatchID == "item-0")
        state.navigatorSearchQueryDidChange()
        #expect(state.navigatorSearchCurrentMatchID == nil)
    }

    @Test func endSearchClearsQueryAndSelection() {
        let state = makeState(titles: (0..<13).map { "Track \($0)" })
        state.beginNavigatorSearch()
        state.navigatorSearchQuery = "track"
        state.advanceNavigatorSearchMatch(delta: 1)
        state.endNavigatorSearch()
        #expect(!state.isNavigatorSearchActive)
        #expect(state.navigatorSearchQuery.isEmpty)
        #expect(state.navigatorSearchCurrentMatchID == nil)
    }

    @Test func commandShortcutsEnterAndCycleMatches() throws {
        let state = makeState(titles: (0..<13).map { "Track \($0)" })
        #expect(state.handleNavigatorSearchKey(try keyEvent("f", modifiers: .command)))
        #expect(state.isNavigatorSearchActive)

        state.navigatorSearchQuery = "track"
        #expect(state.handleNavigatorSearchKey(try keyEvent("g", modifiers: .command)))
        #expect(state.navigatorSearchCurrentMatchID == "item-0")
        #expect(state.handleNavigatorSearchKey(try keyEvent("g", modifiers: [.command, .shift])))
        #expect(state.navigatorSearchCurrentMatchID == "item-12")
    }

    @Test func commandShortcutIsRejectedWithoutSearchableList() throws {
        let state = makeState(titles: (0..<12).map { "Track \($0)" })
        #expect(!state.handleNavigatorSearchKey(try keyEvent("f", modifiers: .command)))
        #expect(!state.isNavigatorSearchActive)
    }
}
