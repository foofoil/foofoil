import Testing
@testable import foofoil

@Suite(.sharedApplicationState)
@MainActor
struct TemporaryIncognitoOpeningTests {
    @Test func optionTemporarilyEnablesIncognitoOpeningOnlyForBlankFoil() {
        let state = AppState()
        #expect(state.isBlank)
        #expect(state.canOpenRecentHistory)
        #expect(!state.usesIncognitoOpening)

        state.isOptionKeyPressed = true
        #expect(state.isTemporaryIncognito)
        #expect(state.usesIncognitoOpening)
        #expect(state.shouldOpenTemporarilyIncognito(optionPressed: true))
        // 临时状态只改变打开入口，空箔中的历史记录仍然可用。
        #expect(state.canOpenRecentHistory)

        state.text = "note"
        #expect(!state.isTemporaryIncognito)
        #expect(!state.usesIncognitoOpening)
        #expect(!state.shouldOpenTemporarilyIncognito(optionPressed: true))
    }

    @Test func incognitoFoilKeepsItsOwnPrivacyState() {
        let state = AppState(isIncognito: true)
        #expect(state.isBlank)
        #expect(state.usesIncognitoOpening)
        #expect(!state.isTemporaryIncognito)
        #expect(!state.shouldOpenTemporarilyIncognito(optionPressed: true))
        #expect(!state.canOpenRecentHistory)
    }
}
