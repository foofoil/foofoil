import Foundation

/// 统一提交内容缓存；编码先写临时文件，串行检查容量后才替换正式文件。
nonisolated final class ContentCache: @unchecked Sendable {
    static let shared = ContentCache()
    static let limitKey = "contentCacheLimitBytes"
    static let defaultLimit: Int64 = 2 * 1024 * 1024 * 1024
    private let queue = DispatchQueue(label: "com.foofoil.content-cache", qos: .utility)
    private let lock = NSLock()
    private var retiredPaths: Set<String> = []
    private var cleanupScheduled = false
    private var leasedPaths: [String: Int] = [:]
    private let bodyQueue = DispatchQueue(label: "com.foofoil.managed-body", qos: .utility)
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
        let changed = activeIDs != ids || activePaths != paths
        activeIDs = ids
        activePaths = paths
        lock.unlock()
        if changed { collectRetired() }
    }

    /// 正文不属于容量淘汰缓存；串行写入确保快速连续编辑不会乱序覆盖。
    func enqueueBodyWrite(_ data: Data, to url: URL, completion: @escaping @Sendable (Error?) -> Void = { _ in }) {
        retain([url.path])
        bodyQueue.async {
            defer { self.release([url.path]) }
            do { try data.write(to: url, options: .atomic); completion(nil) }
            catch { NSLog("托管正文保存失败：%@", error.localizedDescription); completion(error) }
        }
    }

    func flushBodyWrites() { bodyQueue.sync {} }
    func flushCleanup() { queue.sync {} }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
    private func owns(_ url: URL) -> Bool {
        if AppState.isManagedCacheURL(url) { return true }
        // 测试可注入隔离目录；运行时目录仍只来自应用支持路径。
        return directories().contains { Self.canonical($0.path) == Self.canonical(url.deletingLastPathComponent().path) }
            && ["managed_body_", "session_body_", "cached_image_", "cached_text_", "cached_web_", "cached_cover_", "cached_subject_", FragmentedMP4PlaybackCopy.filePrefix].contains { url.lastPathComponent.hasPrefix($0) }
    }

    func hasLease(for path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let target = Self.canonical(path)
        return leasedPaths.contains { Self.canonical($0.key) == target && $0.value > 0 }
    }

    func retain(_ paths: Set<String>) {
        lock.lock()
        for path in paths { leasedPaths[path, default: 0] += 1 }
        lock.unlock()
    }

    func release(_ paths: Set<String>) {
        lock.lock()
        for path in paths { leasedPaths[path, default: 0] -= 1 }
        lock.unlock()
        collectRetired()
    }

    func retire(_ paths: Set<String>) {
        let shareRoots = paths.compactMap { AppState.managedShareRoot(for: URL(fileURLWithPath: $0))?.path }
        lock.lock(); retiredPaths.formUnion(paths); retiredPaths.formUnion(shareRoots); lock.unlock()
        collectRetired()
    }

    private func collectRetired() {
        lock.lock()
        guard !retiredPaths.isEmpty, !cleanupScheduled else { lock.unlock(); return }
        cleanupScheduled = true
        lock.unlock()
        queue.async {
            var referenced: Set<String> = []
            for config in self.repository.recent(limit: Int.max) {
                referenced.formUnion([config.imagePath, config.textPath, config.customCoverPath, config.imageSubjectPath].compactMap { $0 })
                if let value = config.webURLString, let url = URL(string: value), url.isFileURL { referenced.insert(url.path) }
                referenced.formUnion(config.fileList?.items.map(\.path) ?? [])
                referenced.formUnion(config.archiveSource?.volumes.map(\.path) ?? [])
            }
            self.lock.lock()
            defer { self.cleanupScheduled = false; self.lock.unlock() }
            for path in self.retiredPaths {
                // 非沙盒临时目录可同时出现 /var 与 /private/var，不能把同一文件误判成孤儿。
                let target = Self.canonical(path)
                let prefix = target + "/"
                func includes(_ candidate: String) -> Bool {
                    let value = Self.canonical(candidate)
                    return value == target || value.hasPrefix(prefix)
                }
                guard !self.activePaths.contains(where: includes),
                      !referenced.contains(where: includes),
                      !self.leasedPaths.contains(where: { includes($0.key) && $0.value > 0 }) else { continue }
                let url = URL(fileURLWithPath: path)
                if self.owns(url) {
                    try? FileManager.default.removeItem(at: url)
                    let parent = url.deletingLastPathComponent()
                    if ["Shared Items", "Session Shared Items"].contains(parent.deletingLastPathComponent().lastPathComponent),
                       (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                        try? FileManager.default.removeItem(at: parent)
                    }
                }
                self.retiredPaths.remove(path)
            }
        }
    }

    /// 只回收新生命周期明确拥有的残留；旧缓存可能是唯一正文，留给显式处置。
    func recoverOrphanBodies() {
        queue.async {
            let cutoff = Date().addingTimeInterval(-86400)
            for directory in self.directories() {
                guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                let candidates = files.filter {
                    ($0.lastPathComponent.hasPrefix("session_body_") || $0.lastPathComponent.hasPrefix("managed_body_") ||
                     $0.lastPathComponent.hasPrefix(FragmentedMP4PlaybackCopy.filePrefix)) &&
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture) < cutoff
                }
                self.retire(Set(candidates.map(\.path)))
                let shares = directory.appendingPathComponent("Session Shared Items")
                if let enumerator = FileManager.default.enumerator(at: shares, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) {
                    for case let url as URL in enumerator {
                        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                           values.isRegularFile == true, (values.contentModificationDate ?? .distantFuture) < cutoff {
                            self.retire([url.path])
                        }
                    }
                }
            }
        }
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
        if destination.lastPathComponent.hasPrefix("managed_body_") || destination.lastPathComponent.hasPrefix("session_body_") {
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".body-\(UUID()).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try produce(temporary)
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: destination) }
            return
        }
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
            for case let url as URL in enumerator where AppState.isManagedCacheURL(url) ||
                (url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path && ["cached_image_", "cached_text_", "cached_web_", "cached_cover_", "cached_subject_"].contains(where: { url.lastPathComponent.hasPrefix($0) })) || (url.deletingLastPathComponent().lastPathComponent == "Thumbnails" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil) {
                guard !url.lastPathComponent.hasPrefix("managed_body_"), !url.lastPathComponent.hasPrefix("session_body_"),
                      // 兼容副本只能由 APFS 克隆生成；共享数据不按整片逻辑大小计入缓存配额。
                      !url.lastPathComponent.hasPrefix(FragmentedMP4PlaybackCopy.filePrefix),
                      !url.path.contains("/Shared Items/"), !url.path.contains("/Session Shared Items/") else { continue }
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
        return paths.union(paths.map(Self.canonical))
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
        var candidates: [Set<String>] = []
        let referenced = references.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        // 无历史引用的残留缓存优先回收。
        let orphanPaths = cached.keys.sorted {
            let first = (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast
            let second = (try? FileManager.default.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast
            return first == second ? $0 < $1 : first < second
        }
        for path in orphanPaths where !["cached_image", "cached_text_", "cached_web_", "cached_package_"].contains(where: { URL(fileURLWithPath: path).lastPathComponent.hasPrefix($0) }) && !referenced.contains(path) && !protectedPaths.contains(path) && !protected.contains(where: { path.contains($0.uuidString) }) {
            candidates.append([path])
        }
        // 历史仍引用的正文不可淘汰；只清理可重新生成的缩略图和派生资源。
        var bodies: Set<String> = []
        for config in configs {
            bodies.formUnion([config.imagePath, config.textPath].compactMap { $0 })
            if let value = config.webURLString, let url = URL(string: value), url.isFileURL { bodies.insert(url.path) }
            bodies.formUnion(config.fileList?.items.map(\.path) ?? [])
            bodies.formUnion(config.archiveSource?.volumes.map(\.path) ?? [])
        }
        bodies.formUnion(bodies.map(Self.canonical))
        for path in referenced where cached[path] != nil && !bodies.contains(path) && !protectedPaths.contains(path) {
            candidates.append([path])
        }
        // 先确认空间足够，避免写入注定失败却已删除用户历史。
        let available = Set(candidates.flatMap { $0 }).reduce(Int64(0)) { $0 + (cached[$1] ?? 0) }
        guard total - available <= limit else { throw CocoaError(.fileWriteOutOfSpace) }
        for paths in candidates where total > limit {
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
