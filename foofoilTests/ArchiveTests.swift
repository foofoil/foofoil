import AppKit
import Combine
import Testing
import FoofoilExtensionKit
@testable import foofoil

@Suite(.sharedApplicationState)
struct ArchiveTests {
    @Test @MainActor func textPresentationMatchesOrdinaryFiles() async throws {
        let files = [("readme.md", "# 标题\n\n正文 **加粗**"), ("script.js", "const greeting = '你好';\n"), ("data.csv", "name,value\nfoo,1\n")]
        let fixture = try Fixture(files.map { ($0.0, Data($0.1.utf8)) })
        defer { fixture.remove() }
        let owner = AppState(isIncognito: true)
        defer { owner.resetContent() }
        owner.openFile(url: fixture.url)
        let session = try #require(owner.archiveSession)
        try await wait { !session.busy }
        let controller = FloatingWindowController(appState: owner)
        defer { controller.close() }
        for (name, text) in files {
            let externalURL = fixture.directory.appendingPathComponent(name)
            try Data(text.utf8).write(to: externalURL)
            let ordinary = AppState(isIncognito: true)
            ordinary.openFile(url: externalURL)
            defer { ordinary.resetContent() }
            let entry = try #require(session.index?.entries.first { $0.name == name })
            session.select(entry.id)
            try await wait { !session.busy }
            let preview = try #require(session.preview)
            #expect(preview.text == text)
            #expect(preview.text == ordinary.text)
            #expect(preview.isMarkdownPreview == ordinary.isMarkdownPreview)
            #expect(preview.isCSVDocument == ordinary.isCSVDocument)
            #expect(preview.documentThemeId == ordinary.documentThemeId)
            #expect(preview.backgroundColorHex == ordinary.backgroundColorHex)
            #expect(preview.textColorHex == ordinary.textColorHex)
            #expect(preview.textFontSize == ordinary.textFontSize)
            #expect(preview.archiveWindowOwner === owner)
            #expect(owner.readingState === preview)
            owner.showBorder = false
            #expect(!preview.showBorder)
            preview.showBorder = true
            #expect(owner.showBorder)
            owner.isFullScreen = true
            #expect(preview.isFullScreen)
            owner.isFullScreen = false
            // 缩放命令必须修改当前正文，不能落在空的压缩包外壳上。
            let originalSize = preview.textFontSize
            controller.zoomIn()
            #expect(preview.textFontSize > originalSize)
            controller.actualSize()
            #expect(preview.textFontSize == AppState.defaultTextFontSize)
        }
    }

