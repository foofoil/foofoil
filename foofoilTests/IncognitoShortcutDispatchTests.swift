import AppKit
import Testing
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct IncognitoShortcutDispatchTests {
    private func event(in window: NSWindow, key: String, code: UInt16,
                       modifiers: NSEvent.ModifierFlags, repeatKey: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: repeatKey, keyCode: code))
    }

    @Test(arguments: [false, true])
    func incognitoTogglePrecedesTextInput(editable: Bool) throws {
        let store = KeyboardShortcutStore.shared
        let definition = try #require(KeyboardShortcutCatalog.definition(withID: "file.toggleIncognito"))
        let original = store.shortcut(for: definition)
        let customized = store.isCustomized(definition)
        defer { if customized { store.setShortcut(original, for: definition) } else { store.reset(definition) } }
        store.reset(definition)
        let state = AppState(isIncognito: true)
        state.openText("# Shortcut fixture", isMarkdown: true)
        let controller = FloatingWindowController(appState: state)
        defer { controller.close(); HistoryManager.shared.removeFromHistory(state.toConfig()) }
        let window = try #require(controller.window)
        let text = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        text.string = state.text
        text.isEditable = editable
        window.contentView = text
        window.makeFirstResponder(text)
        window.sendEvent(try event(in: window, key: "\u{1b}", code: 53, modifiers: .option))
        #expect(!state.isIncognito)
        window.sendEvent(try event(in: window, key: "\u{1b}", code: 53, modifiers: .option, repeatKey: true))
        #expect(!state.isIncognito)
        #expect(text.string == "# Shortcut fixture")
        #expect(window.performKeyEquivalent(with: try event(in: window, key: "\u{1b}", code: 53, modifiers: [.option, .capsLock])))
        #expect(state.isIncognito)
    }

    @Test func customAndDisabledIncognitoBindingsAreRespected() throws {
        let store = KeyboardShortcutStore.shared
        let definition = try #require(KeyboardShortcutCatalog.definition(withID: "file.toggleIncognito"))
        let original = store.shortcut(for: definition)
        let customized = store.isCustomized(definition)
        defer { if customized { store.setShortcut(original, for: definition) } else { store.reset(definition) } }
        #expect(store.setShortcut(KeyboardShortcut(keyEquivalent: "y", modifiers: [.command, .option, .control]), for: definition))
        let state = AppState(isIncognito: true)
        let controller = FloatingWindowController(appState: state)
        defer { controller.close(); HistoryManager.shared.removeFromHistory(state.toConfig()) }
        let window = try #require(controller.window)
        window.sendEvent(try event(in: window, key: "\u{1b}", code: 53, modifiers: .option))
        #expect(state.isIncognito)
        #expect(window.performKeyEquivalent(with: try event(in: window, key: "y", code: 16, modifiers: [.command, .option, .control])))
        #expect(!state.isIncognito)
        #expect(store.setShortcut(nil, for: definition))
        _ = window.performKeyEquivalent(with: try event(in: window, key: "y", code: 16, modifiers: [.command, .option, .control]))
        #expect(!state.isIncognito)
    }

    @Test func navigatorForwardsIncognitoToggleToItsFoil() throws {
        let state = AppState(isIncognito: true)
        let controller = FloatingWindowController(appState: state)
        let window = try #require(controller.window)
        let navigator = NavigatorPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        navigator.isReleasedWhenClosed = false
        navigator.navigationState = state
        window.addChildWindow(navigator, ordered: .above)
        defer {
            window.removeChildWindow(navigator); navigator.close(); controller.close()
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        let shortcut = try #require(KeyboardShortcutStore.shared.shortcut(forID: "file.toggleIncognito"))
        navigator.sendEvent(try event(in: navigator, key: shortcut.keyEquivalent,
            code: UInt16(shortcut.carbonKeyCode ?? 53), modifiers: shortcut.modifiers))
        #expect(!state.isIncognito)
    }

}
