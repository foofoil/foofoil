//
//  FoilExposeShortcutTests.swift
//  foofoil
//
//  Created by tolg on 2026/9/14.
//

import AppKit
import Testing
@testable import foofoil

@Suite(.sharedApplicationState)
struct FoilExposeShortcutTests {
    @Test @MainActor func controlNavigationMovesHighlightBeforeLetterSelection() throws {
        let controller = FoilExposeController.shared
        let previousModel = controller.model
        let items = (0..<35).map { index in
            FoilExposeItem(id: UUID(), controller: nil, isHistoryEntry: false,
                           title: "Match \(index)", symbolName: "doc", contentKind: .text, thumbnailPath: nil)
        }
        let model = FoilExposeModel(items: items, historyItems: [], fileSearch: { _, _ in }, cancelFiles: {}, musicEnabled: { false })
        controller.model = model
        defer { controller.model = previousModel }
        model.searchText = "Match"
        model.columnCount = 4
        var activated = false
        model.onSelect = { _ in activated = true }
        for (key, index) in [("n", 4), ("f", 5), ("p", 1), ("b", 0), ("p", 0), ("b", 0)] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                                                    timestamp: 0, windowNumber: 0, context: nil,
                                                    characters: key, charactersIgnoringModifiers: key,
                                                    isARepeat: false, keyCode: 0))
            #expect(controller.handleKeyEvent(event) == nil)
            #expect(model.selectedIndex == index)
            #expect(model.searchText == "Match")
            #expect(controller.model === model)
            #expect(!activated)
        }
    }

    @Test @MainActor func overviewFavoriteFilterFollowsConfiguredShortcut() throws {
        let store = KeyboardShortcutStore.shared
        let definition = try #require(KeyboardShortcutCatalog.definition(withID: "history.toggleFavorite"))
        let previous = store.shortcut(for: definition)
        let customized = store.isCustomized(definition)
        let controller = FoilExposeController.shared
        let previousModel = controller.model
        let model = FoilExposeModel(items: [], historyItems: [], fileSearch: { _, _ in }, cancelFiles: {}, musicEnabled: { false })
        controller.model = model
        defer {
            controller.model = previousModel
            if customized { store.setShortcut(previous, for: definition) }
            else { store.reset(definition) }
        }
        func event(_ key: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         characters: key, charactersIgnoringModifiers: key,
                                         isARepeat: false, keyCode: 0))
        }
        store.reset(definition)
        #expect(controller.handleKeyEvent(try event("d", modifiers: .command)) == nil)
        #expect(model.pinnedOnly)
        #expect(controller.handleKeyEvent(try event("d", modifiers: .command)) == nil)
        #expect(!model.pinnedOnly)

        store.setShortcut(KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .option]), for: definition)
        #expect(controller.handleKeyEvent(try event("d", modifiers: .command)) != nil)
        #expect(!model.pinnedOnly)
        #expect(controller.handleKeyEvent(try event("j", modifiers: [.command, .option])) == nil)
        #expect(model.pinnedOnly)
        store.setShortcut(nil, for: definition)
        #expect(controller.handleKeyEvent(try event("j", modifiers: [.command, .option])) != nil)
        #expect(model.pinnedOnly)
    }

    @Test @MainActor func helpDocumentsReuseTheirOpenFoilsAndRefreshContent() throws {
        let delegate = AppDelegate()
        defer {
            for controller in delegate.windowControllers {
                HistoryManager.shared.removeFromHistory(controller.appState.toConfig())
                controller.close()
            }
        }
        delegate.showKeyboardShortcutsOverviewAction()
        let shortcuts = try #require(delegate.windowControllers.first)
        let shortcutsID = shortcuts.appState.id
        delegate.showSupportedContentOverviewAction()
        let content = try #require(delegate.windowControllers.last)
        let contentID = content.appState.id
        #expect(shortcuts !== content)
        #expect(delegate.windowControllers.count == 2)
        shortcuts.appState.text = "Outdated shortcuts"
        shortcuts.hideFoil()
        delegate.showKeyboardShortcutsOverviewAction()
        #expect(delegate.windowControllers.count == 2)
        #expect(shortcuts.appState.id == shortcutsID)
        #expect(shortcuts.appState.text == KeyboardShortcutsOverview.markdown())
        #expect(shortcuts.window?.isVisible == true)
        content.appState.text = "Outdated content"
        content.hideFoil()
        delegate.showSupportedContentOverviewAction()
        #expect(delegate.windowControllers.count == 2)
        #expect(content.appState.id == contentID)
        #expect(content.appState.text == SupportedContentOverview.markdown())
        #expect(content.window?.isVisible == true)
    }

    @Test @MainActor func supportedContentShowsCurrentOpeningShortcuts() {
        let custom = KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .option])
        let text = SupportedContentOverview.markdown { definition in
            definition.id == "file.openClipboardContent" ? custom : definition.defaultShortcut
        }
        #expect(text.contains("⌘L"))
        #expect(text.components(separatedBy: "⌥⌘J").count == 4)
        #expect(!text.contains("{{"))
        let disabled = SupportedContentOverview.markdown { _ in nil }
        #expect(!disabled.contains("⌘L"))
        #expect(!disabled.contains("⌥⌘J"))
        #expect(!disabled.contains("()"))
        #expect(!disabled.contains("（）"))
        #expect(!disabled.contains("{{"))
        let camera = SupportedContentOverview.markdown { definition in
            definition.id == "file.openCamera" ? custom : nil
        }
        #expect(camera.components(separatedBy: "⌥⌘J").count == 2)
    }

    @Test @MainActor func supportedContentOverviewRestoresLatestDocument() {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.openSupportedContentOverview()
        var config = state.toConfig()
        #expect(HistoryManager.shared.historyConfigs.contains { $0.id == config.id })
        #expect(config.sourceFingerprint == SupportedContentOverview.sourceFingerprint)
        #expect(state.isMarkdownPreview)
        #expect(state.text.contains(".epub"))
        #expect(state.text.contains(".swift"))
        #expect(!state.text.contains("{{"))
        config.originalImageName = "Old title.md"
        config.text = "Outdated document"
        let restored = AppState(config: config)
        #expect(restored.originalImageName == NSLocalizedString("Supported Content Overview", comment: "") + ".md")
        #expect(restored.text == SupportedContentOverview.markdown())
        #expect(restored.isMarkdownPreview)
        #expect(restored.id == config.id)
        state.loadConfig(config)
        #expect(state.text == SupportedContentOverview.markdown())
    }

    @Test @MainActor func menuImagesRemainVisibleOnMacOS27() {
        guard #available(macOS 27.0, *) else { return }
        let symbolItem = NSMenuItem(title: "Symbol", action: nil, keyEquivalent: "").withSymbol("folder")
        #expect(symbolItem.image != nil)
        #expect(symbolItem.preferredImageVisibility == .visible)

        let menu = NSMenu()
        let submenu = NSMenu()
        let parent = NSMenuItem(title: "Submenu", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
        let generatedItem = NSMenuItem(title: "Generated", action: nil, keyEquivalent: "")
        generatedItem.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        submenu.addItem(generatedItem)
        let delegate = AppDelegate()
        delegate.restoreMenuItemImages(Notification(name: NSMenu.didBeginTrackingNotification, object: menu))
        #expect(generatedItem.preferredImageVisibility == .visible)
        #expect(parent.preferredImageVisibility == .automatic)
    }

    @Test @MainActor func menuImagesAddedOrUpdatedAfterTrackingRemainVisible() {
        guard #available(macOS 27.0, *) else { return }
        let delegate = AppDelegate()
        delegate.installMenuImageVisibilityObservers()
        defer { NotificationCenter.default.removeObserver(delegate) }
        let menu = NSMenu()
        let favorite = NSMenuItem(title: "Favorite", action: nil, keyEquivalent: "")
        menu.addItem(favorite)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(favorite.preferredImageVisibility == .automatic)
        // 菜单开始跟踪时没有 image，随后由 SwiftUI 的更新过程补齐。
        favorite.image = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: nil)
        #expect(favorite.preferredImageVisibility == .visible)
        let rename = NSMenuItem(title: "Rename", action: nil, keyEquivalent: "")
        rename.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        menu.addItem(rename)
        #expect(rename.preferredImageVisibility == .visible)
        // 同一菜单重用时图标和可见性可能被重新配置。
        favorite.preferredImageVisibility = .automatic
        favorite.image = NSImage(systemSymbolName: "bookmark.slash.fill", accessibilityDescription: nil)
        #expect(favorite.preferredImageVisibility == .visible)
        // 动态子菜单中的延迟图标也走同一修正入口。
        let submenu = NSMenu()
        rename.submenu = submenu
        let child = NSMenuItem(title: "Child", action: nil, keyEquivalent: "")
        submenu.addItem(child)
        child.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        #expect(child.preferredImageVisibility == .visible)
        delegate.restoreMenuItemImages(Notification(name: NSMenu.didChangeItemNotification, object: menu,
                                                    userInfo: ["NSMenuItemIndex": -1]))
        #expect(favorite.preferredImageVisibility == .visible)
    }

    @Test func globalAndFileShortcutGroups() throws {
        #expect(KeyboardShortcutCatalog.sections.prefix(2) == [.global, .opening])
        #expect(KeyboardShortcutCatalog.global.map(\.id) == ["window.showAllFoils", "global.openClipboardContent"])
        #expect(KeyboardShortcutCatalog.global.last?.defaultShortcut == nil)
        #expect(!KeyboardShortcutCatalog.window.contains { $0.id == "window.showAllFoils" })
        #expect(KeyboardShortcutCatalog.openClipboardContent.defaultShortcut ==
                KeyboardShortcut(keyEquivalent: "v", modifiers: [.command, .shift]))
        let ids = KeyboardShortcutCatalog.sections.flatMap { $0.definitions.map(\.id) }
        #expect(Set(ids).count == ids.count)
        let camera = try #require(KeyboardShortcutCatalog.definition(withID: "file.openCamera"))
        #expect(camera.titleKey == "Open Camera")
        #expect(camera.defaultShortcut == nil)
        #expect(KeyboardShortcutCatalog.opening.contains { $0.id == "file.openCamera" })
    }

    @Test func shortcutsAreGroupedByPurpose() {
        #expect(KeyboardShortcutCatalog.sections == [.global, .opening, .file, .go, .view, .image, .web, .playback, .window, .history])
        #expect(KeyboardShortcutCatalog.image.map(\.id) == [
            "edit.extractText", "edit.extractImageSubject", "view.selectColor", "view.slideshow",
            "view.fitWindowToImage", "view.fitImageToWindowWidth"
        ])
        #expect(KeyboardShortcutCatalog.web.map(\.id) == [
            "file.openInBrowser", "file.copyURL", "view.captureImage"
        ])
        #expect(KeyboardShortcutCatalog.go.suffix(2).map(\.id) == ["view.toggleNavigator", "view.moveNavigatorSide"])
        #expect(KeyboardShortcutCatalog.definition(withID: "view.toggleFullScreen")?.titleKey == "Shortcut Toggle Full Screen")
        #expect(KeyboardShortcutCatalog.definition(withID: "edit.extractImageSubject")?.noteKey == "Shortcut Scope Detected Image Subject")
    }

    @MainActor
    @Test func hidingOneFoilKeepsOtherFoilsVisibleAndCanBeRestored() throws {
        let first = FloatingWindowController(appState: AppState())
        let second = FloatingWindowController(appState: AppState())
        defer { first.close(); second.close() }
        let firstWindow = try #require(first.window)
        let secondWindow = try #require(second.window)
        firstWindow.orderFront(nil)
        secondWindow.orderFront(nil)
        first.hideFoil()
        #expect(!firstWindow.isVisible)
        #expect(secondWindow.isVisible)
        first.showWindow(nil)
        firstWindow.makeKeyAndOrderFront(nil)
        #expect(firstWindow.isVisible)
    }

    @MainActor
    @Test func shortcutOverviewRegeneratesOnHistoryRestore() async throws {
        let definition = try #require(KeyboardShortcutCatalog.definition(withID: "file.openClipboardContent"))
        let store = KeyboardShortcutStore.shared
        let previous = store.shortcut(for: definition)
        let customized = store.isCustomized(definition)
        let state = AppState()
        defer {
            if customized { store.setShortcut(previous, for: definition) }
            else { store.reset(definition) }
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        store.reset(definition)
        state.openKeyboardShortcutsOverview()
        let config = state.toConfig()
        #expect(config.sourceFingerprint == KeyboardShortcutsOverview.sourceFingerprint)
        #expect(HistoryManager.shared.historyConfigs.contains { $0.id == config.id })
        store.setShortcut(KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .control]), for: definition)
        let restored = AppState(config: config)
        #expect(restored.text.contains("| ⇧⌘V | \(KeyboardShortcutsOverview.changedKeyStart)⌃⌘J\(KeyboardShortcutsOverview.changedKeyEnd) |"))
        #expect(restored.isMarkdownPreview)
        #expect(restored.id == config.id)
        store.setShortcut(nil, for: definition)
        state.loadConfig(config)
        #expect(state.text != restored.text)
        #expect(!state.text.contains("| ⇧⌘V | ⌃⌘J |"))
        let none = NSLocalizedString("Shortcut Overview Unassigned", comment: "")
        #expect(state.text.contains("| ⇧⌘V | \(KeyboardShortcutsOverview.changedKeyStart)\(none)\(KeyboardShortcutsOverview.changedKeyEnd) |"))
        store.setShortcut(definition.defaultShortcut, for: definition)
        #expect(KeyboardShortcutsOverview.markdown().contains("| ⇧⌘V | ⇧⌘V |"))
        restored.updateRenderedMarkdown()
        for _ in 0..<200 {
            if restored.renderedMarkdown.string.contains("⌃⌘J") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let keyRange = (restored.renderedMarkdown.string as NSString).range(of: "⌃⌘J")
        #expect(keyRange.location != NSNotFound)
        let color = try #require(restored.renderedMarkdown.attribute(.foregroundColor, at: keyRange.location, effectiveRange: nil) as? NSColor)
        #expect(color == NSColor.systemRed)
        #expect(!restored.renderedMarkdown.string.contains(KeyboardShortcutsOverview.changedKeyStart))
        #expect(state.text.contains("⌘W"))
        #expect(!state.text.contains("{{"))
    }

    @Test func indicesZeroThroughNineMapToDigits() {
        #expect(FoilExposeShortcut.key(forIndex: 0) == "1")
        #expect(FoilExposeShortcut.key(forIndex: 4) == "5")
        #expect(FoilExposeShortcut.key(forIndex: 8) == "9")
        #expect(FoilExposeShortcut.key(forIndex: 9) == "0")
    }

    @Test func indicesTenThroughThirtyFiveMapToLetters() {
        #expect(FoilExposeShortcut.key(forIndex: 10) == "A")
        #expect(FoilExposeShortcut.key(forIndex: 11) == "B")
        #expect(FoilExposeShortcut.key(forIndex: 17) == "H")
        #expect(FoilExposeShortcut.key(forIndex: 35) == "Z")
    }

    @Test func indexThirtySixAndBeyondHaveNoShortcut() {
        #expect(FoilExposeShortcut.key(forIndex: 36) == nil)
        #expect(FoilExposeShortcut.key(forIndex: 100) == nil)
    }

    @Test func negativeIndicesHaveNoShortcut() {
        #expect(FoilExposeShortcut.key(forIndex: -1) == nil)
        #expect(FoilExposeShortcut.key(forIndex: -9) == nil)
    }

    @Test func allAssignedShortcutsAreUnique() {
        let keys = (0..<36).compactMap { FoilExposeShortcut.key(forIndex: $0) }
        #expect(keys.count == 36)
        #expect(Set(keys).count == 36)
    }
}
