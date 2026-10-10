import AppKit
import Foundation
import Testing
@testable import foofoil

@MainActor
@Suite(.serialized)
struct FileOpenFeedbackTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func distinguishesUnsupportedMissingAndKnownPreviewDocuments() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState()
        let archive = root.appendingPathComponent("archive.zip")
        let document = root.appendingPathComponent("document.docx")
        try Data([0, 1]).write(to: archive)
        try Data([0, 1]).write(to: document)
        #expect(state.initialFileOpenFailure(archive)?.reason == .unsupported)
        #expect(state.initialFileOpenFailure(root.appendingPathComponent("gone.txt"))?.reason == .missing)
        #expect(state.initialFileOpenFailure(document) == nil)
        #expect(state.initialFileOpenFailure(root) == nil)
    }

    @Test func feedbackAlwaysCreatesSeparateBorderedFoilAndDoesNotEnterHistory() throws {
        let delegate = AppDelegate()
        defer {
            NotificationCenter.default.removeObserver(delegate)
            for controller in delegate.windowControllers { controller.close() }
        }
        let empty = delegate.showNewWindow(with: AppState())
        let source = AppState()
        let failure = FileOpenFeedback(url: URL(fileURLWithPath: "/tmp/example.zip"), reason: .unsupported)
        source.reportFileOpenFeedback([failure])
        let feedback = try #require(delegate.windowControllers.first { $0.appState.isFileOpenFeedback })
        #expect(feedback !== empty)
        #expect(delegate.windowControllers.contains { $0 === empty })
        #expect(feedback.appState.showBorder)
        #expect(!delegate.isBlank(feedback.appState))
        feedback.appState.saveState()
        feedback.appState.opacity = 0.7
        feedback.appState.saveState()
        #expect(!HistoryManager.shared.historyConfigs.contains { $0.id == feedback.appState.id })
        source.reportFileOpenFeedback([.init(url: URL(fileURLWithPath: "/tmp/second.zip"), reason: .unsupported)])
        #expect(delegate.windowControllers.filter { $0.appState.isFileOpenFeedback }.count == 1)
        #expect(feedback.appState.fileOpenFeedback.count == 2)
    }

    @Test func unsupportedDropPreservesExistingContentAndHistoryIdentity() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive.zip")
        try Data([0]).write(to: archive)
        let state = AppState()
        state.text = "Existing note"
        defer {
            state.saveTask?.cancel()
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        let id = state.id
        #expect(state.handleDroppedFileURLs([archive]))
        #expect(state.text == "Existing note")
        #expect(state.id == id)
        #expect(state.imageURL == nil)
    }

    @Test func clipboardUnsupportedFilesNeverConsumeExistingEmptyFoil() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive.zip")
        try Data([0]).write(to: archive)
        let delegate = AppDelegate()
        defer {
            NotificationCenter.default.removeObserver(delegate)
            for controller in delegate.windowControllers { controller.close() }
        }
        let empty = delegate.showNewWindow(with: AppState())
        #expect(delegate.openClipboardFileURLs([archive]))
        #expect(delegate.isBlank(empty.appState))
        #expect(delegate.windowControllers.contains { $0 === empty })
        #expect(delegate.windowControllers.filter { $0.appState.isFileOpenFeedback }.count == 1)
        #expect(delegate.openClipboardFileURLs([archive]))
        #expect(delegate.windowControllers.filter { $0.appState.isFileOpenFeedback }.count == 2)
    }

    @Test func feedbackBecomesOrdinaryContentAfterSuccessfulOpening() {
        let state = AppState()
        state.fileOpenFeedback = [.init(url: URL(fileURLWithPath: "/tmp/example.zip"), reason: .unsupported)]
        #expect(state.isFileOpenFeedback)
        state.text = "New content"
        defer {
            state.saveTask?.cancel()
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        #expect(!state.isFileOpenFeedback)
    }
    @Test func failedUnknownPreviewPreservesOriginalContent() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unknown = root.appendingPathComponent("unknown.foilunsupported")
        try Data((0..<1024).map { UInt8($0 % 256) }).write(to: unknown)
        let state = AppState()
        state.text = "Original preview content"
        defer {
            state.saveTask?.cancel()
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        let id = state.id
        let delegate = AppDelegate()
        defer {
            NotificationCenter.default.removeObserver(delegate)
            for controller in delegate.windowControllers { controller.close() }
        }
        state.openFile(url: unknown)
        let deadline = Date().addingTimeInterval(10)
        while state.pendingContentOpenCount > 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.pendingContentOpenCount == 0)
        #expect(state.text == "Original preview content")
        #expect(state.id == id)
        #expect(state.imageURL == nil)
        #expect(delegate.windowControllers.contains { $0.appState.isFileOpenFeedback })
    }

    @Test func emptyDirectoryGetsSeparateFeedback() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = AppDelegate()
        defer {
            NotificationCenter.default.removeObserver(delegate)
            for controller in delegate.windowControllers { controller.close() }
        }
        let state = AppState()
        #expect(state.handleDroppedFileURLs([root]))
        let deadline = Date().addingTimeInterval(10)
        while state.activeDirectoryDropScan != nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let feedback = try #require(delegate.windowControllers.first { $0.appState.isFileOpenFeedback })
        #expect(feedback.appState.fileOpenFeedback.first?.reason == .emptyDirectory)
        #expect(delegate.isBlank(state))
    }

    @Test func clearingFeedbackReturnsToBlankFoil() {
        let state = AppState()
        state.fileOpenFeedback = [.init(url: URL(fileURLWithPath: "/tmp/example.zip"), reason: .unsupported)]
        state.resetContent()
        #expect(state.fileOpenFeedback.isEmpty)
        #expect(!state.isFileOpenFeedback)
        #expect(!state.hasOpenedContent)
    }

}
