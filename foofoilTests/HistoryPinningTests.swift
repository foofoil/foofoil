import Foundation
import SQLite3
import Testing
@testable import foofoil

@MainActor
struct HistoryPinningTests {
    private func makeRepository() throws -> (URL, HistoryRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite")))
    }

    @Test func pinSurvivesStaleWindowSavesAndRestartWithoutReordering() throws {
        let (root, repository) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = WindowConfig(id: UUID(), text: "First", isPinned: true)
        let second = WindowConfig(id: UUID(), text: "Second")
        #expect(repository.upsert(first))
        #expect(repository.upsert(second))
        let order = repository.recent().map(\.id)
        let dates = try #require(repository.visitDates(id: first.id))
        #expect(repository.setPinned(id: first.id, pinned: true))
        #expect(repository.recent().map(\.id) == order)
        #expect(repository.visitDates(id: first.id)?.last == dates.last)
        #expect(repository.upsert(first)) // 活跃窗口仍拿着未钉住的旧快照。
        let reopened = HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
        #expect(reopened.config(id: first.id)?.historyIsPinned == true)
        #expect(reopened.config(id: first.id)?.isPinned == true)
        #expect(reopened.setPinned(id: first.id, pinned: false))
        #expect(reopened.config(id: first.id)?.historyIsPinned == false)
        #expect(reopened.config(id: first.id)?.isPinned == true)
        #expect(reopened.config(id: first.id) != nil)
    }

