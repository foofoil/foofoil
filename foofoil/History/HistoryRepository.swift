import Foundation

nonisolated public final class HistoryRepository: @unchecked Sendable {
    public static let shared = HistoryRepository()

    private let mutationLock = NSRecursiveLock()
    private var deletedIDs: Set<UUID> = []
    private let database: HistoryDatabase?
    public let initializationError: Error?

    init(databaseURL: URL? = nil) {
        do {
            database = try HistoryDatabase(databaseURL: databaseURL)
            initializationError = nil
        } catch {
            database = nil
            initializationError = error
            NSLog("历史数据库初始化失败：%@", error.localizedDescription)
        }
    }

    @discardableResult
    public func upsert(_ config: WindowConfig) -> Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        guard !deletedIDs.contains(config.id), let database else { return false }
        do { try database.upsert(config); return true }
        catch { NSLog("历史保存失败：%@", error.localizedDescription); return false }
    }

    func fileCheckBatch(after id: UUID?, limit: Int = 32) -> [WindowConfig] {
        (try? database?.fileCheckBatch(after: id, limit: limit)) ?? []
    }

    public func recent(limit: Int = 30, includingPinned: Bool = false) -> [WindowConfig] {
        guard let database else { return [] }
        do {
            return try database.recent(limit: limit, includingPinned: includingPinned)
        }
        catch { NSLog("最近历史读取失败：%@", error.localizedDescription); return [] }
    }

    public func config(id: UUID) -> WindowConfig? {
        guard let database else { return nil }
        return try? database.config(id: id)
    }

    func visitDates(id: UUID) -> (first: Date, last: Date)? {
        try? database?.visitDates(id: id)
    }

    public func touch(id: UUID) { try? database?.touch(id: id) }
    public func remove(id: UUID) { _ = remove(ids: [id]) }
    public func updateThumbnailPath(id: UUID, path: String) { try? database?.updateThumbnailPath(id: id, path: path) }

    @discardableResult
    func remove(ids: Set<UUID>) -> Bool {
        guard let database else { return false }
        mutationLock.lock()
        defer { mutationLock.unlock() }
        do {
            try database.remove(ids: ids)
            deletedIDs.formUnion(ids)
            return true
        }
        catch { NSLog("批量删除历史失败：%@", error.localizedDescription); return false }
    }

    public func removeAll(excluding ids: Set<UUID>) {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let removed = Set(recent(limit: Int.max).filter { !$0.historyIsPinned }.map(\.id)).subtracting(ids)
        do { try database?.removeAll(excluding: ids); deletedIDs.formUnion(removed) }
        catch { NSLog("历史清除失败：%@", error.localizedDescription) }
    }

    @discardableResult
    public func setPinned(id: UUID, pinned: Bool) -> Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        guard let database, !deletedIDs.contains(id), config(id: id) != nil else { return false }
        do { try database.setPinned(id: id, pinned: pinned); return true }
        catch { NSLog("历史钉住失败：%@", error.localizedDescription); return false }
    }

    public func wasDeleted(_ id: UUID) -> Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return deletedIDs.contains(id)
    }
    public func rename(id: UUID, title: String) { try? database?.rename(id: id, title: title) }
    public var searchDatabaseSize: Int64 { database?.searchDatabaseSize() ?? 0 }

    @discardableResult
    public func rebuildSearchIndex() -> Bool {
        do { try database?.rebuildSearchIndex(); return database != nil }
        catch { NSLog("搜索索引重建失败：%@", error.localizedDescription); return false }
    }

    public func replaceChunks(historyID: UUID, chunkKind: Int, chunks: [(String, Int?)], completed: Bool = true) {
        do { try database?.replaceChunks(historyID: historyID, chunkKind: chunkKind, chunks: chunks, completed: completed) }
        catch { try? database?.markIndex(id: historyID, status: 3, error: error.localizedDescription) }
    }

    public func search(_ query: String, limit: Int = 10) async -> [HistorySearchResult] {
        guard let database else { return [] }
        let keywords = SearchTextNormalizer.keywords(query)
        guard !keywords.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            do {
                let groups = try keywords.map { keyword in
                    try database.searchCandidates(keyword: keyword).filter { candidate in
                        candidate.title.localizedCaseInsensitiveContains(keyword) || candidate.normalizedText.contains(keyword)
                    }
                }
                guard let first = groups.first else { return [] }
                let commonIDs = groups.dropFirst().reduce(Set(first.map(\.id))) { result, group in
                    result.intersection(group.map(\.id))
                }
                let normalizedQuery = SearchTextNormalizer.normalize(query)
                var results: [HistorySearchResult] = []
                for id in commonIDs {
                    let candidates = groups.flatMap { $0 }.filter { $0.id == id }
                    guard let best = candidates.max(by: { self.score($0, query: normalizedQuery) < self.score($1, query: normalizedQuery) }) else { continue }
                    results.append(HistorySearchResult(
                        id: id,
                        title: best.title,
                        contentKind: best.contentKind,
                        thumbnailPath: best.thumbnailPath,
                        matchedSnippet: self.snippet(from: best.originalText, keywords: keywords),
                        matchedPageNumber: best.pageNumber,
                        score: self.score(best, query: normalizedQuery),
                        sourcePath: best.sourceFingerprint.flatMap { $0.hasPrefix("file:") ? String($0.dropFirst(5)) : nil },
                        isAppleMusic: best.isAppleMusic,
                        isClipboardContent: best.sourceFingerprint?.hasPrefix("clipboard:") == true,
                        historyIsPinned: best.historyIsPinned
                    ))
                }
                return results.sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }.prefix(limit).map { $0 }
            } catch {
                NSLog("历史搜索失败：%@", error.localizedDescription)
                return []
            }
        }.value
    }

    private func score(_ candidate: HistorySearchCandidate, query: String) -> Double {
        let title = SearchTextNormalizer.normalize(candidate.title)
        let base: Double
        if title == query { base = 1_000 }
        else if title.hasPrefix(query) { base = 800 }
        else if title.contains(query) { base = 600 }
        else if candidate.normalizedText.contains(query) { base = 400 }
        else { base = 200 }
        // 加权小于相邻文本相关性档位的差值，同档优先钉住，强匹配仍优先。
        return base + (candidate.historyIsPinned ? 20 : 0) + min(candidate.lastOpenedAt.timeIntervalSince1970 / 1_000_000_000, 10)
    }

    private func snippet(from text: String, keywords: [String]) -> String? {
        guard !text.isEmpty, let keyword = keywords.first,
              let range = SearchTextNormalizer.normalize(text).range(of: keyword) else { return nil }
        let normalized = SearchTextNormalizer.normalize(text)
        let offset = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
        let start = normalized.index(normalized.startIndex, offsetBy: max(0, offset - 35))
        let end = normalized.index(start, offsetBy: min(90, normalized.distance(from: start, to: normalized.endIndex)))
        return (start > normalized.startIndex ? "…" : "") + String(normalized[start..<end]) + (end < normalized.endIndex ? "…" : "")
    }
}
