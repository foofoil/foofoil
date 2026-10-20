import AppKit
import Foundation
import Testing
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct FileOpenFeedbackTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(arguments: [true, false])
    func failedFileCanBeRemovedFromHistoryWithoutConfirmation(isFavorite: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var config = WindowConfig(id: UUID(), imagePath: root.appendingPathComponent("missing.png").path,
                                  originalImageName: "missing.png", showBorder: true)
        config.historyIsPinned = isFavorite
        #expect(HistoryRepository.shared.upsert(config))
        defer { HistoryRepository.shared.remove(id: config.id) }
        let failure = try #require(config.historyRestoreFileFailure())
        #expect(failure.historyID == config.id)
        #expect(failure.canRemoveFromHistory)
        #expect(await failure.removeFromHistory())
        #expect(HistoryRepository.shared.config(id: config.id) == nil)
        #expect(!failure.canRemoveFromHistory)
        #expect(await failure.removeFromHistory())
    }

    @Test func newFileFailureCannotRemoveUnrelatedHistory() async {
        let failure = FileOpenFeedback(url: URL(fileURLWithPath: "/tmp/missing.png"), reason: .missing)
        #expect(!failure.canRemoveFromHistory)
        #expect(await failure.removeFromHistory() == false)
    }

    @Test func sourceFilesAreNotRejectedAsExecutables() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(isIncognito: true)
        for ext in ["js", "ts", "sh", "py", "swift"] {
            let url = root.appendingPathComponent("source." + ext)
            try Data("source text".utf8).write(to: url)
            #expect(state.initialFileOpenFailure(url) == nil)
        }
    }

    @Test func distinguishesUnsupportedMissingAndKnownPreviewDocuments() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState()
        let archive = root.appendingPathComponent("installer.dmg")
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
        let archive = root.appendingPathComponent("installer.dmg")
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
        let archive = root.appendingPathComponent("installer.dmg")
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

    @Test(arguments: [false, true])
    func deferredBlankCloseWaitsForAllOpensAndPreservesContent(hasContent: Bool) {
        let delegate = AppDelegate()
        defer {
            NotificationCenter.default.removeObserver(delegate)
            for controller in delegate.windowControllers { controller.close() }
        }
        let state = AppState(isIncognito: true)
        let controller = delegate.showNewWindow(with: state)
        state.beginPendingContentOpen()
        state.beginPendingContentOpen()
        delegate.closeFoilIfStillBlank(controller, for: state)
        #expect(controller.pendingBlankCloseCancellable != nil)

        state.endPendingContentOpen()
        #expect(controller.window?.isVisible == true)
        #expect(controller.pendingBlankCloseCancellable != nil)
        if hasContent { state.text = "Opened content" }
        state.endPendingContentOpen()
        #expect(controller.pendingBlankCloseCancellable == nil)
        #expect(controller.window?.isVisible == hasContent)
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

    @Test(arguments: [true, false], [true, false])
    func missingBorderlessHistoryDoesNotCreateEmptyWindow(cleanupEnabled: Bool, brokenBookmark: Bool) throws {
        let previous = SettingsStore.shared.automaticallyRemoveMissingHistory
        SettingsStore.shared.automaticallyRemoveMissingHistory = cleanupEnabled
        defer { SettingsStore.shared.automaticallyRemoveMissingHistory = previous }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = WindowConfig(id: UUID(), imagePath: root.appendingPathComponent("deleted.png").path,
                                  originalImageName: "deleted.png", showBorder: false,
                                  videoBookmark: brokenBookmark ? Data("broken bookmark".utf8) : nil)
        #expect(HistoryRepository.shared.upsert(config))
        defer { HistoryRepository.shared.remove(id: config.id) }
        let delegate = AppDelegate()
        defer {
            NotificationCenter.default.removeObserver(delegate)
            for controller in delegate.windowControllers { controller.close() }
        }
        let item = NSMenuItem()
        item.representedObject = config
        delegate.openHistoryItemAction(item)
        #expect(delegate.windowControllers.count == 1)
        let feedback = try #require(delegate.windowControllers.first)
        #expect(feedback.appState.isFileOpenFeedback)
        #expect(feedback.appState.showBorder)
        #expect(feedback.appState.imageURL == nil)
        #expect(feedback.appState.textURL == nil)
        #expect((HistoryRepository.shared.config(id: config.id) == nil) == (cleanupEnabled && !brokenBookmark))
    }

    @Test func failedHistoryRestorePreservesExistingWindowContent() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(isIncognito: true)
        state.openText("Keep this note", isMarkdown: false, isClipboard: false)
        let body = try #require(state.textURL)
        defer { try? FileManager.default.removeItem(at: body) }
        let originalID = state.id
        let config = WindowConfig(id: UUID(), imagePath: root.appendingPathComponent("deleted.png").path,
                                  originalImageName: "deleted.png", opacity: 0.2, showBorder: false,
                                  videoBookmark: Data("broken bookmark".utf8))
        #expect(!state.loadConfig(config))
        #expect(state.id == originalID)
        #expect(state.text == "Keep this note")
        #expect(state.textURL == body)
        #expect(state.imageURL == nil)
        #expect(state.showBorder)
        #expect(state.opacity == 1)
        #expect(!state.isBatchUpdating)
    }

    @Test func missingSearchResultPreservesBlankWindowAndShowsOnlyFeedback() throws {
        let previous = SettingsStore.shared.automaticallyRemoveMissingHistory
        SettingsStore.shared.automaticallyRemoveMissingHistory = false
        defer { SettingsStore.shared.automaticallyRemoveMissingHistory = previous }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = WindowConfig(id: UUID(), imagePath: root.appendingPathComponent("deleted.png").path,
                                  originalImageName: "deleted.png", showBorder: false)
        #expect(HistoryRepository.shared.upsert(config))
        defer { HistoryRepository.shared.remove(id: config.id) }
        let delegate = AppDelegate()
        defer {
            NotificationCenter.default.removeObserver(delegate)
            for controller in delegate.windowControllers { controller.close() }
        }
        let blank = delegate.showNewWindow(with: AppState())
        let originalID = blank.appState.id
        delegate.openSearchResultInNewWindow(id: config.id)
        #expect(delegate.windowControllers.count == 2)
        #expect(blank.appState.id == originalID)
        #expect(blank.appState.isBlank)
        #expect(blank.appState.showBorder)
        #expect(delegate.windowControllers.filter { $0.appState.isFileOpenFeedback }.count == 1)
        #expect(HistoryRepository.shared.config(id: config.id) != nil)
    }

}
