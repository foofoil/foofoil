import AppKit
import Testing
@testable import foofoil

@MainActor
struct FoilExposeViewTests {
    private func model(clipboardContent: ClipboardOpenableContent? = nil) -> FoilExposeModel {
        let history = FoilExposeItem(id: UUID(), controller: nil, isHistoryEntry: true, title: "Native note",
                                     symbolName: "note.text", contentKind: .note, thumbnailPath: nil, hasHistoryRecord: true)
        return FoilExposeModel(items: [], historyItems: [history], clipboardContent: clipboardContent, fileSearch: { _, _ in },
                               cancelFiles: {}, cameraAvailable: { false }, musicEnabled: { false })
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @Test func overviewPanelUsesNativeRendererAndKeepsScreenSize() throws {
        let screen = try #require(NSScreen.main)
        let panel = FoilExposeController.makePanel(for: screen, model: model())
        defer { panel.close() }
        #expect(panel.frame.size == screen.frame.size)
        #expect(panel.contentView?.frame.size == screen.frame.size)
        #expect(panel.contentViewController is FoilExposeViewController)
        #expect(!descendants(try #require(panel.contentView)).contains { String(describing: type(of: $0)).contains("Hosting") })
    }

    @Test func overviewHasAnEntirelyNativeViewTree() {
        let controller = FoilExposeViewController(model: model())
        controller.view.frame = NSRect(x: 0, y: 0, width: 1240, height: 900)
        controller.synchronize()
        let views = descendants(controller.view)
        #expect(!views.contains { String(describing: type(of: $0)).contains("Hosting") })
        #expect(views.contains { $0 is NSCollectionView })
        #expect(controller.searchField.delegate === controller)
        #expect(controller.searchField.frame.width > 0)
    }

    @Test func clipboardAndSearchAlignWithTheirContainers() throws {
        let controller = FoilExposeViewController(model: model(clipboardContent: .init(.image)))
        controller.view.frame = NSRect(x: 0, y: 0, width: 1240, height: 900)
        controller.synchronize()
        let clipboard = try #require(descendants(controller.view).first { $0.accessibilityIdentifier() == "expose.clipboard" })
        #expect(abs(clipboard.frame.maxX - 1196) < 0.5)
        let field = controller.searchField
        #expect(abs(field.frame.midY - 16) < 0.5)
        #expect(field.frame.minX >= 31)
    }

    @Test func historyFiltersStayInTheirHeaderAndCountsHaveCapsules() throws {
        let controller = FoilExposeViewController(model: model())
        controller.view.frame = NSRect(x: 0, y: 0, width: 1240, height: 900)
        controller.synchronize()
        controller.view.layoutSubtreeIfNeeded()
        let views = descendants(controller.view)
        let header = try #require(views.first { $0.accessibilityIdentifier() == "expose.section.history" })
        let filters = try #require(views.first { $0.accessibilityIdentifier() == "expose.historyFilters" })
        #expect(filters.superview === header)
        #expect(abs(filters.frame.midY - header.bounds.midY) < 0.5)
        #expect(abs(filters.frame.maxX - (header.bounds.width - 44)) < 0.5)
        let count = try #require(header.subviews.first { $0.accessibilityIdentifier() == "expose.section.count" })
        #expect((count.layer?.cornerRadius ?? 0) > 0)
        #expect(count.layer?.backgroundColor != nil)
        #expect(header.subviews.compactMap { $0 as? NSImageView }.contains { $0.image != nil })
        // 窄窗口只缩短筛选滚动区，仍与标题同一行且不越过网格右边缘。
        controller.view.frame.size.width = 600
        controller.synchronize()
        controller.view.layoutSubtreeIfNeeded()
        #expect(filters.frame.width > 0)
        #expect(abs(filters.frame.maxX - (header.bounds.width - 44)) < 0.5)
    }

    @Test func nativeSearchAndScopeSelectionStaySynchronized() {
        let model = model()
        let controller = FoilExposeViewController(model: model)
        _ = controller.view
        controller.searchField.stringValue = "Native"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.searchField))
        #expect(model.searchText == "Native")
        model.searchText = "/"
        controller.synchronize()
        #expect(controller.searchField.stringValue == "/")
        #expect(model.isPickingScope)
        model.selectScope(.history)
        controller.synchronize()
        #expect(controller.searchField.stringValue.isEmpty)
        #expect(model.activeScope == .history)
        #expect(controller.searchField.placeholderString?.contains(model.activeScope!.displayName) == true)
    }

    @Test func scopeInputPreservesResultsUntilSelection() {
        let model = model()
        let originalIDs = model.currentItems.map(\.id)
        for input in ["/", "/history", "/no-such-category"] {
            model.searchText = input
            #expect(model.isPickingScope)
            #expect(model.searchQuery.isEmpty)
            #expect(model.currentItems.map(\.id) == originalIDs)
            #expect(model.showsHistorySection)
        }
        model.searchText = "Native"
        model.searchText = "/no-such-category"
        #expect(model.searchQuery == "Native")
        #expect(model.currentItems.map(\.id) == originalIDs)
        model.selectScope(.history)
        #expect(model.searchQuery.isEmpty)
        #expect(!model.isPickingScope)
    }

    @Test func unmatchedScopeShowsDropdownNotice() throws {
        let model = model()
        let controller = FoilExposeViewController(model: model)
        _ = controller.view
        model.searchText = "/no-such-category"
        controller.synchronize()
        let notice = try #require(descendants(controller.view).first {
            $0.accessibilityIdentifier() == "expose.scope.noMatches"
        } as? NSTextField)
        #expect(!notice.isHiddenOrHasHiddenAncestor)
        #expect(notice.stringValue == NSLocalizedString("No Matching Scopes", comment: ""))
    }

    @Test func nativeCategoryAndFavoriteButtonsUseSharedModel() throws {
        let model = model()
        let controller = FoilExposeViewController(model: model)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1240, height: 900)
        controller.synchronize()
        let buttons = descendants(controller.view).compactMap { $0 as? NSButton }
        let notes = try #require(buttons.first { $0.accessibilityIdentifier() == "expose.category.notes" })
        notes.performClick(nil)
        #expect(model.historyCategory == .notes)
        let favorite = try #require(buttons.first { $0.accessibilityIdentifier() == "expose.favorites" })
        favorite.performClick(nil)
        #expect(model.pinnedOnly)
        #expect(model.currentItems.isEmpty)
    }

    @Test func historyContextMenuShowsIconsShortcutsAndStandardDeletion() throws {
        let model = model()
        let grid = FoilExposeGrid(model: model)
        grid.frame = NSRect(x: 0, y: 0, width: 1240, height: 900)
        grid.update(model: model)
        let collection = try #require(grid.documentView as? NSCollectionView)
        collection.layoutSubtreeIfNeeded()
        let card = try #require(collection.item(at: IndexPath(item: 0, section: 0)))
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(card.view.menu(for: event))
        let favorite = try #require(menu.items.first { $0.title == NSLocalizedString("Favorite History", comment: "") })
        #expect(favorite.keyEquivalent == KeyboardShortcutStore.shared.shortcut(forID: "history.toggleFavorite")?.keyEquivalent)
        let rename = try #require(menu.items.first { $0.title == NSLocalizedString("Change Title", comment: "") })
        #expect(rename.keyEquivalent == "e")
        #expect(rename.keyEquivalentModifierMask == .command)
        let info = try #require(menu.items.first { $0.title == NSLocalizedString("Foil Information Menu", comment: "") })
        #expect(info.keyEquivalent == "i")
        let delete = try #require(menu.items.first { $0.title == NSLocalizedString("Delete History Record", comment: "") })
        #expect(delete.keyEquivalent == "\u{8}")
        #expect(delete.keyEquivalentModifierMask.isEmpty)
        #expect(delete.attributedTitle == nil)
        for item in [favorite, rename, info, delete] {
            #expect(item.image != nil)
            if #available(macOS 27.0, *) { #expect(item.preferredImageVisibility == .visible) }
        }
    }

    @Test func selectionUpdatesKeepNativeCollectionItemsAlive() throws {
        let model = model()
        let grid = FoilExposeGrid(model: model)
        grid.frame = NSRect(x: 0, y: 0, width: 1240, height: 900)
        grid.update(model: model)
        let collection = try #require(grid.documentView as? NSCollectionView)
        collection.layoutSubtreeIfNeeded()
        let before = try #require(collection.item(at: IndexPath(item: 0, section: 0)))
        before.view.layoutSubtreeIfNeeded()
        let title = try #require(before.view.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Native note" })
        #expect(title.frame.width >= before.view.bounds.width - 20)
        model.selectedIndex = 1
        grid.update(model: model)
        #expect(collection.item(at: IndexPath(item: 0, section: 0)) === before)
        #expect(model.columnCount == 5)
    }
}
