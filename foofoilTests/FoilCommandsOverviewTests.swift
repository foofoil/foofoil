import AppKit
import Testing
@testable import foofoil

@Suite(.sharedApplicationState, .serialized) @MainActor
struct FoilCommandsOverviewTests {
    @Test(arguments: ["en", "zh-Hans"])
    func localizedReferenceIncludesEveryCurrentCommand(language: String) throws {
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
        let bundle = try #require(Bundle(url: url))
        let markdown = FoilCommandsOverview.markdown(bundle: bundle)
        #expect(!markdown.isEmpty)
        #expect(!markdown.contains("{{"))
        #expect(!markdown.contains("Foil CLI Command"))
        #expect(!markdown.contains("Foil CLI Group"))
        for definition in AgentCommandCatalog.commands.values {
            let usage = ("foil " + definition.usage).replacingOccurrences(of: "|", with: "\\|")
            #expect(markdown.contains("`" + usage + "`"))
        }
        #expect(markdown.contains("foil guide"))
        #expect(markdown.contains("foil --version"))
    }

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
