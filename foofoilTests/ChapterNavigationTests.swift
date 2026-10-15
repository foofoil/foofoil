import AppKit
import Testing
import FoofoilExtensionKit
@testable import foofoil

@Suite(.sharedApplicationState)
struct ChapterNavigationTests {
    @Test @MainActor func chapterOrderSkipsSubsectionsAndStopsAtBoundaries() {
        let state = AppState(isIncognito: true)
        let url = URL(fileURLWithPath: "/tmp/chapter-navigation.html")
        state.extensionSession = ContentSession(
            extensionID: nil, providerID: "test.chapter-navigation",
            request: .singleFile(ExtensionResource(url: url)),
            presentation: .document(url: url),
            navigatorContributions: [NavigatorContribution(
                id: "contents", titleLocalizationKey: "Table of Contents", style: .outline,
                items: [NavigatorItem(id: "one", title: "One"),
                        NavigatorItem(id: "section", parentID: "one", title: "Section"),
                        NavigatorItem(id: "two", title: "Two")],
                selectedItemIDs: ["section"], readingOrderItemIDs: ["one", "two"],
                currentReadingOrderItemID: "one"
            )]
        )
        #expect(state.adjacentChapterID(delta: -1) == nil)
        #expect(state.adjacentChapterID(delta: 1) == "two")
        state.extensionSession?.navigatorContributions[0].currentReadingOrderItemID = "two"
        #expect(state.adjacentChapterID(delta: -1) == "one")
        #expect(state.adjacentChapterID(delta: 1) == nil)
        state.extensionSession = nil
    }

    @Test @MainActor func chapterMenuUsesConfiguredBindingsOnlyForDocuments() throws {
        let store = KeyboardShortcutStore.shared
        let definition = try #require(KeyboardShortcutCatalog.definition(withID: "go.nextChapter"))
        let original = store.shortcut(for: definition)
        let customized = store.isCustomized(definition)
        defer {
            if customized { store.setShortcut(original, for: definition) }
            else { store.reset(definition) }
        }
        let menu = NSMenu()
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.tag = GoMenuItemTag.chapterNext
        menu.addItem(item)
        store.setShortcut(KeyboardShortcut(keyEquivalent: "j", modifiers: [.command]), for: definition)
        AppDelegate.syncGoMenuKeyEquivalents(in: menu, isPDFDocument: false, hasFileList: false, hasChapters: true)
        #expect(item.keyEquivalent == "j")
        #expect(item.keyEquivalentModifierMask == .command)
        AppDelegate.syncGoMenuKeyEquivalents(in: menu, isPDFDocument: true, hasFileList: false)
        #expect(item.keyEquivalent.isEmpty)
        store.setShortcut(nil, for: definition)
        AppDelegate.syncGoMenuKeyEquivalents(in: menu, isPDFDocument: false, hasFileList: false, hasChapters: true)
        #expect(item.keyEquivalent.isEmpty)
    }
}
