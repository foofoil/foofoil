import Foundation
import Testing
@testable import foofoil

@MainActor
struct ContentCacheTests {
    @Test func defaultLimit() {
        let defaults = UserDefaults(suiteName: "cache-test-\(UUID())")!
        #expect(SettingsStore(userDefaults: defaults).contentCacheLimitBytes == 2 * 1024 * 1024 * 1024)
    }

    @Test func leastRecentlyVisitedRecordIsRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "cache-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
        let cache = ContentCache(repository: repository, defaults: defaults, directories: { [root] })
        let oldID = UUID(), recentID = UUID()
        let old = root.appendingPathComponent("cached_text_\(oldID).txt")
        let recent = root.appendingPathComponent("cached_text_\(recentID).txt")
        try Data(repeating: 1, count: 60).write(to: old)
        try Data(repeating: 2, count: 60).write(to: recent)
        #expect(repository.upsert(WindowConfig(id: oldID, text: "old", textPath: old.path)))
        #expect(repository.upsert(WindowConfig(id: recentID, text: "recent", textPath: recent.path)))
        repository.touch(id: oldID)
        #expect(cache.usage == 120)
        // 最近访问 old，应该清除 recent。
        try cache.setLimit(100)
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: recent.path))
        #expect(repository.config(id: recentID) == nil)
        #expect(cache.usage == 60)
        let new = root.appendingPathComponent("cached_text_\(UUID()).txt")
        try cache.write(Data(repeating: 3, count: 50), to: new)
        #expect(cache.usage == 50)
        #expect(repository.config(id: oldID) == nil)
    }

    @Test func confirmationAndInsufficientSpacePreserveExistingCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "cache-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
        let cache = ContentCache(repository: repository, defaults: defaults, directories: { [root] })
        let id = UUID()
        let file = root.appendingPathComponent("cached_text_\(id).txt")
        try cache.write(Data(repeating: 1, count: 60), to: file)
        #expect(repository.upsert(WindowConfig(id: id, text: "active", textPath: file.path)))
        #expect(throws: ContentCache.LimitError.self) { try cache.setLimit(40, allowClearing: false) }
        #expect(cache.usage == 60)
        #expect(defaults.object(forKey: ContentCache.limitKey) == nil)
        cache.protect([id])
        #expect(throws: CocoaError.self) { try cache.setLimit(40) }
        try cache.setLimit(100)
        #expect(throws: CocoaError.self) { try cache.write(Data(repeating: 2, count: 101), to: file) }
        #expect(try Data(contentsOf: file) == Data(repeating: 1, count: 60))
        #expect(repository.config(id: id) != nil)
    }
}
