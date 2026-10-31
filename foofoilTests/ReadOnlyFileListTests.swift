import AppKit
import Testing
import FoofoilExtensionKit
@testable import foofoil

@MainActor @Suite(.sharedApplicationState, .serialized)
struct ReadOnlyFileListTests {
    @Test func navigatorRejectsRemovalAndPreservesReordering() throws {
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        let items = ["a", "b", "c"].map { FileListItem(id: $0, path: "/tmp/\($0).png", displayName: $0) }
        state.fileList = .init(kind: .image, items: items, currentID: "a")
        state.syncFileListNavigator()
        let contribution = try #require(state.navigatorContributions.first)
        #expect(!contribution.allowedActions.contains(.remove))
        #expect(contribution.allowedActions.contains(.move))
        state.performNavigatorAction(.init(contributionID: contribution.id, kind: .remove, itemIDs: ["a"]))
        #expect(state.fileList?.items.map(\.id) == ["a", "b", "c"])
        state.performNavigatorAction(.init(contributionID: contribution.id, kind: .move, itemIDs: ["a"], destinationItemID: "c", movePosition: .after))
        #expect(state.fileList?.items.map(\.id) == ["b", "c", "a"])
        var accepted = true
        state.handleNavigatorDrop(providers: []) { accepted = $0 }
        #expect(!accepted)
    }

    @Test func fileMenuAndShortcutCatalogDoNotOfferAddingToLists() {
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let delegate = AppDelegate()
        defer { NotificationCenter.default.removeObserver(delegate) }
        delegate.setupMainMenu()
        func containsAdd(_ menu: NSMenu) -> Bool {
            menu.items.contains { item in
                (item.representedObject as? String) == "file.addToList"
                    || item.action.map(NSStringFromSelector) == "addToFileListAction"
                    || item.submenu.map(containsAdd) == true
            }
        }
        #expect(NSApp.mainMenu.map(containsAdd) == false)
        #expect(KeyboardShortcutCatalog.definition(withID: "file.addToList") == nil)
    }

    @Test func additionalFilesOpenSeparatelyAndKeepOriginalList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let data = try #require(image.tiffRepresentation)
        let urls = (0..<3).map { root.appendingPathComponent("\($0).tiff") }
        for url in urls { try data.write(to: url) }
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.installFileList(kind: .image, urls: Array(urls.prefix(2)), preservesIdentity: true)
        let original = state.fileList
        let delegate = AppDelegate()
        defer {
            NotificationCenter.default.removeObserver(delegate)
            for controller in delegate.windowControllers { controller.close() }
        }
        #expect(delegate.openGroupedFiles([urls[2]], into: state, append: true))
        #expect(state.fileList == original)
        #expect(delegate.windowControllers.count == 1)
        #expect(TestFileIdentity.equals(delegate.windowControllers.first?.appState.imageURL, urls[2]))
    }
}
