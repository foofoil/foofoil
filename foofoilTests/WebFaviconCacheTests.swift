import Foundation
import Testing
@testable import foofoil

@MainActor
struct WebFaviconCacheTests {
    @Test func cachePathsAreStableAndSeparateForEachHistoryItem() {
        let id = UUID()
        #expect(WebFaviconCache.path(for: id) == WebFaviconCache.path(for: id))
        #expect(WebFaviconCache.path(for: id) != WebFaviconCache.path(for: UUID()))
    }

    @Test func nonWebIconDoesNotCreateCacheFile() async {
        let id = UUID()
        await WebFaviconCache.cache(iconURL: URL(fileURLWithPath: "/tmp/favicon.png"), historyID: id)
        #expect(!FileManager.default.fileExists(atPath: WebFaviconCache.path(for: id)))
    }
}
