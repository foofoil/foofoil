import Foundation
import Testing
@testable import foofoil

@MainActor
struct FoilInformationTests {
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
