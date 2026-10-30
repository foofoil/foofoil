import AppKit
import Testing
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct BlankFoilMinimumSizeTests {
    @Test(arguments: [false, true])
    func resetCommandIsDisabledForBlankFoils(isIncognito: Bool) {
        _ = NSApplication.shared
        let state = AppState(isIncognito: isIncognito)
        let controller = FloatingWindowController(appState: state)
        let delegate = AppDelegate()
        delegate.windowControllers = [controller]
        delegate.activeWindowProvider = { controller.window }
        defer { controller.close() }
        let item = NSMenuItem(title: "", action: #selector(AppDelegate.resetContentAction), keyEquivalent: "")
        #expect(!delegate.validateMenuItem(item))
        state.text = "Content"
        #expect(delegate.validateMenuItem(item))
        delegate.resetContentAction()
        #expect(state.isBlank)
        #expect(!delegate.validateMenuItem(item))
    }

    @Test(arguments: [false, true])
    func blankMinimumFitsFourHistoryCardsAndTracksContent(isIncognito: Bool) async throws {
        let state = AppState(isIncognito: isIncognito)
        let controller = FloatingWindowController(appState: state)
        let window = try #require(controller.window)
        defer {
            controller.close()
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        // 窗口装载 SwiftUI 后可能异步再应用一次尺寸限制，给初始状态留出稳定时间。
        for _ in 0..<100 {
            if window.minSize.width == 308 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(window.minSize == NSSize(width: 308, height: 308))
        state.text = "A note"
        for _ in 0..<100 {
            if window.minSize.width == 150 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(window.minSize == NSSize(width: 150, height: 150))
        state.resetContent()
        #expect(state.isBlank)
        for _ in 0..<100 {
            if window.minSize.width == 308 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(window.minSize == NSSize(width: 308, height: 308))
    }
}
