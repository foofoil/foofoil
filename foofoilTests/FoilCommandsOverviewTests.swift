import AppKit
import Testing
@testable import foofoil

@Suite(.sharedApplicationState, .serialized) @MainActor
struct FoilCommandsOverviewTests {
    @Test func bundledReferenceOpensAndRefreshesOnRestore() {
        let markdown = FoilCommandsOverview.markdown()
        #expect(markdown.contains("foil terminal create"))
        #expect(markdown.contains("foil update BOARD"))
        #expect(markdown.contains("--request-id"))
        let state = AppState(isIncognito: true)
        state.openFoilCommandsOverview()
        #expect(state.sourceFingerprint == FoilCommandsOverview.sourceFingerprint)
        var config = state.toConfig()
        config.text = "outdated"
        let restored = AppState(isIncognito: true)
        restored.loadConfig(config)
        #expect(restored.text == markdown)
        #expect(restored.textURL == nil)
    }
}
