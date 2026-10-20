import AppKit
import Testing
@testable import foofoil

@Suite(.sharedApplicationState)
@MainActor
struct HistoryFavoriteMenuTests {
    @Test func menuTracksActiveFoilAndTogglesFavoriteWithoutChangingVisitOrder() throws {
        let delegate = AppDelegate()
        delegate.historyMenu = NSMenu()
        let first = AppState()
        first.isBatchUpdating = true
        first.text = "Favorite menu first foil"
        first.isBatchUpdating = false
        let second = AppState()
        second.isBatchUpdating = true
        second.text = "Favorite menu second foil"
        second.isBatchUpdating = false
        let controllers = [FloatingWindowController(appState: first), FloatingWindowController(appState: second)]
        delegate.windowControllers = controllers
        defer {
            for controller in controllers {
                HistoryManager.shared.removeFromHistory(controller.appState.toConfig())
                controller.close()
            }
        }
        for state in [first, second] { #expect(HistoryRepository.shared.upsert(state.toConfig())) }
        let firstVisit = try #require(HistoryRepository.shared.visitDates(id: first.id))
        let order = HistoryRepository.shared.recent(limit: Int.max).map(\.id)
        delegate.activeWindowProvider = { controllers[0].window }
        delegate.updateHistoryMenu()
        let item = try #require(delegate.historyMenu?.items.first)
        #expect(item.action == #selector(AppDelegate.toggleCurrentFoilFavoriteAction))
        #expect(delegate.validateMenuItem(item))
        #expect(item.title == NSLocalizedString("Favorite Current Foil", comment: ""))
        #expect(item.image != nil)
        delegate.toggleCurrentFoilFavoriteAction()
        #expect(HistoryRepository.shared.config(id: first.id)?.historyIsPinned == true)
        #expect(first.toast.message?.text == NSLocalizedString("Favorite Added Toast", comment: ""))
        #expect(second.toast.message == nil)
        #expect(HistoryRepository.shared.config(id: second.id)?.historyIsPinned == false)
        #expect(HistoryRepository.shared.visitDates(id: first.id)?.last == firstVisit.last)
        #expect(HistoryRepository.shared.recent(limit: Int.max).map(\.id) == order)
        #expect(delegate.validateMenuItem(item))
        #expect(item.title == NSLocalizedString("Unfavorite Current Foil", comment: ""))
        delegate.activeWindowProvider = { controllers[1].window }
        #expect(delegate.validateMenuItem(item))
        #expect(item.title == NSLocalizedString("Favorite Current Foil", comment: ""))
        delegate.activeWindowProvider = { controllers[0].window }
        delegate.toggleCurrentFoilFavoriteAction()
        #expect(HistoryRepository.shared.config(id: first.id)?.historyIsPinned == false)
        #expect(first.toast.message?.text == NSLocalizedString("Favorite Removed Toast", comment: ""))
        #expect(HistoryRepository.shared.config(id: first.id) != nil)
    }

    @Test func favoriteShortcutUsesCommandDAndFollowsUserOverrides() throws {
        let definition = try #require(KeyboardShortcutCatalog.definition(withID: "history.toggleFavorite"))
        #expect(definition.defaultShortcut?.keyEquivalent == "d")
        #expect(definition.defaultShortcut?.modifiers == [.command])
        let store = KeyboardShortcutStore.shared
        let wasCustomized = store.isCustomized(definition)
        let previous = store.shortcut(for: definition)
        defer {
            if wasCustomized { store.setShortcut(previous, for: definition) }
            else { store.reset(definition) }
        }
        let delegate = AppDelegate()
        delegate.historyMenu = NSMenu()
        store.reset(definition)
        delegate.updateHistoryMenu()
        #expect(delegate.historyMenu?.items.first?.keyEquivalent == "d")
        #expect(delegate.historyMenu?.items.first?.keyEquivalentModifierMask == [.command])
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                timestamp: 0, windowNumber: 0, context: nil, characters: "d",
                                                charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
        #expect(delegate.matchesConfigurableShortcut(event))
        store.setShortcut(KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .shift]), for: definition)
        delegate.updateHistoryMenu()
        #expect(delegate.historyMenu?.items.first?.keyEquivalent == "j")
        #expect(delegate.historyMenu?.items.first?.keyEquivalentModifierMask == [.command, .shift])
        store.setShortcut(nil, for: definition)
        delegate.updateHistoryMenu()
        #expect(delegate.historyMenu?.items.first?.keyEquivalent == "")
    }

    @Test func searchFavoriteFeedbackSurvivesResultRefreshAndClearsOnStop() throws {
        let config = WindowConfig(id: UUID(), text: "Search toast fixture")
        #expect(HistoryRepository.shared.upsert(config))
        defer { HistoryManager.shared.removeFromHistory(config) }
        let model = HistorySearchViewModel(historySearch: { _ in [] }, fileSearch: { _, _ in }, cancelFiles: {})
        let result = HistorySearchResult(id: config.id, title: "Search toast fixture", contentKind: .note,
                                         thumbnailPath: nil, matchedSnippet: nil, matchedPageNumber: nil, score: 1)
        model.togglePinned(result)
        #expect(HistoryRepository.shared.config(id: config.id)?.historyIsPinned == true)
        #expect(model.toast.message?.text == NSLocalizedString("Favorite Added Toast", comment: ""))
        model.retry()
        #expect(model.toast.message != nil)
        model.stop()
        #expect(model.toast.message == nil)
    }

    @Test func menuRejectsMissingBlankIncognitoAndTemporaryFoils() throws {
        let delegate = AppDelegate()
        let item = NSMenuItem(title: "", action: #selector(AppDelegate.toggleCurrentFoilFavoriteAction), keyEquivalent: "")
        delegate.activeWindowProvider = { nil }
        #expect(!delegate.validateMenuItem(item))
        let blank = AppState()
        let incognito = AppState(isIncognito: true)
        incognito.text = "Private note"
        let preview = AppState()
        preview.isBatchUpdating = true
        preview.text = "Temporary preview"
        preview.isArchivePreview = true
        preview.isBatchUpdating = false
        let controllers = [blank, incognito, preview].map { FloatingWindowController(appState: $0) }
        delegate.windowControllers = controllers
        defer { for controller in controllers { controller.close() } }
        for controller in controllers {
            delegate.activeWindowProvider = { controller.window }
            #expect(!delegate.validateMenuItem(item))
            delegate.toggleCurrentFoilFavoriteAction()
            #expect(HistoryRepository.shared.config(id: controller.appState.id) == nil)
        }
    }

    @Test func favoriteCreatesHistoryForCurrentContentBeforeFirstAutomaticSave() throws {
        let delegate = AppDelegate()
        let state = AppState()
        state.isBatchUpdating = true
        state.text = "New favorite before autosave"
        state.isBatchUpdating = false
        let controller = FloatingWindowController(appState: state)
        delegate.windowControllers = [controller]
        delegate.activeWindowProvider = { controller.window }
        defer {
            HistoryManager.shared.removeFromHistory(state.toConfig())
            controller.close()
        }
        delegate.toggleCurrentFoilFavoriteAction()
        #expect(HistoryRepository.shared.config(id: state.id)?.historyIsPinned == true)
        #expect(!state.isPinned)
    }
}
