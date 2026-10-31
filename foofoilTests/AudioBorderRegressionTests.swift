import AppKit
import Testing
@testable import foofoil

@MainActor
@Suite(.serialized)
struct AudioBorderRegressionTests {
    @Test func togglingAudioBorderKeepsStateAndRestoresWindowSize() async throws {
        let state = AppState()
        state.originalImageName = "border-test.mp3"
        state.imageURL = URL(fileURLWithPath: "/tmp/border-test.mp3")
        state.showBorder = false
        let controller = FloatingWindowController(appState: state)
        defer {
            controller.close()
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        let window = try #require(controller.window)
        try await Task.sleep(for: .milliseconds(300))
        window.setFrame(NSRect(x: 100, y: 100, width: 500, height: 500), display: true)
        controller.beginManualLiveResize()
        controller.endManualLiveResize()
        let initial = window.frame.size
        for _ in 0..<3 {
            state.showBorder = true
            #expect(state.showBorder)
            state.showBorder = false
            #expect(!state.showBorder)
            #expect(abs(window.frame.width - initial.width) < 1)
            #expect(abs(window.frame.height - initial.height) < 1)
        }
    }
}
