import AppKit
import Testing
import FoofoilExtensionKit
@testable import foofoil

@MainActor @Suite(.sharedApplicationState)
struct ArchiveContainerTests {
    @Test func renamedZIPContainersUseTheArchiveReader() async throws {
        let fixture = try ArchiveTests.Fixture([("resources/script.js", Data("const value = 42;".utf8))])
        defer { fixture.remove() }
        for ext in ["apk", "jar", "war", "ear", "cbz", "kra"] {
            let url = fixture.directory.appendingPathComponent("container.\(ext)")
            try FileManager.default.copyItem(at: fixture.url, to: url)
            let state = AppState(isIncognito: true)
            defer { state.resetContent() }
            #expect(state.initialFileOpenFailure(url) == nil)
            state.openFile(url: url)
            let session = try #require(state.archiveSession)
            try await wait { !session.busy }
            let entry = try #require(session.index?.entries.first { $0.name == "script.js" })
            session.select(entry.id)
            try await wait { !session.busy }
            #expect(session.preview?.text == "const value = 42;")
        }
        for ext in ["cbr", "cb7", "cbt", "iso"] {
            #expect(ArchiveReader.recognizes(fixture.directory.appendingPathComponent("container.\(ext)")))
        }
        #expect(!ArchiveReader.recognizes(fixture.directory.appendingPathComponent("disk.dmg")))
    }

    @Test func documentsKeepPreviewAndOpenSeparatePackageState() async throws {
        let fixture = try ArchiveTests.Fixture([("word/document.xml", Data("<document/>".utf8))])
        defer { fixture.remove() }
        for ext in ["docx", "xlsx", "pptx", "docm", "odt", "epub"] {
            let url = fixture.directory.appendingPathComponent("document.\(ext)")
            try FileManager.default.copyItem(at: fixture.url, to: url)
            #expect(!ArchiveReader.recognizes(url))
            #expect(ArchiveReader.supportsPackageContents(url))
            let reader = AppState(isIncognito: true)
            defer { reader.resetContent() }
            // EPUB 会话的实际资源走同一菜单解析路径，普通 Quick Look 文档直接打开。
            if ext == "epub" {
                reader.imageURL = url
                reader.originalImageName = url.lastPathComponent
                reader.sourceFingerprint = AppState.localSourceFingerprint(for: url)
            }
            else { reader.openFile(url: url) }
            #expect(reader.archiveSession == nil)
            #expect(reader.packageContentsURL == url)
            let id = reader.id
            let package = try #require(try await reader.makePackageContentsState())
            defer { package.resetContent() }
            let session = try #require(package.archiveSession)
            try await wait { !session.busy }
            #expect(session.index?.entries.contains { $0.path == "word/document.xml" } == true)
            #expect(package.id != reader.id && reader.id == id)
            #expect(reader.archiveSession == nil)
            #expect(package.toConfig().contentKind == .archive)
            #expect(package.toConfig().originalImageName == url.lastPathComponent)
            let restored = AppState(config: package.toConfig(), isIncognito: true)
            defer { restored.resetContent() }
            #expect(restored.archiveSession?.source.name == url.lastPathComponent)
        }
        for ext in ["doc", "xls", "ppt", "pdf", "dmg"] {
            #expect(!ArchiveReader.supportsPackageContents(fixture.directory.appendingPathComponent("file.\(ext)")))
        }
    }

    @Test func packageMenuUsesAvailableResourceWhenOriginalPathMoved() throws {
        let fixture = try ArchiveTests.Fixture([])
        defer { fixture.remove() }
        let url = fixture.directory.appendingPathComponent("moved.docx")
        try FileManager.default.copyItem(at: fixture.url, to: url)
        let reader = AppState(isIncognito: true)
        defer { reader.resetContent() }
        reader.openFile(url: url)
        reader.sourceFingerprint = "file:/missing/original.docx"
        #expect(reader.packageContentsURL == url)
    }

    @Test func previewAndPackageHistoryDeduplicateIndependently() async throws {
        let fixture = try ArchiveTests.Fixture([])
        defer { fixture.remove() }
        let repository = HistoryRepository(databaseURL: fixture.directory.appendingPathComponent("history.sqlite3"))
        for (name, kind) in [("book.epub", HistoryContentKind.ebook), ("report.docx", .quickLook)] {
            let source = fixture.directory.appendingPathComponent(name)
            try Data("source".utf8).write(to: source)
            let fingerprint = "file:\(source.path)"
            var previewIDs: [UUID] = [], packageIDs: [UUID] = []
            for _ in 0..<3 {
                let preview = WindowConfig(id: UUID(), imagePath: source.path, originalImageName: name,
                                           contentKind: kind, sourceFingerprint: fingerprint)
                let package = WindowConfig(id: UUID(), imagePath: source.path, originalImageName: name,
                                           contentKind: .archive, sourceFingerprint: fingerprint,
                                           archiveSource: ArchiveSource(volumes: [.init(path: source.path)]))
                #expect(repository.upsert(preview))
                #expect(repository.upsert(package))
                // 包窗口的再次保存也不能删除仍然打开的预览记录。
                #expect(repository.upsert(package))
                previewIDs.append(preview.id); packageIDs.append(package.id)
            }
            let history = repository.recent().filter { $0.sourceFingerprint == fingerprint }
            #expect(history.count == 2)
            #expect(Set(history.map(\.id)) == Set([previewIDs.last!, packageIDs.last!]))
            #expect(history.first { $0.contentKind == .archive }?.archiveSource?.primaryURL == source)
            #expect(history.first { $0.contentKind == kind }?.archiveSource == nil)
            #expect((await repository.search(name)).count == 2)
        }
    }

