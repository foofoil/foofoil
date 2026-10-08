//
//  FoilExposeShortcutTests.swift
//  foofoil
//
//  Created by tolg on 2026/9/14.
//

import AppKit
import Testing
@testable import foofoil

struct FoilExposeShortcutTests {
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

    @Test func globalAndFileShortcutGroups() {
        #expect(KeyboardShortcutCatalog.sections.prefix(2) == [.global, .file])
        #expect(KeyboardShortcutCatalog.global.map(\.id) == ["window.showAllFoils", "global.openClipboardContent"])
        #expect(KeyboardShortcutCatalog.global.last?.defaultShortcut == nil)
        #expect(!KeyboardShortcutCatalog.window.contains { $0.id == "window.showAllFoils" })
        #expect(KeyboardShortcutCatalog.openClipboardContent.defaultShortcut ==
                KeyboardShortcut(keyEquivalent: "v", modifiers: [.command, .shift]))
        let ids = KeyboardShortcutCatalog.sections.flatMap { $0.definitions.map(\.id) }
        #expect(Set(ids).count == ids.count)
        let camera = try? #require(KeyboardShortcutCatalog.definition(withID: "file.openCamera"))
        #expect(camera?.titleKey == "Open Camera")
        #expect(camera?.defaultShortcut == nil)
        #expect(KeyboardShortcutCatalog.file.contains { $0.id == "file.openCamera" })
    }

    @Test func shortcutsAreGroupedByPurpose() {
        #expect(KeyboardShortcutCatalog.sections == [.global, .file, .go, .view, .image, .web, .playback, .window, .history])
        #expect(KeyboardShortcutCatalog.image.map(\.id) == [
            "edit.extractText", "edit.extractImageSubject", "view.selectColor", "view.slideshow",
            "view.fitWindowToImage", "view.fitImageToWindowWidth"
        ])
        #expect(KeyboardShortcutCatalog.web.map(\.id) == [
            "file.openInBrowser", "file.copyURL", "view.reloadPage", "view.captureImage"
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
        store.setShortcut(KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .option]), for: definition)
        let restored = AppState(config: config)
        #expect(restored.text.contains("| ⇧⌘V | \(KeyboardShortcutsOverview.changedKeyStart)⌥⌘J\(KeyboardShortcutsOverview.changedKeyEnd) |"))
        #expect(restored.isMarkdownPreview)
        #expect(restored.id == config.id)
        store.setShortcut(nil, for: definition)
        state.loadConfig(config)
        #expect(state.text != restored.text)
        #expect(!state.text.contains("| ⇧⌘V | ⌥⌘J |"))
        let none = NSLocalizedString("Shortcut Overview Unassigned", comment: "")
        #expect(state.text.contains("| ⇧⌘V | \(KeyboardShortcutsOverview.changedKeyStart)\(none)\(KeyboardShortcutsOverview.changedKeyEnd) |"))
        store.setShortcut(definition.defaultShortcut, for: definition)
        #expect(KeyboardShortcutsOverview.markdown().contains("| ⇧⌘V | ⇧⌘V |"))
        restored.updateRenderedMarkdown()
        for _ in 0..<200 {
            if restored.renderedMarkdown.string.contains("⌥⌘J") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let keyRange = (restored.renderedMarkdown.string as NSString).range(of: "⌥⌘J")
        #expect(keyRange.location != NSNotFound)
        let color = try #require(restored.renderedMarkdown.attribute(.foregroundColor, at: keyRange.location, effectiveRange: nil) as? NSColor)
        #expect(color == NSColor.systemRed)
        #expect(!restored.renderedMarkdown.string.contains(KeyboardShortcutsOverview.changedKeyStart))
        #expect(state.text.contains("⌘W"))
        #expect(!state.text.contains("{{"))
    }

    @Test func indicesZeroThroughEightMapToDigits() {
        #expect(FoilExposeShortcut.key(forIndex: 0) == "1")
        #expect(FoilExposeShortcut.key(forIndex: 4) == "5")
        #expect(FoilExposeShortcut.key(forIndex: 8) == "9")
    }

    @Test func indicesNineThroughThirtyFourMapToLetters() {
        #expect(FoilExposeShortcut.key(forIndex: 9) == "A")
        #expect(FoilExposeShortcut.key(forIndex: 10) == "B")
        #expect(FoilExposeShortcut.key(forIndex: 16) == "H")
        #expect(FoilExposeShortcut.key(forIndex: 34) == "Z")
    }

    @Test func indexThirtyFiveAndBeyondHaveNoShortcut() {
        #expect(FoilExposeShortcut.key(forIndex: 35) == nil)
        #expect(FoilExposeShortcut.key(forIndex: 100) == nil)
    }

    @Test func negativeIndicesHaveNoShortcut() {
        #expect(FoilExposeShortcut.key(forIndex: -1) == nil)
        #expect(FoilExposeShortcut.key(forIndex: -9) == nil)
    }

    @Test func allAssignedShortcutsAreUnique() {
        let keys = (0..<35).compactMap { FoilExposeShortcut.key(forIndex: $0) }
        #expect(keys.count == 35)
        #expect(Set(keys).count == 35)
    }
}