    @Test @MainActor func nestedArchivesLoadOnlyOnExpansionAndStayInOneTree() async throws {
        let deepest = try Fixture([("script.js", Data("const answer = 42;".utf8))])
        defer { deepest.remove() }
        let inner = try Fixture([("deeper.zip", Data(contentsOf: deepest.url)), ("inner.txt", Data("inner".utf8))])
        defer { inner.remove() }
        let outer = try Fixture([("folder/nested.zip", Data(contentsOf: inner.url)), ("unopened.zip", Data("not an archive".utf8)), ("outside.txt", Data("outside".utf8))])
        defer { outer.remove() }
        let owner = AppState(isIncognito: true)
        defer { owner.resetContent() }
        owner.openFile(url: outer.url)
        let archive = try #require(owner.archiveSession)
        try await wait { !archive.busy }
        let entry = try #require(archive.index?.entries.first { $0.name == "nested.zip" })
        let originalItems = archive.contribution.items
        #expect(archive.isArchiveNode(entry.id))
        archive.select(entry.id)
        #expect(!archive.busy && archive.preview == nil)
        #expect(archive.contribution.items == originalItems)
        owner.expandedNavigatorItemIDs.insert(entry.id)
        #expect(archive.isLoadingArchiveNode(entry.id))
        try await wait { !archive.isLoadingArchiveNode(entry.id) }
        #expect(owner.navigatorContributions.count == 1)
        let deeper = try #require(archive.contribution.items.first { $0.title == "deeper.zip" })
        #expect(deeper.parentID == entry.id)
        #expect(archive.isArchiveNode(deeper.id))
        #expect(!archive.contribution.items.contains { $0.title == "script.js" })
        let cachedItems = archive.contribution.items
        owner.expandedNavigatorItemIDs.remove(entry.id)
        owner.expandedNavigatorItemIDs.insert(entry.id)
        #expect(!archive.isLoadingArchiveNode(entry.id))
        #expect(archive.contribution.items == cachedItems)
        owner.expandedNavigatorItemIDs.insert(deeper.id)
        try await wait { !archive.isLoadingArchiveNode(deeper.id) }
        let script = try #require(archive.contribution.items.first { $0.title == "script.js" })
        #expect(script.parentID == deeper.id)
        var observed: AppState?
        let observation = owner.readingStatePublisher.sink { observed = $0 }
        owner.performNavigatorAction(NavigatorAction(contributionID: ArchiveSession.navigatorID, kind: .activate, itemIDs: [script.id]))
        try await wait { !archive.busy }
        #expect(owner.readingState.text == "const answer = 42;")
        #expect(observed === owner.readingState)
        #expect(owner.selectedArchiveSession === archive)
        // 折叠已载入的父包不影响当前正文，目录也不重复提取。
        owner.expandedNavigatorItemIDs.remove(entry.id)
        #expect(owner.readingState.text == "const answer = 42;")
        #expect(archive.contribution.items.contains { $0.id == script.id })
        let other = try #require(archive.index?.entries.first { $0.name == "outside.txt" })
        archive.select(other.id)
        try await wait { !archive.busy }
        #expect(owner.readingState.text == "outside")
        #expect(owner.toConfig().archiveSource?.primaryURL == outer.url)
        #expect(archive.message == nil)
        withExtendedLifetime(observation) {}
    }

    @Test @MainActor func collapsingAncestorCancelsUnfinishedNestedLoadAndCanRetry() async throws {
        let inner = try Fixture([("hello.txt", Data("hello".utf8))])
        defer { inner.remove() }
        let fixture = try Fixture([("folder/nested.zip", Data(contentsOf: inner.url))])
        defer { fixture.remove() }
        let owner = AppState(isIncognito: true)
        defer { owner.resetContent() }
        owner.openFile(url: fixture.url)
        let archive = try #require(owner.archiveSession)
        try await wait { !archive.busy }
        let entry = try #require(archive.index?.entries.first { $0.name == "nested.zip" })
        let folder = try #require(archive.index?.entries.first { $0.path == "folder" })
        owner.expandedNavigatorItemIDs.insert(folder.id)
        owner.expandedNavigatorItemIDs.insert(entry.id)
        #expect(archive.isLoadingArchiveNode(entry.id))
        owner.expandedNavigatorItemIDs.remove(folder.id)
        #expect(!archive.isLoadingArchiveNode(entry.id))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!archive.contribution.items.contains { $0.parentID == entry.id })
        owner.expandedNavigatorItemIDs.remove(entry.id)
        owner.expandedNavigatorItemIDs.insert(folder.id)
        owner.expandedNavigatorItemIDs.insert(entry.id)
        try await wait { !archive.isLoadingArchiveNode(entry.id) }
        #expect(archive.contribution.items.contains { $0.title == "hello.txt" })
        archive.close()
        #expect(!archive.contribution.items.contains { $0.title == "hello.txt" })
    }

    @Test @MainActor func invalidNestedArchiveFailsLocallyAndOuterFileStillOpens() async throws {
        let fixture = try Fixture([("broken.zip", Data("broken".utf8)), ("hello.txt", Data("hello".utf8))])
        defer { fixture.remove() }
        let session = ArchiveSession(source: ArchiveSource(volumes: [.init(path: fixture.url.path)]))
        defer { session.close() }
        session.load()
        try await wait { !session.busy }
        let broken = try #require(session.index?.entries.first { $0.name == "broken.zip" })
        session.setArchiveExpanded(broken.id, expanded: true)
        try await wait { !session.isLoadingArchiveNode(broken.id) }
        #expect(session.contribution.items.first { $0.id == broken.id }?.subtitle != nil)
        #expect(session.index != nil && !session.needsPassword)
        let hello = try #require(session.index?.entries.first { $0.name == "hello.txt" })
        session.select(hello.id)
        try await wait { !session.busy }
        #expect(session.preview?.text == "hello")
    }

