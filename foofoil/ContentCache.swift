import Foundation

/// 统一提交内容缓存；编码先写临时文件，串行检查容量后才替换正式文件。
nonisolated final class ContentCache: @unchecked Sendable {
    static let shared = ContentCache()
    static let limitKey = "contentCacheLimitBytes"
    static let defaultLimit: Int64 = 2 * 1024 * 1024 * 1024
    private let queue = DispatchQueue(label: "com.foofoil.content-cache", qos: .utility)
    private let lock = NSLock()
    private var activeIDs: Set<UUID> = []
    private var activePaths: Set<String> = []
    private let repository: HistoryRepository
    private let directories: () -> [URL]
    private let defaults: UserDefaults

    init(repository: HistoryRepository = .shared, defaults: UserDefaults = .standard, directories: @escaping () -> [URL] = { AppState.cacheDirectoryURLs() }) {
        self.repository = repository
        self.defaults = defaults
        self.directories = directories
    }

    func protect(_ ids: Set<UUID>, paths: Set<String> = []) {
        lock.lock()
        activeIDs = ids
        activePaths = paths
        lock.unlock()
    }

    var usage: Int64 { queue.sync { files().values.reduce(0, +) } }

    enum LimitError: Error { case confirmationRequired }

    func setLimit(_ bytes: Int64, allowClearing: Bool = true) throws {
        try queue.sync {
            guard bytes > 0 else { throw CocoaError(.fileWriteOutOfSpace) }
            if !allowClearing, files().values.reduce(0, +) > bytes { throw LimitError.confirmationRequired }
            try trim(to: bytes, excluding: [])
            defaults.set(bytes, forKey: Self.limitKey)
        }
    }

    func copy(from source: URL, to destination: URL) throws {
        try write(to: destination) { try FileManager.default.copyItem(at: source, to: $0) }
    }

    func write(_ data: Data, to destination: URL) throws {
        try write(to: destination) { try data.write(to: $0) }
    }

    func write(to destination: URL, produce: (URL) throws -> Void) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".cache-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try produce(temporary)
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try queue.sync {
            let configured = defaults.object(forKey: Self.limitKey) as? NSNumber
            let limit = configured?.int64Value ?? Self.defaultLimit
            guard Int64(size) <= limit else { throw CocoaError(.fileWriteOutOfSpace) }
            try trim(to: limit - Int64(size), excluding: [destination.path])
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Notification.Name("ContentCacheDidChange"), object: nil) }
    }

    private func files() -> [String: Int64] {
        var result: [String: Int64] = [:]
        for directory in directories() {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where AppState.isManagedCacheURL(url) || (url.deletingLastPathComponent().lastPathComponent == "Thumbnails" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil) {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
                result[url.path] = Int64(values.fileSize ?? 0)
            }
        }
        return result
    }

    private func paths(for config: WindowConfig, files: [String: Int64]) -> Set<String> {
        var paths = Set([config.imagePath, config.textPath, config.customCoverPath, config.imageSubjectPath].compactMap { $0 })
        paths.formUnion(config.archiveSource?.volumes.map(\.path) ?? [])
        if let value = config.webURLString, let url = URL(string: value), url.isFileURL { paths.insert(url.path) }
        if let path = config.imagePath, let copy = FragmentedMP4PlaybackCopy.copyURL(for: URL(fileURLWithPath: path)) { paths.insert(copy.path) }
        // 列表图片和派生文件也属于同一条记录。
        paths.formUnion(files.keys.filter { $0.contains(config.id.uuidString) })
        return paths
    }

    private func trim(to limit: Int64, excluding excluded: Set<String>) throws {
        let cached = files()
        var total = cached.filter { !excluded.contains($0.key) }.values.reduce(0, +)
        guard total > limit else { return }
        lock.lock()
        let active = activeIDs
        let openPaths = activePaths
        lock.unlock()
        let configs = repository.recent(limit: Int.max)
        let protected = active.union(configs.filter { config in excluded.contains(where: { $0.contains(config.id.uuidString) }) }.map(\.id))
        let references = Dictionary(uniqueKeysWithValues: configs.map { ($0.id, paths(for: $0, files: cached)) })
        let protectedPaths = configs.filter { protected.contains($0.id) }.reduce(into: excluded.union(openPaths)) { $0.formUnion(references[$1.id] ?? []) }
        var candidates: [(WindowConfig?, Set<String>)] = []
        let referenced = references.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        // 无历史引用的残留缓存优先回收。
        let orphanPaths = cached.keys.sorted {
            let first = (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast
            let second = (try? FileManager.default.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast
            return first == second ? $0 < $1 : first < second
        }
        for path in orphanPaths where !referenced.contains(path) && !protectedPaths.contains(path) && !protected.contains(where: { path.contains($0.uuidString) }) {
            candidates.append((nil, [path]))
        }
        var owners: [String: Int] = [:]
        for paths in references.values {
            for path in paths { owners[path, default: 0] += 1 }
        }
        for config in configs.reversed() where !protected.contains(config.id) {
            let paths = references[config.id] ?? []
            guard paths.contains(where: { cached[$0] != nil }), paths.isDisjoint(with: protectedPaths) else { continue }
            var removable: Set<String> = []
            for path in paths {
                owners[path, default: 0] -= 1
                if owners[path] == 0, !excluded.contains(path) { removable.insert(path) }
            }
            candidates.append((config, removable))
        }
        // 先确认空间足够，避免写入注定失败却已删除用户历史。
        let available = Set(candidates.flatMap { $0.1 }).reduce(Int64(0)) { $0 + (cached[$1] ?? 0) }
        guard total - available <= limit else { throw CocoaError(.fileWriteOutOfSpace) }
        for (config, paths) in candidates where total > limit {
            if let config {
                guard repository.remove(ids: [config.id]) else { throw CocoaError(.fileWriteUnknown) }
            }
            for path in paths where cached[path] != nil {
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
                total -= cached[path] ?? 0
            }
        }
        DispatchQueue.main.async {
            HistoryManager.shared.refresh()
            NotificationCenter.default.post(name: Notification.Name("ContentCacheDidChange"), object: nil)
        }
    }
}
