import Foundation
import Testing
@testable import foofoil

@MainActor
struct FoilInformationTests {
    @Test func cameraAndEmptyFoilsRejectTitleChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let configs = [WindowConfig(id: UUID()),
                       WindowConfig(id: UUID(), text: " \n ", contentKind: .note),
                       WindowConfig(id: UUID(), isCamera: true, contentKind: .camera),
                       WindowConfig(id: UUID(), imagePath: "/tmp/frame.png", contentKind: .camera)]
        for config in configs {
            #expect(!config.canRenameTitle)
            #expect(repository.upsert(config))
            repository.rename(id: config.id, title: "Rejected")
            #expect(repository.config(id: config.id)?.customTitle == nil)
            let state = AppState(config: config)
            state.applyFoilTitle("Rejected")
            #expect(state.customTitle == nil)
        }
        #expect(WindowConfig(id: UUID(), textPath: "/tmp/empty.txt").canRenameTitle)
        #expect(WindowConfig(id: UUID(), text: "Content").canRenameTitle)
    }

    @Test func renamedHistoryPreservesSourcesAndSurvivesSaveAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let repository = HistoryRepository(databaseURL: url)
        let configs = [
            WindowConfig(id: UUID(), imagePath: "/tmp/source.png", originalImageName: "source.png", imageSource: .clipboard, contentKind: .image),
            WindowConfig(id: UUID(), webURLString: "https://example.com", originalImageName: "Original page", contentKind: .web),
            WindowConfig(id: UUID(), originalImageName: "source.csv", text: "a,b", textPath: "/tmp/source.csv", contentKind: .csv),
            WindowConfig(id: UUID(), originalImageName: "source.md", text: "# Heading", contentKind: .markdown),
            WindowConfig(id: UUID(), contentKind: .terminal, terminalConfiguration: .init())
        ]
        for config in configs {
            #expect(repository.upsert(config))
            let originalTitle = try #require(repository.config(id: config.id)).historyMenuDisplayName
            repository.rename(id: config.id, title: "  自定义标题  ")
            let renamed = try #require(repository.config(id: config.id))
            #expect(renamed.customTitle == "自定义标题")
            #expect(renamed.historyMenuDisplayName == "自定义标题")
            #expect(renamed.originalImageName == config.originalImageName)
            #expect(renamed.contentKind == config.contentKind)
            #expect(renamed.textPath == config.textPath)
            #expect(renamed.webURLString == config.webURLString)
            #expect(repository.upsert(renamed))
            let reopened = HistoryRepository(databaseURL: url)
            #expect(reopened.config(id: config.id)?.historyMenuDisplayName == "自定义标题")
            repository.rename(id: config.id, title: "  ")
            #expect(repository.config(id: config.id)?.customTitle == nil)
            #expect(repository.config(id: config.id)?.historyMenuDisplayName == originalTitle)
        }
        #expect((await repository.search("自定义标题")).isEmpty)
    }

    @Test func activeTitleRoundTripsWithoutChangingFilenameAndResetClearsIt() throws {
        let state = AppState()
        state.isBatchUpdating = true
        state.originalImageName = "source.csv"
        state.text = "a,b"
        state.applyFoilTitle(" 自定义标题 ")
        let config = state.toConfig()
        #expect(config.historyMenuDisplayName == "自定义标题")
        #expect(config.originalImageName == "source.csv")
        let decoded = try JSONDecoder().decode(WindowConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.customTitle == "自定义标题")
        let restored = AppState(config: decoded)
        #expect(restored.toConfig().historyMenuDisplayName == "自定义标题")
        #expect(restored.originalImageName == "source.csv")
        state.applyFoilTitle("  ")
        #expect(state.customTitle == nil)
        state.applyFoilTitle("Reset me")
        state.resetContent()
        #expect(state.customTitle == nil)
    }

    @Test func prefersOriginalSourceOverCacheAndRejectsCacheSource() throws {
        let cache = try #require(AppState.getFoofoilDirectoryURL()).appendingPathComponent("cached_image_test.pdf")
        let original = URL(fileURLWithPath: "/Users/example/Documents/original.pdf")
        let config = WindowConfig(id: UUID(), imagePath: cache.path, sourceFingerprint: "file:\(original.path)")
        #expect(FoilInformation.sourceURL(for: config) == original)
        let cachedConfig = WindowConfig(id: UUID(), imagePath: cache.path)
        #expect(FoilInformation.sourceURL(for: cachedConfig) == nil)
    }

    @Test func missingOriginalRetainsPathAndReportsUnavailableSize() async throws {
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = WindowConfig(id: UUID(), sourceFingerprint: "file:\(original.path)")
        #expect(FoilInformation.sourceURL(for: config) == original)
        let metadata = await FoilInformation.fileRows(source: original, contentURL: nil, kind: .pdf)
        #expect(!metadata.available)
        #expect(metadata.rows.contains { $0.key == "Foil Info File Status" })
        #expect(metadata.rows.contains { $0.key == "Foil Info File Size" })
    }

    @Test func visitsPersistAndWebDeduplicationKeepsFirstVisit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let oldID = UUID()
        #expect(repository.upsert(WindowConfig(id: oldID, webURLString: "https://example.com", createdAt: first)))
        let newID = UUID()
        #expect(repository.upsert(WindowConfig(id: newID, webURLString: "https://example.com", createdAt: Date())))
        let dates = try #require(repository.visitDates(id: newID))
        #expect(dates.first == first)
        repository.touch(id: newID)
        #expect(try #require(repository.visitDates(id: newID)).last >= dates.last)
        let reopened = HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        #expect(reopened.visitDates(id: newID)?.first == first)
    }
}
