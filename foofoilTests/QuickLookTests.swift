import AppKit
import Testing
@testable import foofoil

@MainActor
struct QuickLookTests {
    @Test(arguments: ["docx", "xlsx", "pptx", "rtf"])
    func opensAndRestoresFallbackDocument(_ ext: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(ext.isEmpty ? "document" : "document.\(ext)")
        try Data("Preview fixture".utf8).write(to: url)
        let state = AppState()
        state.openFile(url: url)
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        #expect(state.isQuickLookDocument)
        #expect(state.imageURL == url)
        #expect(state.cachedContentPaths.isEmpty)
        #expect(state.listableKind == nil)
        #expect(state.currentDroppedFileKind == FileListGrouper.dropKind(url: url))

        let repository = HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        #expect(repository.upsert(state.toConfig()))
        let config = try #require(repository.config(id: state.id))
        #expect(config.contentKind == .quickLook)
        let restored = AppState(config: config)
        #expect(restored.isQuickLookDocument)
        #expect(restored.imageURL == url)
        let reused = AppState()
        reused.loadConfig(config)
        #expect(reused.isQuickLookDocument)
        reused.resetContent()
        #expect(!reused.isQuickLookDocument)
    }

    @Test func packageIsOpenedAsOneDocument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = directory.appendingPathComponent("Document.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{\\rtf1 Hello}".utf8).write(to: package.appendingPathComponent("TXT.rtf"))
        #expect(!DroppedFileResolver.containsDirectory(in: [package]))
        let state = AppState()
        #expect(state.canOpenFile(url: package))
        #expect(!state.canOpenFile(url: directory))
        #expect(state.handleDroppedFileURLs([package]))
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        #expect(state.isQuickLookDocument)
        #expect(state.imageURL == package)
    }

    @Test func keepsNativeTextRoute() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).txt")
        try "Native text".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = AppState()
        state.openFile(url: url)
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        #expect(!state.isQuickLookDocument)
        #expect(state.text == "Native text")
        #expect(!state.canOpenFile(url: URL(string: "https://example.com/file.docx")!))
    }

    @Test func unplayableMediaGetsFeedbackWithoutHistory() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp4")
        try Data("Not playable by AVFoundation".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let delegate = AppDelegate()
        defer {
            NotificationCenter.default.removeObserver(delegate)
            for controller in delegate.windowControllers { controller.close() }
        }
        let state = AppState()
        state.openFile(url: url)
        let deadline = Date().addingTimeInterval(10)
        while state.pendingContentOpenCount > 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.pendingContentOpenCount == 0)
        #expect(!state.hasOpenedContent)
        #expect(!state.isQuickLookDocument)
        #expect(!HistoryManager.shared.historyConfigs.contains { $0.id == state.id })
        let feedback = try #require(delegate.windowControllers.first { $0.appState.isFileOpenFeedback })
        #expect(feedback.appState.fileOpenFeedback.first?.reason == .failed)
    }
}
