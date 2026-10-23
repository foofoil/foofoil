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

    @Test @MainActor func controlAAndEMoveHighlightToRowEdges() throws {
        let controller = FoilExposeController.shared
        let previousModel = controller.model
        let items = (0..<8).map { index in
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
        func press(_ key: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         characters: key, charactersIgnoringModifiers: key,
                                         isARepeat: false, keyCode: 0))
        }
        // 第二行（下标 4-7）：⌃A 到行首 4，⌃E 到行尾 7。
        model.selectedIndex = 6
        #expect(controller.handleKeyEvent(try press("a")) == nil)
        #expect(model.selectedIndex == 4)
        #expect(controller.handleKeyEvent(try press("e")) == nil)
        #expect(model.selectedIndex == 7)
        // 第一行（下标 0-3）：⌃A 到 0，⌃E 到 3；均不触发条目选择。
        model.selectedIndex = 2
        #expect(controller.handleKeyEvent(try press("A")) == nil)
        #expect(model.selectedIndex == 0)
        #expect(controller.handleKeyEvent(try press("E")) == nil)
        #expect(model.selectedIndex == 3)
        #expect(!activated)
        #expect(model.searchText == "Match")
    }

    @Test @MainActor func overviewFavoriteFilterFollowsConfiguredShortcut() throws {
        let store = KeyboardShortcutStore.shared
        let definition = try #require(KeyboardShortcutCatalog.definition(withID: "history.filterFavorites"))
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
        #expect(controller.handleKeyEvent(try event("d", modifiers: [.command, .shift])) == nil)
        #expect(model.pinnedOnly)
        #expect(controller.handleKeyEvent(try event("d", modifiers: [.command, .shift])) == nil)
        #expect(!model.pinnedOnly)

        store.setShortcut(KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .option]), for: definition)
        #expect(controller.handleKeyEvent(try event("d", modifiers: [.command, .shift])) != nil)
        #expect(!model.pinnedOnly)
        #expect(controller.handleKeyEvent(try event("j", modifiers: [.command, .option])) == nil)
        #expect(model.pinnedOnly)
        store.setShortcut(nil, for: definition)
        #expect(controller.handleKeyEvent(try event("j", modifiers: [.command, .option])) != nil)
        #expect(model.pinnedOnly)
    }

    @Test @MainActor func highlightedHistoryReceivesItemShortcuts() throws {
        let controller = FoilExposeController.shared
        let previous = controller.model
        let item = FoilExposeItem(id: UUID(), controller: nil, isHistoryEntry: true,
                                  title: "History", symbolName: "note.text", contentKind: .note, thumbnailPath: nil,
                                  hasHistoryRecord: true)
        let model = FoilExposeModel(items: [], historyItems: [item], fileSearch: { _, _ in }, cancelFiles: {}, musicEnabled: { false })
        controller.model = model
        defer { controller.model = previous }
        var actions: [String] = []
        model.onTogglePinned = { _ in actions.append("favorite") }
        model.onRenameItem = { _ in actions.append("rename") }
        model.onShowInformation = { _ in actions.append("info") }
        model.onClearHistoryItem = { _ in actions.append("delete") }
        func event(_ key: String, modifiers: NSEvent.ModifierFlags = .command, code: UInt16 = 0, repeating: Bool = false) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         characters: key, charactersIgnoringModifiers: key, isARepeat: repeating, keyCode: code))
        }
        for key in ["d", "e", "i"] { #expect(controller.handleKeyEvent(try event(key)) == nil) }
        #expect(controller.handleKeyEvent(try event("\u{8}", modifiers: [], code: 51)) == nil)
        #expect(actions == ["favorite", "rename", "info", "delete"])
        _ = controller.handleKeyEvent(try event("\u{8}", modifiers: [], code: 51, repeating: true))
        #expect(actions.count == 4)
        model.searchText = "/"
        #expect(controller.handleKeyEvent(try event("e")) != nil)
        #expect(actions.count == 4)
    }

    @Test @MainActor func overviewAlertsKeepBackgroundVisibleAndCompleteAsSheets() async throws {
        let screen = try #require(NSScreen.main)
        let model = FoilExposeModel(items: [], historyItems: [], fileSearch: { _, _ in }, cancelFiles: {}, musicEnabled: { false })
        let panel = FoilExposeController.makePanel(for: screen, model: model)
        panel.makeKeyAndOrderFront(nil)
        defer { panel.close() }
        let clear = NSAlert()
        clear.messageText = "Clear"
        clear.addButton(withTitle: "Cancel")
        clear.addButton(withTitle: "Clear")
        let failure = NSAlert()
        failure.messageText = "Failure"
        for alert in [HistoryManager.pinnedDeletionAlert(), FoilTitleEditing.makeAlert(title: "Title"), clear, failure] {
            let presentation = Task { await FoilExposeController.presentAlert(alert, on: panel) }
            for _ in 0..<100 where panel.attachedSheet == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(panel.attachedSheet === alert.window)
            #expect(alert.window.sheetParent === panel)
            #expect(panel.isVisible)
            #expect(alert.window.level.rawValue >= panel.level.rawValue)
            panel.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
            #expect(await presentation.value == .alertFirstButtonReturn)
            #expect(panel.isVisible)
        }
        panel.orderOut(nil)
        #expect(await FoilExposeController.presentAlert(NSAlert(), on: panel) == .cancel)
    }

    @Test @MainActor func historyInformationUsesSnapshotWithoutRestoringFoil() async throws {
        let delegate = AppDelegate()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
            window.close()
        }
        var config = WindowConfig(id: UUID(), text: "Saved body")
        config.customTitle = "Snapshot history"
        config.windowFrame = NSStringFromRect(NSRect(x: 0, y: 0, width: 320, height: 240))
        delegate.showFoilInformation(config: config, state: nil, window: window)
        for _ in 0..<100 where window.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let sheet = try #require(window.attachedSheet)
        func text(in view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { text(in: $0) }
        }
        let values = text(in: try #require(sheet.contentView))
        #expect(values.contains("Snapshot history"))
        #expect(values.contains("320 × 240 pt"))
        #expect(delegate.windowControllers.isEmpty)
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

    @Test @MainActor func globalIncognitoClipboardShortcutCanBeConfiguredIndependently() throws {
        let definition = try #require(KeyboardShortcutCatalog.definition(withID: "global.openClipboardIncognito"))
        let store = KeyboardShortcutStore.shared
        let previous = store.shortcut(for: definition)
        let customized = store.isCustomized(definition)
        let ordinary = store.shortcut(forID: "global.openClipboardContent")
        defer {
            if customized { store.setShortcut(previous, for: definition) }
            else { store.reset(definition) }
        }
        #expect(definition.defaultShortcut == nil)
        #expect(store.reset(definition))
        #expect(store.shortcut(for: definition) == nil)
        let custom = KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .control, .shift, .option])
        #expect(store.setShortcut(custom, for: definition))
        #expect(store.shortcut(for: definition) == custom)
        #expect(store.shortcut(forID: "global.openClipboardContent") == ordinary)
        #expect(store.validationMessage(IncognitoOpening.clipboardShortcut, for: definition) == nil)
        #expect(KeyboardShortcutsOverview.markdown().contains(custom.displayString))
        #expect(store.setShortcut(nil, for: definition))
        #expect(store.shortcut(for: definition) == nil)
        #expect(store.reset(definition))
        #expect(store.shortcut(for: definition) == nil)
    }

    @Test func globalAndFileShortcutGroups() throws {
        #expect(KeyboardShortcutCatalog.sections.prefix(2) == [.global, .opening])
        #expect(KeyboardShortcutCatalog.global.map(\.id) == ["window.showAllFoils", "global.openClipboardContent", "global.openClipboardIncognito"])
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

    @Test func indicesTenThroughTwentyNineMapToLettersSkippingNavigationKeys() {
        #expect(FoilExposeShortcut.key(forIndex: 10) == "C")
        #expect(FoilExposeShortcut.key(forIndex: 11) == "D")
        #expect(FoilExposeShortcut.key(forIndex: 17) == "L")
        #expect(FoilExposeShortcut.key(forIndex: 19) == "O")
        #expect(FoilExposeShortcut.key(forIndex: 20) == "Q")
        #expect(FoilExposeShortcut.key(forIndex: 29) == "Z")
        for index in 10..<30 {
            let key = FoilExposeShortcut.key(forIndex: index)?.lowercased() ?? ""
            #expect(!FoilExposeShortcut.reservedLetters.contains(key))
        }
    }

    @Test func indexThirtyAndBeyondHaveNoShortcut() {
        #expect(FoilExposeShortcut.key(forIndex: 30) == nil)
        #expect(FoilExposeShortcut.key(forIndex: 100) == nil)
    }

    @Test func negativeIndicesHaveNoShortcut() {
        #expect(FoilExposeShortcut.key(forIndex: -1) == nil)
        #expect(FoilExposeShortcut.key(forIndex: -9) == nil)
    }

    @Test func allAssignedShortcutsAreUnique() {
        let keys = (0..<30).compactMap { FoilExposeShortcut.key(forIndex: $0) }
        #expect(keys.count == 30)
        #expect(Set(keys).count == 30)
    }

    @Test @MainActor func returnOpensDirectPathAndURLFromTheScopeDropdown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("expose-return-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Return Target.txt")
        try Data("path".utf8).write(to: file)

        let controller = FoilExposeController.shared
        let previousModel = controller.model
        defer { controller.model = previousModel }
        let model = FoilExposeModel(items: [], historyItems: [], fileSearch: { _, _ in },
                                    cancelFiles: {}, cameraAvailable: { false }, musicEnabled: { false })
        controller.model = model

        var openedFile: URL?
        var openedURL: URL?
        var selectedItem = false
        model.onOpenFile = { openedFile = $0 }
        model.onOpenURL = { openedURL = $0 }
        model.onSelect = { _ in selectedItem = true }

        let returnEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        model.searchText = "'\(file.path)'"
        #expect(controller.handleKeyEvent(returnEvent) == nil)
        #expect(openedFile?.path == file.path)
        #expect(!selectedItem)

        model.searchText = "example.com"
        #expect(controller.handleKeyEvent(returnEvent) == nil)
        #expect(openedURL?.absoluteString == "https://example.com")
        #expect(!selectedItem)
        model.stopFileSearch()
    }
}
