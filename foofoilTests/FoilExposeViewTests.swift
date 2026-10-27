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

    @Test func clipboardCopyControlReceivesItsOwnClicks() async throws {
        let entry = ClipboardSearchEntry(id: "fixture", title: "A long clipboard title\nsecond line",
                                         searchText: "Searchable body", content: .text("Searchable body"), date: Date())
        let search = ClipboardHistorySearch(load: { .init(access: .available, entries: [entry]) }, currentContent: { nil })
        let model = FoilExposeModel(items: [], historyItems: [], fileSearch: { _, _ in },
                                    cancelFiles: {}, cameraAvailable: { false }, musicEnabled: { false }, clipboardSearch: search)
        defer { model.stopFileSearch() }
        model.selectScope(.clipboard)
        for _ in 0..<100 {
            if !search.isLoading && model.currentItems.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.currentItems.count == 1)
        #expect(model.currentItems.first?.isNewFoil == false)
        let controller = FoilExposeViewController(model: model)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        controller.synchronize()
        let collection = try #require(descendants(controller.view).compactMap { $0 as? NSCollectionView }.first)
        let dataSource = try #require(collection.dataSource)
        // 显式请求卡片，避免离屏 NSCollectionView 尚未实例化可见项。
        let cell = dataSource.collectionView(collection, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
        cell.view.frame = NSRect(x: 0, y: 0, width: 400, height: 58)
        cell.view.layoutSubtreeIfNeeded()
        let copy = try #require(descendants(cell.view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == NSLocalizedString("Clipboard History Copy", comment: "") })
        #expect(!copy.isHidden && copy.isEnabled)
        let card = try #require(copy.superview)
        let artwork = try #require(descendants(card).compactMap { $0 as? ClipboardEntryArtworkView }.first)
        #expect(!artwork.isHidden && artwork.frame.size == NSSize(width: 44, height: 44))
        #expect(card.hitTest(card.convert(NSPoint(x: copy.frame.midX, y: copy.frame.midY), to: card.superview)) === copy)
        let titles = descendants(card).compactMap { $0 as? NSTextField }.filter { $0.stringValue == entry.title }
        #expect(titles.count == 1 && titles.first?.maximumNumberOfLines == 1)
    }

    @Test func overviewPanelUsesNativeRendererAndKeepsScreenSize() throws {
        let screen = try #require(NSScreen.main)
        let panel = FoilExposeController.makePanel(for: screen, model: model())
        defer { panel.close() }
        #expect(panel.frame.size == screen.frame.size)
        #expect(panel.contentView?.frame.size == screen.frame.size)
        #expect(panel.contentViewController is FoilExposeViewController)
        #expect(!descendants(try #require(panel.contentView)).contains { String(describing: type(of: $0)).contains("Hosting") && !($0 is QuickOpenPromptHostingView) })
    }

    @Test func overviewKeepsResultsNativeWithTheSharedSearchPrompt() {
        let controller = FoilExposeViewController(model: model())
        controller.view.frame = NSRect(x: 0, y: 0, width: 1240, height: 900)
        controller.synchronize()
        let views = descendants(controller.view)
        #expect(!views.contains { String(describing: type(of: $0)).contains("Hosting") && !($0 is QuickOpenPromptHostingView) })
        #expect(views.contains { $0 is NSCollectionView })
        #expect(controller.searchField.delegate === controller)
        #expect(controller.searchField.frame.width > 0)
    }

    @Test func clipboardAndSearchAlignWithTheirContainers() throws {
        let controller = FoilExposeViewController(model: model(clipboardContent: .init(.image)))
        controller.view.frame = NSRect(x: 0, y: 0, width: 1240, height: 900)
        controller.synchronize()
        let clipboard = try #require(descendants(controller.view).first { $0.accessibilityIdentifier() == "expose.clipboard" })
        #expect(abs(clipboard.frame.maxX - 1120) < 0.5)
        let search = try #require(controller.searchField.superview)
        #expect(search.frame.midY == clipboard.frame.midY)
        #expect(search.frame.maxX < clipboard.frame.minX)
        for width in [420.0, 600.0, 1240.0] {
            controller.view.frame.size.width = width
            controller.model.isOptionPressed.toggle()
            controller.synchronize()
            #expect(clipboard.frame.maxX <= width - 20)
            #expect(search.frame.maxX < clipboard.frame.minX)
            #expect(search.frame.width > 0)
        }
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
        #expect(delete.keyEquivalentModifierMask == .command)
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

    @Test func partiallyVisibleSelectionScrollsFullyIntoView() throws {
        let items = (0..<12).map { index in
            FoilExposeItem(id: UUID(), controller: nil, isHistoryEntry: false, title: "Open \(index)",
                           symbolName: "doc", contentKind: .text, thumbnailPath: nil)
        }
        let model = FoilExposeModel(items: items, historyItems: [], fileSearch: { _, _ in },
                                    cancelFiles: {}, cameraAvailable: { false }, musicEnabled: { false })
        let grid = FoilExposeGrid(model: model)
        grid.frame = NSRect(x: 0, y: 0, width: 1240, height: 420)
        grid.update(model: model)
        let collection = try #require(grid.documentView as? NSCollectionView)
        // 无窗口的测试宿主不会触发 AppKit 的文档尺寸更新，手动同步为布局内容高度。
        func layoutContent() {
            collection.layoutSubtreeIfNeeded()
            collection.frame = NSRect(origin: .zero,
                                      size: collection.collectionViewLayout?.collectionViewContentSize ?? .zero)
            grid.reflectScrolledClipView(grid.contentView)
        }
        layoutContent()
        let first = try #require(collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let last = try #require(collection.layoutAttributesForItem(at: IndexPath(item: 10, section: 0)))

        // 顶部只露出卡片底部 20pt：向上导航时也要滚到完整可见。
        model.selectedIndex = 1
        grid.update(model: model)
        layoutContent()
        grid.contentView.scroll(to: NSPoint(x: 0, y: first.frame.maxY - 20))
        grid.reflectScrolledClipView(grid.contentView)
        #expect(!grid.documentVisibleRect.contains(first.frame))
        model.selectedIndex = 0
        grid.update(model: model)
        layoutContent()
        #expect(grid.documentVisibleRect.contains(first.frame))

        // 底部只露出卡片顶部 20pt：同样滚到完整可见。
        model.selectedIndex = 9
        grid.update(model: model)
        layoutContent()
        grid.contentView.scroll(to: NSPoint(x: 0, y: last.frame.minY - (grid.contentSize.height - 20)))
        grid.reflectScrolledClipView(grid.contentView)
        #expect(!grid.documentVisibleRect.contains(last.frame))
        model.selectedIndex = 10
        grid.update(model: model)
        layoutContent()
        #expect(grid.documentVisibleRect.contains(last.frame))

        // 高亮已在第一项但卡片被滚出视口时，继续按上键（高亮不移动）也要滚回完整可见。
        model.selectedIndex = 0
        grid.update(model: model)
        layoutContent()
        grid.contentView.scroll(to: NSPoint(x: 0, y: first.frame.maxY - 20))
        grid.reflectScrolledClipView(grid.contentView)
        #expect(!grid.documentVisibleRect.contains(first.frame))
        model.moveSelection(.up)
        #expect(model.selectedIndex == 0)
        grid.update(model: model)
        layoutContent()
        #expect(grid.documentVisibleRect.contains(first.frame))
    }

    @Test func overviewDropsHeadingAndWidensSearchField() {
        let controller = FoilExposeViewController(model: model())
        controller.view.frame = NSRect(x: 0, y: 0, width: 1240, height: 900)
        controller.synchronize()
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.searchField.frame.width > 600)
        let displayName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        if let displayName {
            #expect(!descendants(controller.view).compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == displayName })
        }
    }

    @Test func directPathAndURLActionsUseTheScopeDropdown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("expose-direct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Long Report 2026.pdf")
        try Data("path".utf8).write(to: file)

        let model = model()
        let controller = FoilExposeViewController(model: model)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1240, height: 900)
        controller.synchronize()

        var openedFile: URL?
        model.onOpenFile = { openedFile = $0 }
        model.searchText = "\"\(file.path)\""
        controller.synchronize()
        let fileButton = try #require(descendants(controller.view).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "expose.scope.openFile"
        })
        #expect(fileButton.title == String(
            format: NSLocalizedString("Open File Search Result Format", comment: ""),
            file.lastPathComponent
        ))
        #expect(!fileButton.isHiddenOrHasHiddenAncestor)
        fileButton.performClick(nil)
        #expect(openedFile?.path == file.path)

        var openedURL: URL?
        model.onOpenURL = { openedURL = $0 }
        model.searchText = "example.com"
        controller.synchronize()
        let urlButton = try #require(descendants(controller.view).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "expose.scope.openURL"
        })
        #expect(urlButton.title == String(
            format: NSLocalizedString("Open URL Search Result Format", comment: ""),
            "https://example.com"
        ))
        urlButton.performClick(nil)
        #expect(openedURL?.absoluteString == "https://example.com")
        model.stopFileSearch()
    }
}
