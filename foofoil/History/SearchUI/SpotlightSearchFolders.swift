import Foundation

/// 仅保存用户通过系统面板选择的目录书签；每次查询和打开分别持有并释放访问。
@MainActor
final class SpotlightSearchFolders {
    static let shared = SpotlightSearchFolders()
    private let defaults: UserDefaults
    private let key = "spotlightSearchFolderBookmarks"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var hasFolders: Bool { !(defaults.array(forKey: key) as? [Data] ?? []).isEmpty }

    func replace(with urls: [URL]) throws {
        let bookmarks = try urls.map { try $0.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) }
        defaults.set(bookmarks, forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }

    func beginAccess() throws -> [URL] {
        let bookmarks = defaults.array(forKey: key) as? [Data] ?? []
        var urls: [URL] = []
        var refreshed: [Data] = []
        do {
            for data in bookmarks {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else {
                    throw CocoaError(.fileReadNoPermission)
                }
                urls.append(url)
                refreshed.append(stale ? try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) : data)
            }
            if refreshed != bookmarks { defaults.set(refreshed, forKey: key) }
            return urls
        } catch {
            urls.forEach { $0.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
}
