import AppKit
import Testing
import FoofoilExtensionKit
@testable import foofoil

@MainActor @Suite(.sharedApplicationState, .serialized)
struct CollectionSidebarTests {
    @Test func folderAudioBorderToggleSynchronizesPreviewAndWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("track.mp3")
        let secondAudio = directory.appendingPathComponent("track2.mp3")
        try Data().write(to: audio)
        try Data().write(to: secondAudio)
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFileCollection([audio, secondAudio], roots: [directory])
        let session = try #require(state.archiveSession)
        try await settle(session)
        session.setSidebarMode(.audio)
        try await settle(session)
        let preview = state.readingState
        #expect(preview !== state && preview.isAudioDocument)
        state.showBorder = true
        let controller = FloatingWindowController(appState: state)
        defer { controller.close() }
        let window = try #require(controller.window)
        let initialSize = window.frame.size
        for _ in 0..<3 {
            state.showBorder = false
            #expect(!state.showBorder && !preview.showBorder)
            #expect(window.frame.size == initialSize)
            preview.showBorder = true
            #expect(state.showBorder && preview.showBorder)
            #expect(window.frame.size == initialSize)
        }
    }

    private func fixture() throws -> (URL, [URL]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let urls = [directory.appendingPathComponent("one.png"), nested.appendingPathComponent("two.png"), nested.appendingPathComponent("note.txt")]
        try png.write(to: urls[0]); try png.write(to: urls[1])
        try "collection note".write(to: urls[2], atomically: true, encoding: .utf8)
        return (directory, urls)
    }

    private func settle(_ session: ArchiveSession) async throws {
        for _ in 0..<300 {
            if !session.busy { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Collection did not settle")
    }

    @Test(arguments: [("png", CollectionSidebarMode.image), ("mp3", .audio), ("mp4", .video)])
    func dominantMediaIsSelectedForDirectories(_ ext: String, _ expected: CollectionSidebarMode) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (0..<3).map { directory.appendingPathComponent("\($0).\(ext)") }
            + [directory.appendingPathComponent("other.txt")]
        for url in urls { try Data().write(to: url) }
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFileCollection(urls, roots: [directory])
        let session = try #require(state.archiveSession)
        try await settle(session)
        #expect(session.sidebarMode == expected)
        session.setSidebarMode(.folder)
        session.load()
        try await settle(session)
        #expect(session.sidebarMode == .folder)
    }

    @Test func dominantMediaIsSelectedForArchives() async throws {
        let (directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: directory.appendingPathComponent("one.png"), to: directory.appendingPathComponent("three.png"))
        let zip = directory.appendingPathComponent("collection.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", "-r", zip.path, "one.png", "three.png", "nested"]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFile(url: zip)
        let session = try #require(state.archiveSession)
        try await settle(session)
        #expect(session.sidebarMode == .image)
        #expect(state.readingState.fileList?.items.count == 3)
    }

    @Test(arguments: [false, true]) func dominantImageProducesFolderHistoryArtwork(archive: Bool) async throws {
        let (directory, urls) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let third = directory.appendingPathComponent("three.png")
        try FileManager.default.copyItem(at: urls[0], to: third)
        let state = AppState(isIncognito: false)
        defer {
            state.resetContent()
            if let config = HistoryRepository.shared.config(id: state.id) { HistoryManager.shared.removeFromHistory(config) }
        }
        if archive {
            let zip = directory.appendingPathComponent("images.zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = directory
            process.arguments = ["-q", "-r", zip.path, "one.png", "three.png", "nested"]
            try process.run(); process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            state.openFile(url: zip)
        } else {
            state.openFileCollection(urls + [third], roots: [directory])
        }
        let session = try #require(state.archiveSession)
        try await settle(session)
        for _ in 0..<300 {
            if HistoryRepository.shared.config(id: state.id)?.thumbnailPath != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let config = try #require(HistoryRepository.shared.config(id: state.id))
        #expect(config.archiveSource?.dominantMediaMode == .image)
        #expect(config.historyMenuSymbolName == CollectionSidebarMode.image.folderHistorySymbol)
        let path = try #require(config.thumbnailPath)
        #expect(NSImage(contentsOfFile: path) != nil)
        session.setSidebarMode(.folder)
        #expect(state.toConfig().archiveSource?.dominantMediaMode == .image)
    }

    @Test func mixedFilesKeepTheirTreeAndSwitchToAnImageList() async throws {
        let (directory, urls) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        #expect(state.handleDroppedFileURLs(urls))
        let session = try #require(state.archiveSession)
        try await settle(session)
        #expect(session.sidebarMode == .folder)
        #expect(session.source.localFiles?.count == 3)
        #expect(session.contribution.items.contains { $0.title == "nested" && $0.parentID == "root" })
        #expect(session.availableSidebarModes == [.folder, .image])
        let note = try #require(session.contribution.items.first { $0.title == "note.txt" })
        #expect(session.canOpenInNewFoil(note.id))
        session.select(note.id)
        #expect(state.readingState.text == "collection note")
        session.setSidebarMode(.image)
        try await settle(session)
        let list = try #require(state.readingState.fileList)
        #expect(list.items.count == 2)
        #expect(list.currentID == list.items.first?.id)
        #expect(state.navigatorContributions.first?.id == AppState.fileListNavigatorID)
        #expect(state.supportsItemNavigation)
        state.activateAdjacentFileListItem(delta: 1)
        #expect(state.readingState.fileList?.currentID == list.items.last?.id)
        session.setSidebarMode(.folder)
        #expect(session.contribution.items.contains { $0.id == note.id })
        #expect(state.readingState.text == "collection note")
    }

    @Test func directoryHistoryRestoresSidebarModeThroughSQLite() async throws {
        let (directory, urls) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFileCollection(urls, roots: [directory])
        let session = try #require(state.archiveSession)
        try await settle(session)
        session.setSidebarMode(.image)
        try await settle(session)
        let config = try JSONDecoder().decode(WindowConfig.self, from: JSONEncoder().encode(state.toConfig()))
        let database = try HistoryDatabase(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        try database.upsert(config)
        let saved = try #require(try database.config(id: state.id))
        #expect(saved.archiveSource?.sidebarMode == .image)
        let restored = AppState(config: saved, isIncognito: true)
        defer { restored.resetContent() }
        let restoredSession = try #require(restored.archiveSession)
        try await settle(restoredSession)
        #expect(restoredSession.sidebarMode == .image)
        #expect(restored.readingState.fileList?.items.count == 2)
        #expect(restored.readingState.fileList?.currentID == restored.readingState.fileList?.items.first?.id)
    }

    @Test func archiveMediaModeExtractsAListAndPreservesItsTree() async throws {
        let (directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = directory.appendingPathComponent("collection.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", "-r", zip.path, "one.png", "nested"]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFile(url: zip)
        let session = try #require(state.archiveSession)
        try await settle(session)
        let tree = session.contribution.items
        session.setSidebarMode(.image)
        try await settle(session)
        let list = try #require(state.readingState.fileList)
        #expect(list.items.count == 2)
        #expect(list.currentID == list.items.first?.id)
        #expect(list.items.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        session.setSidebarMode(.folder)
        #expect(session.contribution.items == tree)
    }

    @Test func changingBackToTreeCancelsPendingMediaPreparation() async throws {
        let (directory, urls) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFileCollection(urls)
        let session = try #require(state.archiveSession)
        try await settle(session)
        session.setSidebarMode(.image)
        session.setSidebarMode(.folder)
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.sidebarMode == .folder)
        #expect(session.preview == nil)
        #expect(!session.busy)
        #expect(session.displayedContributions.first?.style == .outline)
    }

    @Test func localCollectionsExpandArchivesWithoutConfusingFileOrdinals() async throws {
        let (directory, urls) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = directory.appendingPathComponent("nested.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", zip.path, "nested/note.txt"]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFileCollection([urls[0], zip])
        let session = try #require(state.archiveSession)
        try await settle(session)
        let entry = try #require(session.contribution.items.first { $0.title == "nested.zip" })
        session.setArchiveExpanded(entry.id, expanded: true)
        for _ in 0..<300 {
            if !session.isLoadingArchiveNode(entry.id) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let note = try #require(session.contribution.items.first { $0.title == "note.txt" })
        session.select(note.id)
        try await settle(session)
        #expect(state.readingState.text == "collection note")
    }

    @Test func openingArchiveFileInNewFoilKeepsAnIndependentManagedCopy() async throws {
        let (directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = directory.appendingPathComponent("standalone.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", zip.path, "nested/note.txt"]
        try process.run(); process.waitUntilExit()
        let delegate = try #require(NSApp.delegate as? AppDelegate)
        let existing = Set(delegate.windowControllers.map { $0.appState.id })
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFile(url: zip)
        let session = try #require(state.archiveSession)
        try await settle(session)
        let note = try #require(session.contribution.items.first { $0.title == "note.txt" })
        session.openInNewFoil(note.id)
        for _ in 0..<300 {
            if delegate.windowControllers.contains(where: { !existing.contains($0.appState.id) }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let controller = try #require(delegate.windowControllers.first { !existing.contains($0.appState.id) })
        defer { controller.appState.resetContent(); controller.close() }
        let opened = controller.appState
        #expect(opened.isIncognito)
        #expect(opened.text == "collection note")
        let path = try #require(opened.textURL)
        #expect(AppState.isManagedCacheURL(path))
        state.resetContent()
        #expect(FileManager.default.fileExists(atPath: path.path))
        let restored = AppState(config: opened.toConfig(), isIncognito: true)
        defer { restored.resetContent() }
        #expect(restored.text == "collection note")
    }

    @Test func mixedDirectoryRetainsUnsupportedFilesWithoutOfferingStandaloneOpen() async throws {
        let (directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsupported = directory.appendingPathComponent("installer.dmg")
        try Data([0, 1]).write(to: unsupported)
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        #expect(state.handleDroppedFileURLs([directory]))
        for _ in 0..<300 {
            if state.archiveSession != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let session = try #require(state.archiveSession)
        try await settle(session)
        #expect(session.source.localFiles?.count == 4)
        let entry = try #require(session.contribution.items.first { $0.title == "installer.dmg" })
        #expect(!session.canOpenInNewFoil(entry.id))
    }

    @Test func archiveMediaRowsResolveToTheirOriginalEntries() async throws {
        let (directory, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let zip = directory.appendingPathComponent("collection.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", "-r", zip.path, "one.png", "nested"]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.openFile(url: zip)
        let session = try #require(state.archiveSession)
        try await settle(session)
        session.setSidebarMode(.image)
        try await settle(session)
        let item = try #require(state.readingState.fileList?.items.last)
        #expect(state.navigatorFileItem(contributionID: AppState.fileListNavigatorID, itemID: item.id)?.path == item.path)
        let id = try #require(session.mediaEntryID(for: item.url))
        let details = try #require(try await session.fileInformation(id))
        #expect(details.rows.contains { $0.key == "Foil Info Title" && $0.value == item.displayName })
        #expect(details.rows.contains { $0.key == "Foil Info File Path" && $0.value.contains("collection.zip/") })
        #expect(details.rows.contains { $0.key == "Foil Info Pixels" })
        #expect(details.source == nil)
        #expect(!details.rows.contains { ["Foil Info Window Size", "Foil Info First Visit", "Foil Info Last Visit"].contains($0.key) })
    }

    @Test func homogeneousFilesKeepExistingGrouping() {
        #expect(!AppState.needsCollectionTree([URL(fileURLWithPath: "/one.png"), URL(fileURLWithPath: "/two.jpg")]))
        #expect(AppState.needsCollectionTree([URL(fileURLWithPath: "/one.pdf"), URL(fileURLWithPath: "/two.txt")]))
    }

    @Test func homogeneousDirectoryKeepsFolderIdentity() async throws {
        let (directory, urls) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.removeItem(at: urls[2])
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        #expect(state.handleDroppedFileURLs([directory]))
        for _ in 0..<300 {
            if state.archiveSession != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let session = try #require(state.archiveSession)
        try await settle(session)
        #expect(session.source.dominantMediaMode == .image)
        #expect(state.toConfig().isFolderCollection)
    }
}
