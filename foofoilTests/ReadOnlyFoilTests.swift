import AppKit
import Testing
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct ReadOnlyFoilTests {
    @Test func textIsReadOnlyWithoutAnExternalFile() {
        let state = AppState(isIncognito: true)
        #expect(!state.isReadOnlyTextFile)
        state.text = "Clipboard text"
        #expect(state.isReadOnlyTextFile)
        #expect(state.verticalArrowsScrollContent)
        state.originalImageName = "source.md"
        state.isMarkdownPreview = false
        #expect(state.verticalArrowsScrollContent)
    }

    @Test func embeddedSearchDoesNotChangeTheBlankFoil() throws {
        let state = AppState(isIncognito: true)
        let search = HistorySearchWindowController(embedded: true)
        search.beginEmbeddedSearch(target: state)
        defer { search.endEmbeddedSearch() }
        search.model.query = "example.com"
        #expect(state.isBlank)
        #expect(state.text.isEmpty)
        #expect(search.window == nil)
        #expect(search.model.opensIncognito)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(HistorySearchPanel.handleSearchKey(escape, model: search.model, dismiss: { search.model.reset() }))
        #expect(search.model.query.isEmpty)
        #expect(state.isBlank)
    }
}
