import AppKit
import Testing
import SwiftUI
@testable import foofoil

@MainActor
@Suite(.serialized)
struct HistoryWindowFrameTests {
    @Test(arguments: [250.0, 650.0], [true, false])
    func restoresTextWindowAfterReset(height: Double, bordered: Bool) async throws {
        try await verifyRestoration(fileExtension: "txt", height: height, bordered: bordered)
    }

    @Test(arguments: ["md", "html", "pdf"])
    func restoresOtherDocumentWindowsAfterReset(fileExtension: String) async throws {
        try await verifyRestoration(fileExtension: fileExtension, height: 650, bordered: true)
    }

    /// 覆盖真实窗口的重置、历史卡片动画载入与异步布局收尾。
    private func verifyRestoration(fileExtension: String, height: Double, bordered: Bool) async throws {
        let state = AppState()
        let historyID = state.id
        let text = String(repeating: "History window frame regression\n", count: 100)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("frame-\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: file) }
        if fileExtension == "pdf" {
            let page = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
            try page.dataWithPDF(inside: page.bounds).write(to: file)
            state.imageURL = file
        } else {
            try text.write(to: file, atomically: true, encoding: .utf8)
            if fileExtension == "html" {
                state.webURL = file
            } else {
                state.textURL = file
                state.text = text
            }
        }
        state.showBorder = bordered
        let controller = FloatingWindowController(appState: state)
        let window = try #require(controller.window)
        defer {
            controller.close()
            HistoryManager.shared.removeFromHistory(state.toConfig())
            if let config = HistoryRepository.shared.config(id: historyID) {
                HistoryManager.shared.removeFromHistory(config)
            }
        }
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(300))
        let screen = try #require(window.screen)
        let savedFrame = NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40, width: 480, height: height)
        window.setFrame(savedFrame, display: true)
        // ⌘K 前留一份文档快照：并行运行的其它套件会清空共享历史库（FoofoilTests 的 clearHistory 用例），
        // 查不到条目时用它加上 ⌘K 当场保存的窗口框，保证这条窗口框回归不依赖共享库的时序。
        let documentConfig = state.toConfig()
        state.resetContent()
        let capturedFrame = try #require(state.windowFrame)
        try await Task.sleep(for: .milliseconds(500))
        let storedConfig = HistoryRepository.shared.config(id: historyID)
        var config = storedConfig ?? documentConfig
        if storedConfig == nil { config.windowFrame = capturedFrame }
        withAnimation(.easeInOut(duration: 0.35)) {
            state.loadConfig(config)
        }
        try await Task.sleep(for: .milliseconds(600))
        #expect(abs(window.frame.minX - savedFrame.minX) < 1)
        #expect(abs(window.frame.minY - savedFrame.minY) < 1)
        #expect(abs(window.frame.width - 480) < 1)
        #expect(abs(window.frame.height - height) < 1)
    }
}