    @Test @MainActor func encryptedNestedEntryUsesItsOwnPasswordAndChangedOuterInvalidatesCache() async throws {
        let inner = try Fixture([])
        defer { inner.remove() }
        let encrypted = try #require(Data(base64Encoded: "UEsDBDMAAQhjAAAAAAAAAAAAJQAAABEAAAAFAAsAYS50eHQBmQcAAgBBRQEAAAABAgMEBQYHI2VacSKixx7k3B+RLe4ic8Wk0oEouerOXsjQ6bFQSwECMwAzAAEIYwAAAAAAAAAAACUAAAARAAAABQALAAAAAAAAAAAAAAAAAAAAYS50eHQBmQcAAgBBRQEAAFBLBQYAAAAAAQABAD4AAABTAAAAAAA="))
        try encrypted.write(to: inner.url)
        let outer = try Fixture([("encrypted.zip", encrypted), ("outside.txt", Data("outside".utf8))])
        defer { outer.remove() }
        let session = ArchiveSession(source: ArchiveSource(volumes: [.init(path: outer.url.path)]))
        defer { session.close() }
        session.load()
        try await wait { !session.busy }
        let innerEntry = try #require(session.index?.entries.first { $0.name == "encrypted.zip" })
        session.setArchiveExpanded(innerEntry.id, expanded: true)
        try await wait { !session.isLoadingArchiveNode(innerEntry.id) }
        let file = try #require(session.contribution.items.first { $0.title == "a.txt" })
        session.select(file.id)
        try await wait { !session.busy }
        #expect(session.needsPassword)
        #expect(session.passwordPromptName == "encrypted.zip")
        session.passwordInput = "wrong"
        session.unlock()
        try await wait { !session.busy }
        #expect(session.needsPassword && session.preview == nil)
        session.passwordInput = "archive-test"
        session.unlock()
        try await wait { !session.busy }
        #expect(session.preview?.text == "archive aes test\n")
        let innerIndex = try ArchiveReader.scan(urls: [inner.url])
        let innerFile = try #require(innerIndex.entries.first { $0.isRegular })
        #expect(throws: ArchiveFailure.originalDestination) {
            try ArchiveReader.export(urls: [inner.url], index: innerIndex, entries: [innerFile], selection: innerFile,
                destination: outer.url, basePath: "", password: "archive-test", protectedURLs: [outer.url])
        }
        try Data("changed".utf8).write(to: outer.url)
        session.select(file.id)
        try await wait { !session.busy }
        #expect(session.index == nil, "message: \(String(describing: session.message))")
        #expect(session.preview == nil)
        #expect(session.contribution.items.isEmpty)
    }

    @Test @MainActor func sameNamedNestedArchivesKeepDistinctSources() async throws {
        let first = try Fixture([("same.txt", Data("first".utf8))])
        let second = try Fixture([("same.txt", Data("second".utf8))])
        defer { first.remove(); second.remove() }
        let outer = try Fixture([("a/nested.zip", Data(contentsOf: first.url)), ("b/nested.zip", Data(contentsOf: second.url))])
        defer { outer.remove() }
        let session = ArchiveSession(source: ArchiveSource(volumes: [.init(path: outer.url.path)]))
        defer { session.close() }
        session.load()
        try await wait { !session.busy }
        let archives = try #require(session.index?.entries.filter { $0.name == "nested.zip" })
        for (entry, expected) in zip(archives, ["first", "second"]) {
            session.setArchiveExpanded(entry.id, expanded: true)
            try await wait { !session.isLoadingArchiveNode(entry.id) }
            let item = try #require(session.contribution.items.first { $0.parentID == entry.id && $0.title == "same.txt" })
            session.select(item.id)
            try await wait { !session.busy }
            #expect(session.preview?.text == expected)
        }
        #expect(Set(session.contribution.items.map(\.id)).count == session.contribution.items.count)
    }

    @Test @MainActor func nestingCannotExceedTotalTreeDepth() async throws {
        let path = String(repeating: "dir/", count: ArchiveReader.maximumDepth - 1) + "nested.zip"
        let fixture = try Fixture([(path, Data("unread".utf8))])
        defer { fixture.remove() }
        let session = ArchiveSession(source: ArchiveSource(volumes: [.init(path: fixture.url.path)]))
        defer { session.close() }
        session.load()
        try await wait { !session.busy }
        let item = try #require(session.contribution.items.first { $0.title == "nested.zip" })
        session.setArchiveExpanded(item.id, expanded: true)
        #expect(!session.isLoadingArchiveNode(item.id))
        #expect(session.contribution.items.first { $0.id == item.id }?.subtitle == ArchiveFailure.limit.localizedDescription)
        // 每层路径单独合法，但嵌入原树后超过总深度，也必须拒绝并释放该层目录。
        let deep = try Fixture([(String(repeating: "dir/", count: ArchiveReader.maximumDepth - 1) + "file.txt", Data("text".utf8))])
        defer { deep.remove() }
        let outer = try Fixture([("deep.zip", Data(contentsOf: deep.url))])
        defer { outer.remove() }
        let second = ArchiveSession(source: ArchiveSource(volumes: [.init(path: outer.url.path)]))
        defer { second.close() }
        second.load()
        try await wait { !second.busy }
        let node = try #require(second.contribution.items.first { $0.title == "deep.zip" })
        second.setArchiveExpanded(node.id, expanded: true)
        try await wait { !second.isLoadingArchiveNode(node.id) }
        #expect(second.contribution.items.count == 2)
        #expect(second.contribution.items.first { $0.id == node.id }?.subtitle == ArchiveFailure.limit.localizedDescription)
    }

    @Test @MainActor func previewFailureRefreshesArchivePresentation() async throws {
        let fixture = try Fixture([("file.txt", Data("hello".utf8))])
        defer { fixture.remove() }
        let session = ArchiveSession(source: ArchiveSource(volumes: [.init(path: fixture.url.path)]))
        defer { session.close() }
        session.load()
        try await wait { !session.busy }
        let entry = try #require(session.index?.entries.first { $0.isRegular })
        session.select(entry.id)
        try await wait { !session.busy }
        let preview = try #require(session.preview)
        // 模拟系统对未知类型异步返回不支持，父视图必须离开内部空白阅读器。
        preview.text = ""
        preview.textURL = nil
        var refreshed = false
        let observation = session.objectWillChange.sink { refreshed = true }
        preview.reportFileOpenFeedback([.init(url: fixture.url, reason: .unsupported)])
        try await wait { refreshed }
        #expect(preview.isFileOpenFeedback)
        withExtendedLifetime(observation) {}
    }

    @Test func pathsRejectEscapesAndExcessiveDepth() throws {
        for path in ["/etc/passwd", "../a", "a/../../b", "C:\\test", "a\\..\\b", "\0bad", String(repeating: "a/", count: 129)] {
            #expect(throws: ArchiveFailure.self) { try ArchiveReader.safePath(path) }
        }
        #expect(try ArchiveReader.safePath("./目录//file.txt") == "目录/file.txt")
    }

    @Test func treePreservesImplicitDirectoriesEmptyFoldersAndDuplicates() throws {
        let fixture = try Fixture([( "目录/hello.txt", Data("hello".utf8)), ("empty/", Data()), ("same.txt", Data([1])), ("same.txt", Data([2])), ("a/", Data()), ("a#4/n.txt", Data([3]))])
        defer { fixture.remove() }
        let index = try ArchiveReader.scan(urls: [fixture.url])
        #expect(index.entries.first?.id == "root")
        #expect(Set(index.entries.map(\.id)).count == index.entries.count)
        #expect(index.entries.contains { $0.path == "目录" && $0.isDirectory })
        #expect(index.entries.contains { $0.path == "empty" && $0.isDirectory })
        let duplicates = index.entries.filter { $0.path == "same.txt" }
        #expect(duplicates.count == 2)
        #expect(Set(duplicates.map(\.id)).count == 2)
        for (offset, entry) in duplicates.enumerated() {
            let output = fixture.directory.appendingPathComponent("out\(offset)")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            _ = try ArchiveReader.extract(urls: [fixture.url], index: index, entries: [entry], root: output, basePath: "", password: nil, limit: 10)
            #expect(try Data(contentsOf: output.appendingPathComponent("same.txt")) == Data([UInt8(offset + 1)]))
        }
        let output = fixture.directory.appendingPathComponent("all")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        #expect(throws: ArchiveFailure.self) {
            try ArchiveReader.extract(urls: [fixture.url], index: index, entries: index.entries, root: output, basePath: "", password: nil, limit: 100)
        }
    }

    @Test func changedSourceAndLimitsDoNotSucceed() throws {
        let fixture = try Fixture([("a.txt", Data(repeating: 65, count: 100))])
        defer { fixture.remove() }
        let index = try ArchiveReader.scan(urls: [fixture.url])
        let output = fixture.directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        #expect(throws: ArchiveFailure.self) {
            try ArchiveReader.extract(urls: [fixture.url], index: index, entries: index.entries, root: output, basePath: "", password: nil, limit: 50)
        }
        try Data([1]).write(to: fixture.url)
        #expect(throws: ArchiveFailure.self) {
            try ArchiveReader.extract(urls: [fixture.url], index: index, entries: index.entries, root: output, basePath: "", password: nil, limit: 1000)
        }
    }

    @Test func unsafeArchiveAndCaseCollisionsFail() throws {
        let unsafe = try Fixture([("../escape.txt", Data([1]))])
        defer { unsafe.remove() }
        #expect(throws: ArchiveFailure.self) { try ArchiveReader.scan(urls: [unsafe.url]) }
        let fixture = try Fixture([("A.txt", Data([1])), ("a.txt", Data([2]))])
        defer { fixture.remove() }
        let index = try ArchiveReader.scan(urls: [fixture.url])
        let output = fixture.directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        #expect(throws: ArchiveFailure.self) { try ArchiveReader.extract(urls: [fixture.url], index: index, entries: index.entries, root: output, basePath: "", password: nil, limit: 1000) }
    }

    @Test func directoryExportIncludesEmptyFoldersAndOriginalBytes() throws {
        let fixture = try Fixture([("parent/empty/", Data()), ("parent/sub/中文.txt", Data("original\r\n".utf8))])
        defer { fixture.remove() }
        let index = try ArchiveReader.scan(urls: [fixture.url])
        let output = fixture.directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try ArchiveReader.extract(urls: [fixture.url], index: index, entries: index.entries.filter { $0.path.hasPrefix("parent") }, root: output, basePath: "parent", password: nil, limit: 1000)
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("empty").path))
        #expect(try Data(contentsOf: output.appendingPathComponent("sub/中文.txt")) == Data("original\r\n".utf8))
    }

    @Test @MainActor func historyPersistsOnlyOriginalSourceAndRestoresUnselected() async throws {
        let fixture = try Fixture([("a.md", Data("# hello".utf8)), ("b.txt", Data("second".utf8))])
        defer { fixture.remove() }
        let state = AppState(isIncognito: true)
        state.openFile(url: fixture.url)
        let archive = try #require(state.archiveSession)
        try await wait { !archive.busy }
        #expect(archive.selected == nil)
        let entry = try #require(archive.index?.entries.first { $0.path == "a.md" })
        archive.select(entry.id)
        try await wait { !archive.busy }
        #expect(archive.preview?.isArchivePreview == true)
        #expect(archive.preview?.isIncognito == true)
        try await wait { archive.preview?.navigatorContributions.contains { $0.id == AppState.markdownOutlineNavigatorID } == true }
        #expect(state.navigatorContributions.contains { $0.id == ArchiveSession.navigatorID })
        #expect(state.navigatorContributions.count == 1)
        #expect(!state.navigatorContributions.contains { $0.id == AppState.markdownOutlineNavigatorID })
        let config = state.toConfig()
        #expect(config.imagePath == fixture.url.path)
        #expect(config.text.isEmpty && config.textPath == nil && config.extensionID == nil)
        #expect(config.contentKind == .archive)
        let repository = HistoryRepository(databaseURL: fixture.directory.appendingPathComponent("history.sqlite"))
        #expect(repository.upsert(config))
        let restored = try #require(repository.config(id: config.id))
        #expect(restored.archiveSource == config.archiveSource)
        let reopened = AppState(config: restored, isIncognito: true)
        #expect(reopened.archiveSession != nil)
        #expect(reopened.archiveSession?.selected == nil)
        #expect(reopened.archiveSession?.preview == nil)
        #expect(reopened.imageURL == nil)
        reopened.resetContent()
        state.resetContent()
    }

    @Test @MainActor func fastSwitchAndCloseDiscardPendingPreview() async throws {
        let fixture = try Fixture([("one.txt", Data("one".utf8)), ("two.txt", Data("two".utf8))])
        defer { fixture.remove() }
        let session = ArchiveSession(source: ArchiveSource(volumes: [.init(path: fixture.url.path)]))
        session.load()
        try await wait { !session.busy }
        let one = try #require(session.index?.entries.first { $0.path == "one.txt" })
        let two = try #require(session.index?.entries.first { $0.path == "two.txt" })
        session.select(one.id)
        session.select(two.id)
        try await wait { !session.busy }
        #expect(session.preview?.text == "two")
        session.select(one.id)
        session.close()
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.preview == nil)
    }

    @Test func failedExportPreservesExistingDestinationAndSuccessfulExportCommitsOriginalBytes() throws {
        let fixture = try Fixture([("a.txt", Data(repeating: 65, count: 100))])
        defer { fixture.remove() }
        let index = try ArchiveReader.scan(urls: [fixture.url])
        let entry = try #require(index.entries.first { $0.isRegular })
        let destination = fixture.directory.appendingPathComponent("existing.txt")
        let original = Data("keep me".utf8)
        try original.write(to: destination)
        #expect(throws: ArchiveFailure.self) {
            try ArchiveReader.export(urls: [fixture.url], index: index, entries: [entry], selection: entry,
                destination: destination, basePath: "", password: nil, limit: 50)
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(throws: ArchiveFailure.self) {
            try ArchiveReader.export(urls: [fixture.url], index: index, entries: [entry], selection: entry,
                destination: fixture.url, basePath: "", password: nil)
        }
        _ = try ArchiveReader.export(urls: [fixture.url], index: index, entries: [entry], selection: entry,
            destination: destination, basePath: "", password: nil, limit: 1000)
        #expect(try Data(contentsOf: destination) == Data(repeating: 65, count: 100))
        #expect(throws: ArchiveFailure.self) {
            try ArchiveReader.export(urls: [fixture.url], index: index, entries: index.entries,
                selection: index.entries[0], destination: fixture.directory, basePath: "", password: nil)
        }
    }

    @Test @MainActor func closingPreservesOriginalHistoryConfiguration() async throws {
        let fixture = try Fixture([("a.txt", Data("hello".utf8))])
        defer { fixture.remove() }
        let state = AppState(isIncognito: true)
        state.openFile(url: fixture.url)
        state.endExtensionSessionOnWindowClose()
        #expect(state.toConfig().contentKind == .archive)
        #expect(state.toConfig().imagePath == fixture.url.path)
        state.resetContent()
    }

    @Test func zipAESPasswordsAndAuthentication() throws {
        // 自有固定盐 AES-128/256 样本，正文为 archive aes test\n；密码仅为测试数据。
        for encoded in [
            "UEsDBDMAAQhjAAAAAAAAAAAAJQAAABEAAAAFAAsAYS50eHQBmQcAAgBBRQEAAAABAgMEBQYHI2VacSKixx7k3B+RLe4ic8Wk0oEouerOXsjQ6bFQSwECMwAzAAEIYwAAAAAAAAAAACUAAAARAAAABQALAAAAAAAAAAAAAAAAAAAAYS50eHQBmQcAAgBBRQEAAFBLBQYAAAAAAQABAD4AAABTAAAAAAA=",
            "UEsDBDMAAQhjAAAAAAAAAAAALQAAABEAAAAFAAsAYS50eHQBmQcAAgBBRQMAAAABAgMEBQYHCAkKCwwNDg8NoNSYNJO2cCIU7duWTkbPW6r6G7Qhc3XKmV9ZklBLAQIzADMAAQhjAAAAAAAAAAAALQAAABEAAAAFAAsAAAAAAAAAAAAAAAAAAABhLnR4dAGZBwACAEFFAwAAUEsFBgAAAAABAAEAPgAAAFsAAAAAAA=="
        ] {
            let fixture = try Fixture([])
            defer { fixture.remove() }
            try #require(Data(base64Encoded: encoded)).write(to: fixture.url)
            let index = try ArchiveReader.scan(urls: [fixture.url])
            let entry = try #require(index.entries.first { $0.isRegular })
            #expect(entry.encrypted)
            for password in [nil, "wrong", "archive-test"] as [String?] {
                let output = fixture.directory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                if password == "archive-test" {
                    _ = try ArchiveReader.extract(urls: [fixture.url], index: index, entries: [entry], root: output, basePath: "", password: password, limit: 100)
                    #expect(try Data(contentsOf: output.appendingPathComponent("a.txt")) == Data("archive aes test\n".utf8))
                } else {
                    #expect(throws: ArchiveFailure.self) { try ArchiveReader.extract(urls: [fixture.url], index: index, entries: [entry], root: output, basePath: "", password: password, limit: 100) }
                }
            }
        }
    }

    @Test @MainActor func imagePreviewBorrowsCacheURLWithoutRecursiveRecaching() async throws {
        let image = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j2ioAAAAASUVORK5CYII="))
        let fixture = try Fixture([("image.png", image)])
        defer { fixture.remove() }
        let session = ArchiveSession(source: ArchiveSource(volumes: [.init(path: fixture.url.path)]))
        session.load()
        try await wait { !session.busy }
        let entry = try #require(session.index?.entries.first { $0.isRegular })
        session.select(entry.id)
        try await wait { !session.busy }
        let preview = try #require(session.preview)
        let url = try #require(preview.imageURL)
        #expect(url.deletingLastPathComponent() == preview.archivePreviewLease?.directory)
        #expect(!AppState.isManagedCacheURL(url))
        preview.imageURL = url
        #expect(preview.imageURL == url)
        session.close()
    }

    @Test @MainActor func replacingArchiveRotatesIdentity() throws {
        let fixture = try Fixture([("a.txt", Data("archive".utf8))])
        defer { fixture.remove() }
        let state = AppState(isIncognito: true)
        state.openFile(url: fixture.url)
        let archiveID = state.id
        state.openText("replacement", isMarkdown: false)
        #expect(state.archiveSession == nil)
        #expect(state.id != archiveID)
        #expect(state.toConfig().contentKind != .archive)
        state.resetContent()
    }

    @Test @MainActor func encryptedPreviewRetriesAndCancellationStayInSession() async throws {
        let fixture = try Fixture([])
        defer { fixture.remove() }
        try #require(Data(base64Encoded: "UEsDBDMAAQhjAAAAAAAAAAAAJQAAABEAAAAFAAsAYS50eHQBmQcAAgBBRQEAAAABAgMEBQYHI2VacSKixx7k3B+RLe4ic8Wk0oEouerOXsjQ6bFQSwECMwAzAAEIYwAAAAAAAAAAACUAAAARAAAABQALAAAAAAAAAAAAAAAAAAAAYS50eHQBmQcAAgBBRQEAAFBLBQYAAAAAAQABAD4AAABTAAAAAAA=")).write(to: fixture.url)
        let session = ArchiveSession(source: ArchiveSource(volumes: [.init(path: fixture.url.path)]))
        session.load()
        try await wait { !session.busy }
        let entry = try #require(session.index?.entries.first { $0.isRegular })
        session.select(entry.id)
        try await wait { !session.busy }
        #expect(session.needsPassword)
        session.passwordInput = "wrong"
        session.unlock()
        try await wait { !session.busy }
        #expect(session.needsPassword && session.preview == nil)
        session.cancelUnlock()
        #expect(!session.needsPassword && session.passwordInput.isEmpty)
        session.select(entry.id)
        try await wait { !session.busy }
        session.passwordInput = "archive-test"
        session.unlock()
        try await wait { !session.busy }
        #expect(session.preview?.text == "archive aes test\n")
        #expect(!session.needsPassword && session.passwordInput.isEmpty)
        session.close()
    }

    @Test func rarVolumeRequiresTerminalEndMarkerEvenWhenAllPresentFilesAreComplete() throws {
        let fixture = try Fixture([])
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("group.part01.rar")
        func littleEndian(_ value: UInt32) -> Data {
            var value = value.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        func header(_ body: Data) -> Data {
            let payload = Data([UInt8(body.count)]) + body
            return littleEndian(PPTXCRC32.checksum(payload)) + payload
        }
        let bytes = Data("complete".utf8)
        // 自建 RAR5 Store 条目；Unix 属性 0100644 使用 vint 编码，ENDARC bit 0 表示还有后续卷。
        let fileHeader = Data([2, 2, 8, 4, 8, 0xa4, 0x83, 2]) + littleEndian(PPTXCRC32.checksum(bytes)) + Data([0, 1, 5]) + Data("a.txt".utf8)
        let prefix = Data([0x52, 0x61, 0x72, 0x21, 0x1a, 7, 1, 0]) + header(Data([1, 0, 1])) + header(fileHeader) + bytes
        try (prefix + header(Data([5, 4, 0]))).write(to: source)
        let index = try ArchiveReader.scan(urls: [source])
        #expect(index.entries.contains { $0.path == "a.txt" && $0.isRegular })
        try (prefix + header(Data([5, 4, 1]))).write(to: source)
        #expect(throws: ArchiveFailure.self) { try ArchiveReader.scan(urls: [source]) }
    }

    @Test func leaseDeletesOnlyOwnedPreviewDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var lease: ArchivePreviewLease? = ArchivePreviewLease(directory: root)
        #expect(lease?.directory == root)
        lease = nil
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func formatsExcludeContainerDocuments() {
        for ext in ["zip", "tar", "tgz", "gz", "7z", "rar", "7z.001"] { #expect(ArchiveReader.recognizes(URL(fileURLWithPath: "sample." + ext))) }
        for ext in ["epub", "pptx", "docx", "xlsx"] { #expect(!ArchiveReader.recognizes(URL(fileURLWithPath: "sample." + ext))) }
    }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Archive operation timed out")
    }

    nonisolated struct Fixture {
        let directory: URL
        let url: URL
        init(_ files: [(String, Data)]) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            url = directory.appendingPathComponent("fixture.zip")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var local = Data(), central = Data()
            func bytes(_ values: [(UInt64, Int)]) -> Data {
                var result = Data()
                for (value, count) in values { for index in 0..<count { result.append(UInt8(truncatingIfNeeded: value >> (index * 8))) } }
                return result
            }
            for (path, data) in files {
                let name = Data(path.utf8), offset = local.count
                let crc = UInt64(PPTXCRC32.checksum(data)), size = UInt64(data.count), length = UInt64(name.count)
                local += bytes([(0x04034b50,4),(20,2),(0x800,2),(0,2),(0,2),(0,2),(crc,4),(size,4),(size,4),(length,2),(0,2)]) + name + data
                central += bytes([(0x02014b50,4),(20,2),(20,2),(0x800,2),(0,2),(0,2),(0,2),(crc,4),(size,4),(size,4),(length,2),(0,2),(0,2),(0,2),(0,2),(path.hasSuffix("/") ? 16 : 0,4),(UInt64(offset),4)]) + name
            }
            let count = UInt64(files.count)
            try (local + central + bytes([(0x06054b50,4),(0,2),(0,2),(count,2),(count,2),(UInt64(central.count),4),(UInt64(local.count),4),(0,2)])).write(to: url)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