    @Test func exposeIncludesOldPinsBeyondRecentLimitWithoutReordering() throws {
        let (root, repository) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let pin = WindowConfig(id: UUID(), text: "Old pin", historyIsPinned: true)
        let ordinary = WindowConfig(id: UUID(), text: "Older ordinary")
        let recent = WindowConfig(id: UUID(), text: "Recent")
        for config in [pin, ordinary, recent] { #expect(repository.upsert(config)) }
        #expect(repository.recent(limit: 1).map(\.id) == [recent.id])
        #expect(repository.recent(limit: 1, includingPinned: true).map(\.id) == [recent.id, pin.id])
        #expect(repository.setPinned(id: pin.id, pinned: false))
        #expect(repository.recent(limit: 1, includingPinned: true).map(\.id) == [recent.id])
    }

    @Test func migrationAndMissingJSONFieldDefaultToUnpinned() throws {
        let (root, repository) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = WindowConfig(id: UUID(), text: "Existing", isPinned: true)
        #expect(repository.upsert(config))
        var connection: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("history.sqlite").path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        #expect(sqlite3_exec(connection, "ALTER TABLE history_items DROP COLUMN history_is_pinned; PRAGMA user_version = 23;", nil, nil, nil) == SQLITE_OK)
        let migrated = HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
        #expect(migrated.initializationError == nil)
        #expect(migrated.config(id: config.id)?.historyIsPinned == false)
        #expect(migrated.config(id: config.id)?.isPinned == true)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        object.removeValue(forKey: "historyIsPinned")
        let decoded = try JSONDecoder().decode(WindowConfig.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!decoded.historyIsPinned)
    }

    @Test func clearRetainsPinsAndActiveRecordsButExplicitDeleteRemovesPin() throws {
        let (root, repository) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let pin = WindowConfig(id: UUID(), text: "Keep", historyIsPinned: true)
        let ordinary = WindowConfig(id: UUID(), text: "Clear")
        let active = WindowConfig(id: UUID(), text: "Open")
        for config in [pin, ordinary, active] { #expect(repository.upsert(config)) }
        let cache = ContentCache(repository: repository, directories: { [root] })
        let manager = HistoryManager(repository: repository, contentCache: cache, cacheDirectories: { [root] })
        manager.clearHistory(preserving: [active])
        #expect(Set(repository.recent().map(\.id)) == [pin.id, active.id])
        #expect(!repository.wasDeleted(pin.id))
        #expect(repository.wasDeleted(ordinary.id))
        #expect(repository.setPinned(id: pin.id, pinned: false))
        #expect(repository.config(id: pin.id) != nil)
        #expect(repository.setPinned(id: pin.id, pinned: true))
        manager.removeFromHistory(pin)
        #expect(repository.config(id: pin.id) == nil)
    }

    @Test func searchPinBonusBreaksTiesButNeverBeatsStrongerTextMatch() async throws {
        let (root, repository) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let pin = WindowConfig(id: UUID(), text: "alpha", historyIsPinned: true, customTitle: "Other")
        let normal = WindowConfig(id: UUID(), text: "alpha", customTitle: "Other")
        let exact = WindowConfig(id: UUID(), text: "Body", customTitle: "alpha")
        for config in [pin, normal, exact] { #expect(repository.upsert(config)) }
        #expect(await repository.search("alpha").map(\.id) == [exact.id, pin.id, normal.id])
        #expect(repository.setPinned(id: pin.id, pinned: false))
        #expect(await repository.search("alpha").map(\.id) == [exact.id, normal.id, pin.id])
    }

    @Test func newRecordDoesNotInheritPinOrAutomaticallyDeleteProtectedRecord() throws {
        let (root, repository) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        for isWeb in [false, true] {
            let first = WindowConfig(id: UUID(), webURLString: isWeb ? "https://example.com" : nil,
                                     text: "Content", historyIsPinned: true, contentKind: isWeb ? .web : .text,
                                     sourceFingerprint: isWeb ? nil : "file:/tmp/source.txt")
            #expect(repository.upsert(first))
            let next = WindowConfig(id: UUID(), webURLString: first.webURLString, text: first.text,
                                contentKind: first.contentKind, sourceFingerprint: first.sourceFingerprint)
            #expect(repository.upsert(next))
            #expect(repository.config(id: first.id)?.historyIsPinned == true)
            #expect(repository.config(id: next.id)?.historyIsPinned == false)
            let third = WindowConfig(id: UUID(), webURLString: first.webURLString, text: first.text,
                                     contentKind: first.contentKind, sourceFingerprint: first.sourceFingerprint)
            #expect(repository.upsert(third))
            #expect(repository.config(id: next.id) == nil)
            #expect(repository.config(id: first.id)?.historyIsPinned == true)
        }
    }

    @Test func missingSourceAndRetiredSharedBodyRemainWhilePinned() throws {
        let (root, repository) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = root.appendingPathComponent("cached_text_shared.txt")
        try Data("Content".utf8).write(to: body)
        let pin = WindowConfig(id: UUID(), text: "Keep", historyIsPinned: true, textPath: body.path)
        let ordinary = WindowConfig(id: UUID(), text: "Remove", textPath: body.path)
        for config in [pin, ordinary] { #expect(repository.upsert(config)) }
        let cache = ContentCache(repository: repository, directories: { [root] })
        let manager = HistoryManager(repository: repository, contentCache: cache, cacheDirectories: { [root] })
        manager.applyFileReferenceResult(pin, result: (pin, true))
        manager.removeFromHistory(pin, preservingLegacyBody: true)
        #expect(repository.config(id: pin.id)?.historyIsPinned == true)
        manager.clearHistory(preserving: [])
        cache.retire([body.path])
        cache.flushCleanup()
        #expect(FileManager.default.fileExists(atPath: body.path))
        #expect(repository.config(id: ordinary.id) == nil)
        #expect(throws: CocoaError.self) { try cache.setLimit(1) }
        #expect(FileManager.default.fileExists(atPath: body.path))
        manager.removeFromHistory(pin)
        cache.flushCleanup()
        #expect(!FileManager.default.fileExists(atPath: body.path))
    }

    @Test func exposePinnedFilterKeepsHistoryOrderAndCombinesWithCategory() {
        func item(_ title: String, pinned: Bool, kind: HistoryContentKind = .text) -> FoilExposeItem {
            FoilExposeItem(id: UUID(), controller: nil, isHistoryEntry: true, title: title,
                           symbolName: kind.symbolName, contentKind: kind, thumbnailPath: nil, historyIsPinned: pinned)
        }
        let first = item("First", pinned: true)
        let normal = item("Normal", pinned: false)
        let last = item("Last", pinned: true, kind: .image)
        let model = FoilExposeModel(items: [], historyItems: [first, normal, last],
                                    fileSearch: { _, _ in }, cancelFiles: {}, musicEnabled: { false })
        model.pinnedOnly = true
        #expect(model.currentItems.map(\.id) == [first.id, last.id])
        model.historyCategory = .documents
        #expect(model.currentItems.map(\.id) == [first.id])
        model.historyCategory = .all
        var unpinned = first
        unpinned.historyIsPinned = false
        model.refreshItems(open: [], history: [unpinned, normal, last])
        #expect(model.currentItems.map(\.id) == [last.id])
        model.pinnedOnly = false
        #expect(model.currentItems.map(\.id) == [first.id, normal.id, last.id])
        let configs = [WindowConfig(id: first.id, text: "pin", historyIsPinned: true),
                       WindowConfig(id: normal.id, text: "ordinary")]
        #expect(FoilExposeModel.historyToClear(configs, category: .all, openIDs: []).map(\.id) == [normal.id])
    }
}
