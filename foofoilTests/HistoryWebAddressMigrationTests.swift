import Foundation
import SQLite3
import Testing
@testable import foofoil

@MainActor
struct HistoryWebAddressMigrationTests {
    @Test func upgradeReindexesLegacyFullWebAddressMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite3")
        let id = UUID()
        let repository = HistoryRepository(databaseURL: databaseURL)
        #expect(repository.upsert(WindowConfig(
            id: id,
            webURLString: "https://example.com/docs?token=secret#intro",
            originalImageName: "Docs",
            contentKind: .web
        )))

        // 模拟 v28：元数据块和 FTS 仍保存完整地址。
        let legacy = "https://example.com/docs?token=secret#intro"
        var connection: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        #expect(sqlite3_exec(connection, """
            UPDATE search_chunks SET original_text = '\(legacy)', normalized_text = '\(legacy)'
            WHERE history_id = '\(id.uuidString)' AND chunk_kind = 0;
            PRAGMA user_version = 28;
            """, nil, nil, nil) == SQLITE_OK)
        #expect(repository.rebuildSearchIndex())

        let migrated = HistoryRepository(databaseURL: databaseURL)
        #expect(migrated.initializationError == nil)
        #expect(await migrated.search("example.com/docs").map(\.id) == [id])
        #expect(await migrated.search("https").isEmpty)
        #expect(await migrated.search("token=secret").isEmpty)
        #expect(await migrated.search("intro").isEmpty)
    }
}
