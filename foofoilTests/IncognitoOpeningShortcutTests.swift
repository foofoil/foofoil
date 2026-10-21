import AppKit
import Testing
@testable import foofoil

@Suite(.sharedApplicationState)
@MainActor
struct IncognitoOpeningShortcutTests {
    @Test func derivationFollowsCustomizationAndClearing() throws {
        let store = KeyboardShortcutStore.shared
        let definition = try #require(KeyboardShortcutCatalog.definition(withID: "file.openURL"))
        let original = store.shortcut(for: definition)
        let customized = store.isCustomized(definition)
        defer {
            if customized { store.setShortcut(original, for: definition) }
            else { store.reset(definition) }
        }
        store.setShortcut(KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .control]), for: definition)
        #expect(store.incognitoShortcut(forID: definition.id) == KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .control, .option]))
        store.setShortcut(nil, for: definition)
        #expect(store.incognitoShortcut(forID: definition.id) == nil)
        #expect(store.shortcut(forID: "file.openClipboardIncognito") == IncognitoOpening.clipboardShortcut)
        store.reset(definition)
        #expect(store.incognitoShortcut(forID: definition.id) == IncognitoOpening.derived(definition.defaultShortcut))
    }

    @Test func conflictsIncludeDerivedKeysInBothDirectionsAndFixedClipboard() throws {
        let store = KeyboardShortcutStore.shared
        let opening = try #require(KeyboardShortcutCatalog.definition(withID: "file.openURL"))
        let other = try #require(KeyboardShortcutCatalog.definition(withID: "view.reloadPage"))
        let before = store.shortcut(for: other)
        let customized = store.isCustomized(other)
        defer {
            if customized { store.setShortcut(before, for: other) }
            else { store.reset(other) }
        }
        let ordinary = KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .control])
        store.setShortcut(IncognitoOpening.derived(ordinary), for: other)
        #expect(store.validationMessage(ordinary, for: opening) != nil)
        #expect(store.validationMessage(store.incognitoShortcut(forID: opening.id), for: other) != nil)
        #expect(store.validationMessage(KeyboardShortcut(keyEquivalent: "v", modifiers: [.command]), for: opening) != nil)
        #expect(store.validationMessage(IncognitoOpening.clipboardShortcut, for: other) != nil)
        #expect(store.validationMessage(KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .option]), for: opening) == NSLocalizedString("Option Reserved for Incognito", comment: ""))
        #expect(store.validationMessage(nil, for: opening) == nil)
    }

    @Test func fixedMenuKeysAndAllDefaultOpeningPairsAreChecked() throws {
        let store = KeyboardShortcutStore.shared
        let savedMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = savedMenu }
        let menu = NSMenu()
        let parent = NSMenuItem()
        parent.submenu = NSMenu()
        parent.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(parent)
        NSApp.mainMenu = menu
        for id in IncognitoOpening.titles.keys {
            let definition = try #require(KeyboardShortcutCatalog.definition(withID: id))
            #expect(store.validationMessage(definition.defaultShortcut, for: definition) == nil)
            #expect(store.validationMessage(KeyboardShortcut(keyEquivalent: "q", modifiers: [.command]), for: definition) != nil)
        }
    }

    @Test func rejectedAssignmentAndResetPreserveCurrentBinding() throws {
        let store = KeyboardShortcutStore.shared
        let opening = try #require(KeyboardShortcutCatalog.definition(withID: "file.openURL"))
        let other = try #require(KeyboardShortcutCatalog.definition(withID: "view.reloadPage"))
        let oldOpening = store.shortcut(for: opening)
        let oldOther = store.shortcut(for: other)
        let customizedOpening = store.isCustomized(opening)
        let customizedOther = store.isCustomized(other)
        defer {
            if customizedOther { store.setShortcut(oldOther, for: other) } else { store.reset(other) }
            if customizedOpening { store.setShortcut(oldOpening, for: opening) } else { store.reset(opening) }
        }
        let custom = KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .control])
        #expect(store.setShortcut(custom, for: opening))
        #expect(!store.setShortcut(IncognitoOpening.derived(custom), for: opening))
        #expect(store.shortcut(for: opening) == custom)
        #expect(store.setShortcut(opening.defaultShortcut, for: other))
        #expect(!store.reset(opening))
        #expect(store.shortcut(for: opening) == custom)
        let symbol = KeyboardShortcut(keyEquivalent: "=", modifiers: [.command, .shift])
        #expect(store.validationMessage(symbol, for: opening) != nil)
    }

    @Test func menuAlternatesRefreshAndClipboardAliasDoesNotDuplicate() throws {
        let delegate = AppDelegate()
        let menu = NSMenu()
        delegate.fileMenu = menu
        for definition in KeyboardShortcutCatalog.opening where IncognitoOpening.titles[definition.id] != nil {
            let item = NSMenuItem(title: definition.displayName, action: #selector(AppDelegate.openFileAction), keyEquivalent: "")
            item.representedObject = definition.id
            menu.addItem(item)
        }
        let clipboard = NSMenuItem(title: "Private clipboard", action: #selector(AppDelegate.openClipboardIncognitoAction), keyEquivalent: "v")
        menu.addItem(clipboard)
        delegate.installIncognitoOpeningAlternates(in: menu)
        delegate.applyKeyboardShortcuts(to: menu)
        for id in IncognitoOpening.titles.keys {
            let item = try #require(menu.items.first { $0.representedObject as? String == id + IncognitoOpening.suffix })
            #expect(item.isAlternate)
            #expect(item.action == #selector(AppDelegate.openIncognitoContentAction(_:)))
            #expect(item.keyEquivalentModifierMask.contains(.option))
        }
        delegate.updateIncognitoClipboardVisibility(optionPressed: true)
        #expect(clipboard.isHidden)
        delegate.updateIncognitoClipboardVisibility(optionPressed: false)
        #expect(!clipboard.isHidden)
    }
    @Test func quickOpenIsAnOpeningCommandWithDerivedShortcut() throws {
        let definition = try #require(KeyboardShortcutCatalog.definition(withID: "history.search"))
        #expect(KeyboardShortcutCatalog.opening.first?.id == definition.id)
        #expect(KeyboardShortcutStore.shared.incognitoShortcut(forID: definition.id) == KeyboardShortcut(keyEquivalent: "p", modifiers: [.command, .option]))
        #expect(KeyboardShortcutStore.shared.validationMessage(KeyboardShortcut(keyEquivalent: "p", modifiers: [.command, .option]), for: definition) != nil)
        let search = HistorySearchWindowController.shared
        defer { search.dismiss() }
        search.configureOpening(isIncognito: true)
        #expect(search.model.opensIncognito)
        search.configureOpening(isIncognito: false)
        #expect(!search.model.opensIncognito)
    }

    @Test func privateQuickOpenHistoryKeepsSourceVisitAndCreatesSeparateIdentity() throws {
        let source = AppState()
        source.openText("Quick Open private copy fixture", isMarkdown: false)
        let config = source.toConfig()
        let visits = try #require(HistoryRepository.shared.visitDates(id: source.id))
        let delegate = AppDelegate()
        defer {
            for controller in delegate.windowControllers { controller.close() }
            HistoryManager.shared.removeFromHistory(config)
        }
        delegate.openHistoryConfigIncognito(config)
        let opened = try #require(delegate.windowControllers.first?.appState)
        #expect(opened.isIncognito)
        #expect(opened.id != source.id)
        #expect(opened.text == source.text)
        #expect(HistoryRepository.shared.config(id: opened.id) == nil)
        #expect(HistoryRepository.shared.visitDates(id: source.id)?.last == visits.last)
    }

    @Test func appKitDispatchesBothClipboardIncognitoShortcuts() throws {
        let delegate = OpeningSpy()
        let menu = NSMenu()
        let normal = NSMenuItem(title: "Clipboard", action: #selector(AppDelegate.openClipboardContentAction), keyEquivalent: "v")
        normal.target = delegate
        normal.keyEquivalentModifierMask = [.command, .shift]
        normal.representedObject = "file.openClipboardContent"
        menu.addItem(normal)
        delegate.installIncognitoOpeningAlternates(in: menu)
        let fixed = NSMenuItem(title: "Private clipboard", action: #selector(AppDelegate.openClipboardIncognitoAction), keyEquivalent: "v")
        fixed.target = delegate
        fixed.keyEquivalentModifierMask = [.command, .option]
        fixed.isHidden = true
        fixed.allowsKeyEquivalentWhenHidden = true
        menu.addItem(fixed)
        for modifiers: NSEvent.ModifierFlags in [[.command, .option], [.command, .shift, .option], [.command, .shift]] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                    timestamp: 0, windowNumber: 0, context: nil,
                                                    characters: modifiers.contains(.shift) ? "V" : "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
            #expect(menu.performKeyEquivalent(with: event))
        }
        #expect(delegate.openings == ["private", "private", "ordinary"])
    }

}

@MainActor
private final class OpeningSpy: AppDelegate {
    var openings: [String] = []
    override func openClipboardContentAction() { openings.append("ordinary") }
    override func openClipboardIncognitoAction() { openings.append("private") }
    override func openIncognitoContentAction(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String ?? ""
        openings.append(id == "file.openClipboardContent.incognito" ? "private" : id)
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }
}