    @Test func iso9660OpensWithoutMountingAndNestedISOExpands() async throws {
        let fixture = try ArchiveTests.Fixture([("disc.iso", Self.iso9660())])
        defer { fixture.remove() }
        let iso = fixture.directory.appendingPathComponent("ordinary.iso")
        try Self.iso9660().write(to: iso)
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        #expect(!FileListGrouper.isSACDISOFile(iso))
        state.openFile(url: iso)
        let session = try #require(state.archiveSession)
        try await wait { !session.busy }
        let entry = try #require(session.index?.entries.first { $0.name.lowercased() == "hello.txt" })
        session.select(entry.id)
        try await wait { !session.busy }
        #expect(session.preview?.text == "Hello ISO\n")
        let output = fixture.directory.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let index = try #require(session.index)
        _ = try ArchiveReader.extract(urls: [iso], index: index, entries: [entry], root: output, basePath: "", password: nil, limit: 1024)
        #expect(try Data(contentsOf: output.appendingPathComponent(entry.path)) == Data("Hello ISO\n".utf8))
        state.openFile(url: fixture.url)
        let outer = try #require(state.archiveSession)
        try await wait { !outer.busy }
        let nested = try #require(outer.index?.entries.first { $0.name == "disc.iso" })
        #expect(outer.isArchiveNode(nested.id))
        outer.select(nested.id)
        try await wait { !outer.busy }
        #expect(outer.preview == nil)
        #expect(!outer.contribution.items.contains { $0.title.lowercased() == "hello.txt" })
        state.expandedNavigatorItemIDs.insert(nested.id)
        try await wait { !outer.isLoadingArchiveNode(nested.id) }
        let inner = try #require(outer.contribution.items.first { $0.title.lowercased() == "hello.txt" })
        outer.select(inner.id)
        try await wait { !outer.busy }
        #expect(outer.preview?.text == "Hello ISO\n")
    }

    @Test func sacdProbeWinsOverArchiveIncludingNestedISO() async throws {
        let provider = ArchiveSACDProbeProvider()
        ExtensionHost.shared.resolver.register(provider)
        defer { ExtensionHost.shared.resolver.unregister(providerID: provider.descriptor.id) }
        var sacd = Data(repeating: 0, count: 511 * 2048)
        sacd.replaceSubrange((510 * 2048)..<(510 * 2048 + 8), with: Data("SACDMTOC".utf8))
        let fixture = try ArchiveTests.Fixture([("album.iso", sacd)])
        defer { fixture.remove() }
        let url = fixture.directory.appendingPathComponent("album.iso")
        try sacd.write(to: url)
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        #expect(FileListGrouper.isSACDISOFile(url))
        state.openFile(url: url)
        try await wait { !state.isLoading }
        #expect(state.archiveSession == nil)
        #expect(state.extensionSession?.providerID == provider.descriptor.id)
        state.openFile(url: fixture.url)
        let session = try #require(state.archiveSession)
        try await wait { !session.busy }
        let entry = try #require(session.index?.entries.first { $0.name == "album.iso" })
        // 即使首先点展开，识别后也会回到音频叶节点，不把 SACD 当损坏的文件镜像。
        state.expandedNavigatorItemIDs.insert(entry.id)
        try await wait { !session.isLoadingArchiveNode(entry.id) }
        #expect(!session.isArchiveNode(entry.id))
        session.select(entry.id)
        try await wait { !session.busy && session.preview?.isLoading == false }
        #expect(session.preview?.archiveSession == nil)
        #expect(session.preview?.extensionSession?.providerID == provider.descriptor.id)
    }

