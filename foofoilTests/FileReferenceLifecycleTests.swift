import AppKit
import Foundation
import Testing
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct FileReferenceLifecycleTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func fileLocationTracksRenameAndSeparatesUnknownFailures() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.txt")
        try Data("body".utf8).write(to: original)
        let bookmark = try #require(AppState.makeSecurityScopedBookmark(for: original))
        let moved = root.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: original, to: moved)
        let result = FileReference.resolve(original, bookmark: bookmark)
        #expect(result.status == .available)
        #expect(result.url.path == moved.path)
        #expect(FileReference.resolve(original, bookmark: nil).status == .missing)
        #expect(FileReference.resolve(original, bookmark: Data("invalid".utf8)).status == .temporaryFailure)
        #expect(FileReference.resolve(URL(fileURLWithPath: "/Volumes/offline-\(UUID())/file.txt"), bookmark: nil).status == .offline)
    }

    @Test func partialListsKeepAvailableItemsAndHonorDisabledCleanup() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let present = root.appendingPathComponent("present.png")
        try Data([1]).write(to: present)
        let missing = root.appendingPathComponent("missing.png")
        let items = [FileListItem(id: "gone", path: missing.path, bookmark: nil, displayName: "gone"),
                     FileListItem(id: "present", path: present.path, bookmark: nil, displayName: "present")]
        let config = WindowConfig(id: UUID(), imagePath: missing.path, fileList: FileListState(kind: .image, items: items, currentID: "gone"))
        let result = config.resolvingFileReferences()
        #expect(!result.missing)
        #expect(result.config.fileList?.items.map(\.id) == ["present"])
        #expect(result.config.imagePath == present.path)
        #expect(config.resolvingFileReferences(removeMissingItems: false).config.fileList?.items.count == 2)
        try FileManager.default.removeItem(at: present)
        #expect(config.resolvingFileReferences().missing)
        #expect(!WindowConfig(id: UUID(), imagePath: root.appendingPathComponent("missing-screenshot.png").path,
                              webURLString: "https://example.com").resolvingFileReferences().missing)
        #expect(!WindowConfig(id: UUID(), isCamera: true).resolvingFileReferences().missing)
    }

    @Test func repositoryDeletionRejectsWindowAndIndexResurrection() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
        let config = WindowConfig(id: UUID(), text: "searchable unique body")
        #expect(repository.upsert(config))
        repository.remove(id: config.id)
        #expect(!repository.upsert(config))
        repository.replaceChunks(historyID: config.id, chunkKind: 2, chunks: [("resurrect", nil)])
        #expect(repository.config(id: config.id) == nil)
        #expect(await repository.search("resurrect").isEmpty)
    }

    @Test func managedBodyWaitsForAllOwnersAndActiveReaders() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
        let cache = ContentCache(repository: repository, directories: { [root] })
        let body = root.appendingPathComponent("managed_body_\(UUID()).txt")
        try cache.write(Data("content".utf8), to: body)
        let first = WindowConfig(id: UUID(), textPath: body.path)
        let second = WindowConfig(id: UUID(), textPath: body.path)
        #expect(repository.upsert(first))
        #expect(repository.upsert(second))
        cache.protect([first.id], paths: [body.path])
        cache.retain([body.path])
        cache.retire([body.path])
        repository.remove(id: first.id)
        cache.flushCleanup()
        #expect(FileManager.default.fileExists(atPath: body.path))
        repository.remove(id: second.id)
        cache.protect([], paths: [])
        cache.flushCleanup()
        #expect(FileManager.default.fileExists(atPath: body.path))
        cache.release([body.path])
        cache.flushCleanup()
        #expect(!FileManager.default.fileExists(atPath: body.path))
        let external = root.appendingPathComponent("user-original.txt")
        try Data([1]).write(to: external)
        cache.retire([external.path])
        cache.flushCleanup()
        #expect(FileManager.default.fileExists(atPath: external.path))
    }

    @Test func clipboardTextEditsAndHTMLRestoreFromManagedBody() throws {
        let state = AppState()
        let originalRoot = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: originalRoot) }
        let original = originalRoot.appendingPathComponent("original.txt")
        try Data("external".utf8).write(to: original)
        state.openTextFile(url: original)
        let externalConfig = state.toConfig()
        defer { HistoryManager.shared.removeFromHistory(externalConfig) }
        state.openText("first", isMarkdown: false)
        #expect(state.videoBookmarkData == nil)
        let body = try #require(state.textURL)
        #expect(AppState(config: state.toConfig()).text == "first")
        defer {
            HistoryManager.shared.removeFromHistory(state.toConfig())
            try? FileManager.default.removeItem(at: body)
        }
        ContentCache.shared.flushBodyWrites()
        #expect(state.toConfig().isClipboardContent)
        #expect(!state.isReadOnlyTextFile)
        #expect(!state.verticalArrowsScrollContent)
        #expect(FoilInformation.sourceURL(for: state.toConfig()) == nil)
        state.text = "edited"
        state.saveState()
        ContentCache.shared.flushBodyWrites()
        #expect(AppState(config: state.toConfig()).text == "edited")
        state.text = ""
        state.saveState()
        ContentCache.shared.flushBodyWrites()
        #expect(try String(contentsOf: body, encoding: .utf8) == "")
        let html = AppState()
        #expect(html.openHTML("<p>fragment</p>"))
        let htmlURL = try #require(html.webURL)
        defer {
            HistoryManager.shared.removeFromHistory(html.toConfig())
            try? FileManager.default.removeItem(at: htmlURL)
        }
        #expect(html.toConfig().isClipboardContent)
        #expect(try String(contentsOf: htmlURL, encoding: .utf8) == "<p>fragment</p>")
        #expect(AppState(config: html.toConfig()).webURL == htmlURL)
    }

    @Test func cleanupSettingControlsConfirmedMissingRestore() throws {
        let defaults = UserDefaults(suiteName: "history-settings-\(UUID())")!
        #expect(SettingsStore(userDefaults: defaults).automaticallyRemoveMissingHistory)
        let previous = SettingsStore.shared.automaticallyRemoveMissingHistory
        defer { SettingsStore.shared.automaticallyRemoveMissingHistory = previous }
        let config = WindowConfig(id: UUID(), text: "must not restore snapshot", textPath: "/tmp/absent-\(UUID()).txt")
        SettingsStore.shared.automaticallyRemoveMissingHistory = false
        #expect(HistoryRepository.shared.upsert(config))
        let state = AppState(config: config)
        #expect(state.text.isEmpty)
        #expect(HistoryRepository.shared.config(id: config.id) != nil)
        SettingsStore.shared.automaticallyRemoveMissingHistory = true
        state.loadConfig(config)
        #expect(HistoryRepository.shared.config(id: config.id) == nil)
        state.saveState()
        #expect(HistoryRepository.shared.config(id: config.id) == nil)
    }

    @Test func orphanRecoveryKeepsReferencedBodiesAndUniqueLegacyContent() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
        let cache = ContentCache(repository: repository, directories: { [root] })
        let orphan = root.appendingPathComponent("managed_body_\(UUID()).txt")
        let live = root.appendingPathComponent("managed_body_\(UUID()).txt")
        let legacy = root.appendingPathComponent("cached_text_\(UUID()).txt")
        for url in [orphan, live, legacy] {
            try Data("unique".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172800)], ofItemAtPath: url.path)
        }
        #expect(repository.upsert(WindowConfig(id: UUID(), textPath: live.path)))
        cache.recoverOrphanBodies()
        cache.flushCleanup()
        cache.flushCleanup()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        let bodyRoot = root.appendingPathComponent("bodies", isDirectory: true)
        try FileManager.default.createDirectory(at: bodyRoot, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "body-limit-\(UUID())")!
        let bodyCache = ContentCache(repository: repository, defaults: defaults, directories: { [bodyRoot] })
        try bodyCache.setLimit(1)
        let body = bodyRoot.appendingPathComponent("managed_body_\(UUID()).txt")
        try bodyCache.write(Data(repeating: 1, count: 100), to: body)
        #expect(try Data(contentsOf: body).count == 100)
    }

    @Test func unreadableFileIsAuthorizationProblem() throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("restricted.txt")
        try Data([1]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(FileReference.resolve(url, bookmark: nil).status == .authorizationRequired)
    }

    @Test func cleanupCommitRechecksSettingAndChangedSnapshot() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = SettingsStore.shared.automaticallyRemoveMissingHistory
        SettingsStore.shared.automaticallyRemoveMissingHistory = false
        defer { SettingsStore.shared.automaticallyRemoveMissingHistory = previous }
        let repository = HistoryRepository.shared
        let original = WindowConfig(id: UUID(), imagePath: root.appendingPathComponent("missing.png").path)
        #expect(repository.upsert(original))
        defer { repository.remove(id: original.id) }
        let snapshot = try #require(repository.config(id: original.id))
        let result = snapshot.resolvingFileReferences()
        #expect(result.missing)
        HistoryManager.shared.applyFileReferenceResult(snapshot, result: result)
        #expect(repository.config(id: original.id) != nil)
        let present = root.appendingPathComponent("present.png")
        try Data([1]).write(to: present)
        var changed = snapshot
        changed.imagePath = present.path
        #expect(repository.upsert(changed))
        SettingsStore.shared.automaticallyRemoveMissingHistory = true
        HistoryManager.shared.applyFileReferenceResult(snapshot, result: result)
        #expect(repository.config(id: original.id)?.imagePath == present.path)
        let current = try #require(repository.config(id: original.id))
        try FileManager.default.removeItem(at: present)
        HistoryManager.shared.applyFileReferenceResult(current, result: current.resolvingFileReferences())
        #expect(repository.config(id: original.id) == nil)
    }

    @Test func automaticCleanupPreservesUniqueLegacyBody() throws {
        let previous = SettingsStore.shared.automaticallyRemoveMissingHistory
        SettingsStore.shared.automaticallyRemoveMissingHistory = true
        defer { SettingsStore.shared.automaticallyRemoveMissingHistory = previous }
        let root = try #require(AppState.getFoofoilDirectoryURL())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("cached_text_\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: legacy) }
        try Data("only remaining copy".utf8).write(to: legacy)
        let config = WindowConfig(id: UUID(), text: "only remaining copy", textPath: legacy.path,
                                  sourceFingerprint: "file:/tmp/missing-\(UUID()).txt")
        #expect(HistoryRepository.shared.upsert(config))
        let snapshot = try #require(HistoryRepository.shared.config(id: config.id))
        HistoryManager.shared.applyFileReferenceResult(snapshot, result: snapshot.resolvingFileReferences())
        ContentCache.shared.flushCleanup()
        #expect(HistoryRepository.shared.config(id: config.id) == nil)
        #expect(try String(contentsOf: legacy, encoding: .utf8) == "only remaining copy")
    }

    @Test func exportedShareDirectoryWaitsForDescendantReferences() throws {
        let databaseRoot = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: databaseRoot) }
        let support = try #require(AppState.getFoofoilDirectoryURL())
        let group = support.appendingPathComponent("Shared Items/\(UUID())", isDirectory: true)
        let nested = group.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: group) }
        let first = nested.appendingPathComponent("first.txt")
        let second = nested.appendingPathComponent("second.txt")
        for url in [first, second, nested.appendingPathComponent(".metadata")] { try Data([1]).write(to: url) }
        #expect(AppState.isManagedCacheURL(first))
        #expect(FoilInformation.sourceURL(for: WindowConfig(id: UUID(), textPath: first.path)) == nil)
        let repository = HistoryRepository(databaseURL: databaseRoot.appendingPathComponent("history.sqlite"))
        let cache = ContentCache(repository: repository, directories: { [support] })
        let config = WindowConfig(id: UUID(), textPath: second.path)
        #expect(repository.upsert(config))
        cache.retire([first.path])
        cache.flushCleanup()
        #expect(FileManager.default.fileExists(atPath: group.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        repository.remove(id: config.id)
        cache.protect([config.id], paths: [second.path])
        cache.flushCleanup()
        #expect(FileManager.default.fileExists(atPath: group.path))
        cache.protect([], paths: [])
        cache.flushCleanup()
        #expect(!FileManager.default.fileExists(atPath: group.path))
    }

    @Test func privateClipboardHasOnlySessionBody() throws {
        let state = AppState(isIncognito: true)
        state.openText("private", isMarkdown: false)
        let url = try #require(state.textURL)
        defer { try? FileManager.default.removeItem(at: url) }
        ContentCache.shared.flushBodyWrites()
        #expect(url.lastPathComponent.hasPrefix("session_body_"))
        #expect(HistoryRepository.shared.config(id: state.id) == nil)
        #expect(state.toConfig().isClipboardContent)
    }

    @Test func clipboardImageRetainsRepresentationAndFileReferenceWins() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        pasteboard.setData(png, forType: .png)
        pasteboard.setString("https://example.com/image.png", forType: .string)
        pasteboard.setString("<img src='https://example.com/image.png'>", forType: .html)
        let result = try #require(AppDelegate.clipboardImageRepresentation(from: pasteboard))
        #expect(result.data == png)
        #expect(result.ext == "png")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reference.png")
        pasteboard.writeObjects([url as NSURL])
        let delegate = AppDelegate()
        #expect(delegate.clipboardFileURLs(from: pasteboard) == [url])
    }
}