    @Test(arguments: [true, false]) func packageFromNestedDocumentOwnsTemporarySource(_ privateMode: Bool) async throws {
        let document = try ArchiveTests.Fixture([("word/document.xml", Data("<document/>".utf8))])
        defer { document.remove() }
        let fixture = try ArchiveTests.Fixture([("report.docx", Data(contentsOf: document.url))])
        defer { fixture.remove() }
        let owner = AppState(isIncognito: privateMode)
        owner.openFile(url: fixture.url)
        let ownerID = owner.id
        defer {
            owner.resetContent()
            if !privateMode { HistoryRepository.shared.remove(id: ownerID) }
        }
        let session = try #require(owner.archiveSession)
        try await wait { !session.busy }
        let entry = try #require(session.index?.entries.first { $0.name == "report.docx" })
        #expect(!session.isArchiveNode(entry.id))
        session.select(entry.id)
        try await wait { !session.busy }
        var preview: AppState? = session.preview
        #expect(preview != nil)
        let packageState = try await preview?.makePackageContentsState()
        let package = try #require(packageState)
        let packageID = package.id
        let source = try #require(package.archiveSession?.source.primaryURL)
        defer {
            package.resetContent()
            if !privateMode {
                HistoryRepository.shared.remove(id: packageID)
                try? FileManager.default.removeItem(at: source)
            }
        }
        #expect(package.isIncognito == privateMode)
        #expect(package.archiveSession?.sourceLease != nil)
        #expect(!AppState.isManagedCacheURL(source))
        #expect(package.toConfig().originalImageName == "report.docx")
        #expect(HistoryRepository.shared.config(id: packageID) == nil)
        owner.resetContent()
        preview = nil
        try await wait { package.archiveSession?.busy == false }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(package.archiveSession?.index?.entries.contains { $0.path == "word/document.xml" } == true)
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Container operation timed out")
    }

    /// 自建最小 ISO 9660，含双端序元数据、路径表、根目录和一个正文文件。
    nonisolated static func iso9660() -> Data {
        var image = Data(repeating: 0, count: 24 * 2048)
        func put(_ offset: Int, _ data: Data) { image.replaceSubrange(offset..<(offset + data.count), with: data) }
        func both(_ value: UInt32, width: Int) -> Data {
            Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
                 + (0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func record(_ name: Data, sector: UInt32, size: UInt32, directory: Bool) -> Data {
            var result = Data(repeating: 0, count: 33 + name.count + (name.count.isMultiple(of: 2) ? 1 : 0))
            result[0] = UInt8(result.count)
            result.replaceSubrange(2..<10, with: both(sector, width: 4))
            result.replaceSubrange(10..<18, with: both(size, width: 4))
            result.replaceSubrange(18..<25, with: Data([126, 10, 16, 0, 0, 0, 0]))
            result[25] = directory ? 2 : 0
            result.replaceSubrange(28..<32, with: both(1, width: 2))
            result[32] = UInt8(name.count)
            result.replaceSubrange(33..<(33 + name.count), with: name)
            return result
        }
        let root = record(Data([0]), sector: 20, size: 2048, directory: true)
        put(16 * 2048, Data([1]) + Data("CD001".utf8) + Data([1]))
        put(16 * 2048 + 8, Data(repeating: 32, count: 64))
        put(16 * 2048 + 80, both(24, width: 4))
        put(16 * 2048 + 120, both(1, width: 2) + both(1, width: 2) + both(2048, width: 2))
        put(16 * 2048 + 132, both(10, width: 4))
        put(16 * 2048 + 140, Data([18, 0, 0, 0]))
        put(16 * 2048 + 148, Data([0, 0, 0, 19]))
        put(16 * 2048 + 156, root)
        put(16 * 2048 + 881, Data([1]))
        put(17 * 2048, Data([255]) + Data("CD001".utf8) + Data([1]))
        put(18 * 2048, Data([1, 0, 20, 0, 0, 0, 1, 0, 0, 0]))
        put(19 * 2048, Data([1, 0, 0, 0, 0, 20, 0, 1, 0, 0]))
        let text = Data("Hello ISO\n".utf8)
        put(20 * 2048, root + record(Data([1]), sector: 20, size: 2048, directory: true)
            + record(Data("HELLO.TXT;1".utf8), sector: 21, size: UInt32(text.count), directory: false))
        put(21 * 2048, text)
        return image
    }
}

@MainActor private final class ArchiveSACDProbeProvider: ContentProvider {
    let descriptor = ProviderDescriptor(id: "test.archive-sacd", extensionID: "test.archive-sacd", role: .primary,
                                        fallbackProviderID: nil, enhancementDomain: nil, contentFamily: .audio,
                                        filenameExtensions: ["iso"], isEnabled: true, isRuntimeAvailable: true)
    func match(_ request: ContentRequest) -> ProviderMatch? {
        ProviderContentMatcher.match(request, declarations: [.init(extensions: ["iso"], strategy: .sniff)]) { url in
            guard let file = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? file.close() }
            try? file.seek(toOffset: 510 * 2048)
            return (try? file.read(upToCount: 8)) == Data("SACDMTOC".utf8)
        }
    }
    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        ContentSession(extensionID: descriptor.extensionID, providerID: descriptor.id, request: request,
                       presentation: .text(titleKey: "Test", body: "SACD"))
    }
}
