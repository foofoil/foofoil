import Foundation
import Cocoa
import Combine

/// 供现有视图观察的兼容门面；历史权威数据由 `HistoryRepository` 管理。
public final class HistoryManager: ObservableObject {
    public static let shared = HistoryManager()

    @Published public private(set) var historyConfigs: [WindowConfig] = []
    private var checkingFiles = false
    private let fileCheckQueue = DispatchQueue(label: "com.foofoil.history.file-check", qos: .utility)
    private let repository: HistoryRepository
    private let contentCache: ContentCache
    private let cacheDirectories: () -> [URL]
    private let listSaveQueue = DispatchQueue(label: "com.foofoil.history.large-list", qos: .utility)
    private var pendingListConfigs: [UUID: WindowConfig] = [:]
    private var listSaveWorkItem: DispatchWorkItem?
    private var historyMutationGeneration: UInt64 = 0

    init(repository: HistoryRepository = .shared, contentCache: ContentCache = .shared,
         cacheDirectories: @escaping () -> [URL] = { AppState.cacheDirectoryURLs() }) {
        self.repository = repository
        self.contentCache = contentCache
        self.cacheDirectories = cacheDirectories
        refresh()
        contentCache.recoverOrphanBodies()
        // 旧历史没有 Quick Look 缩略图；后台补齐并沿用现有路径去重。
        for config in repository.recent(limit: Int.max) where config.contentKind == .quickLook {
            ContentIndexCoordinator.shared.schedule(config: config)
        }
    }

    public func refresh() {
        let configs = repository.recent(limit: 30)
        if Thread.isMainThread { historyConfigs = configs; checkFileReferences() }
        else { DispatchQueue.main.async { self.historyConfigs = configs; self.checkFileReferences() } }
    }

    public func addToHistory(_ config: WindowConfig) {
        historyMutationGeneration &+= 1
        // 大列表每次切歌都编码书签、重建索引并读取历史，不能阻塞主线程。
        if (config.fileList?.items.count ?? 0) >= 256, hasPersistableContent(config) {
            pendingListConfigs[config.id] = config
            listSaveWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.enqueuePendingListSaves() }
            listSaveWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }
        // 同一历史项从大列表变为小列表时，先完成旧写入，再保存最新状态。
        pendingListConfigs.removeValue(forKey: config.id)
        listSaveQueue.sync {}
        guard hasPersistableContent(config), repository.upsert(config) else { return }
        refreshUI()
        ContentIndexCoordinator.shared.schedule(config: config)
    }

    @discardableResult
    public func setPinned(id: UUID, pinned: Bool) -> Bool {
        flushPendingListSaves()
        guard repository.setPinned(id: id, pinned: pinned) else { return false }
        historyMutationGeneration &+= 1
        refreshUI()
        return true
    }

    @discardableResult
    func setFavorite(id: UUID, pinned: Bool, toast: FoilToastCenter) -> Bool {
        let succeeded = setPinned(id: id, pinned: pinned)
        toast.showFavoriteResult(pinned: pinned, succeeded: succeeded)
        return succeeded
    }

    /// 显式删除与自动清理分开；只对已钉住的记录要求确认。
    @discardableResult
    func requestRemoveFromHistory(_ config: WindowConfig) -> Bool {
        guard let current = repository.config(id: config.id) else { return false }
        if current.historyIsPinned, Self.pinnedDeletionAlert().runModal() != .alertSecondButtonReturn { return false }
        removeFromHistory(current)
        return true
    }

    static func pinnedDeletionAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Delete Favorited History Confirmation", comment: "")
        alert.informativeText = NSLocalizedString("Delete Favorited History Explanation", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Delete History Record", comment: "")).hasDestructiveAction = true
        return alert
    }

    public func removeFromHistory(_ config: WindowConfig, preservingLegacyBody: Bool = false) {
        if preservingLegacyBody, repository.config(id: config.id)?.historyIsPinned == true { return }
        historyMutationGeneration &+= 1
        pendingListConfigs.removeValue(forKey: config.id)
        // 排空已提交写入，防止后台任务在删除之后重新创建历史项。
        listSaveQueue.sync {}
        ContentIndexCoordinator.shared.cancel(historyID: config.id)
        guard repository.remove(ids: [config.id]) else { return }
        forgetRestoration(ids: [config.id])
        let referencedPaths = Set(repository.recent(limit: Int.max).flatMap(cachePaths(for:)))
        let legacyPaths = preservingLegacyBody ? config.legacyExternalBodyPaths : []
        removeCacheFiles(for: config, preserving: referencedPaths.union(legacyPaths))
        contentCache.retire(Set(cachePaths(for: config)).subtracting(legacyPaths))
        refreshUI()
    }

    /// 批量清除前取消待写入与索引任务；数据库及缓存清理放在已有串行队列，防止删除后复活。
    @MainActor
    func removeFromHistory(_ configs: [WindowConfig]) async -> Bool {
        historyMutationGeneration &+= 1
        let ids = Set(configs.map(\.id))
        for id in ids {
            pendingListConfigs.removeValue(forKey: id)
            ContentIndexCoordinator.shared.cancel(historyID: id)
        }
        let activePaths = activeCachePaths()
        let candidatePaths = Set(configs.flatMap(cachePaths(for:)))
        let success = await withCheckedContinuation { continuation in
            listSaveQueue.async {
                guard self.repository.remove(ids: ids) else {
                    continuation.resume(returning: false)
                    return
                }
                let referencedPaths = Set(self.repository.recent(limit: Int.max).flatMap(self.cachePaths(for:)))
                let preservedPaths = activePaths.union(referencedPaths)
                for path in candidatePaths where !preservedPaths.contains(path) {
                    let url = URL(fileURLWithPath: path)
                    if AppState.isManagedCacheURL(url) { self.contentCache.retire([path]) }
                }
                continuation.resume(returning: true)
            }
        }
        if success {
            forgetRestoration(ids: ids)
            contentCache.retire(candidatePaths)
        }
        refreshUI()
        return success
    }

    public func clearHistory(preserving activeConfigs: [WindowConfig]? = nil) {
        historyMutationGeneration &+= 1
        flushPendingListSaves()
        let configs = activeConfigs ?? (NSApplication.shared.delegate as? AppDelegate)?.windowControllers.filter { !$0.appState.isIncognito }.map { $0.appState.toConfig() } ?? []
        let incognitoIDs = Set((NSApplication.shared.delegate as? AppDelegate)?.windowControllers.filter { $0.appState.isIncognito }.map { $0.appState.id } ?? [])
        let active = configs.filter { !incognitoIDs.contains($0.id) && hasPersistableContent($0) }
        let activeIDs = Set(active.map(\.id))
        let pinned = repository.recent(limit: Int.max).filter(\.historyIsPinned)
        let retainedIDs = activeIDs.union(pinned.map(\.id))
        ContentIndexCoordinator.shared.cancelAll(excluding: retainedIDs)
        repository.removeAll(excluding: activeIDs)
        active.forEach { _ = repository.upsert($0) }

        let activePaths = Set((active + pinned).flatMap(cachePaths(for:))).union(activeCachePaths())
        for directoryURL in cacheDirectories() {
            guard let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let fileURL as URL in enumerator where contentCache.isManaged(fileURL) && !activePaths.contains(fileURL.path) {
                contentCache.retire([fileURL.path])
            }
        }
        clearThumbnailFiles(preserving: retainedIDs)
        refreshUI()
    }

    /// 清理所有不在活跃列表中的历史项的缩略图文件，兼容旧 Flofoil/Flamina 目录
    private func clearThumbnailFiles(preserving activeIDs: Set<UUID>) {
        for root in cacheDirectories() {
            let thumbnailsDir = root.appendingPathComponent("Thumbnails")
            guard let enumerator = FileManager.default.enumerator(at: thumbnailsDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let fileURL as URL in enumerator {
                let uuidString = fileURL.deletingPathExtension().lastPathComponent
                if let uuid = UUID(uuidString: uuidString) {
                    if !activeIDs.contains(uuid) {
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                } else {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }
        }
    }

    nonisolated private static func snapshotData(_ config: WindowConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(config)
    }

    private func forgetRestoration(ids: Set<UUID>) {
        SettingsStore.shared.lastOpenWindowConfigs.removeAll { ids.contains($0.id) }
        SettingsStore.shared.windowConfigs.removeAll { ids.contains($0.id) }
        for id in ids {
            for root in cacheDirectories() {
                try? FileManager.default.removeItem(at: root.appendingPathComponent("Thumbnails/\(id).heic"))
            }
        }
    }

    /// 单队列分批检查；结果提交前比对完整快照，避免覆盖窗口期间的新状态。
    func checkFileReferences() {
        guard !checkingFiles else { return }
        checkingFiles = true
        Task { @MainActor in
            defer { checkingFiles = false }
            var cursor: UUID?
            while true {
                let batchCursor = cursor
                let results: [(WindowConfig, (config: WindowConfig, missing: Bool))] = await withCheckedContinuation { continuation in
                    fileCheckQueue.async {
                        let batch = self.repository.fileCheckBatch(after: batchCursor)
                        continuation.resume(returning: batch.map { ($0, $0.resolvingFileReferences()) })
                    }
                }
                guard let last = results.last else { break }
                cursor = last.0.id
                for (old, result) in results { applyFileReferenceResult(old, result: result) }
                historyConfigs = repository.recent(limit: 30)
            }
        }
    }

    /// 结果提交与设置检查在主线程完成；供异步竞态回归直接验证。
    func applyFileReferenceResult(_ old: WindowConfig, result: (config: WindowConfig, missing: Bool)) {
        guard let current = repository.config(id: old.id),
              (try? Self.snapshotData(current)) == (try? Self.snapshotData(old)) else { return }
        if result.missing {
            if SettingsStore.shared.automaticallyRemoveMissingHistory && !current.historyIsPinned { removeFromHistory(current, preservingLegacyBody: true) }
        } else if (try? Self.snapshotData(result.config)) != (try? Self.snapshotData(old)) {
            // 关闭清理时也不能静默裁剪文件列表。
            if (SettingsStore.shared.automaticallyRemoveMissingHistory && !current.historyIsPinned) || result.config.fileList?.items.count == old.fileList?.items.count {
                _ = repository.upsert(result.config)
                if let state = (NSApplication.shared.delegate as? AppDelegate)?.windowControllers.first(where: { $0.appState.id == old.id })?.appState,
                   let list = result.config.fileList, list.items.count != old.fileList?.items.count {
                    let previousID = state.fileList?.currentID
                    state.fileList = list
                    state.syncFileListNavigator()
                    if previousID != list.currentID { state.presentFileListItem(id: list.currentID, rotatesIdentity: false) }
                }
            }
        }
    }

    public func updateHistoryTitle(configId: UUID, newTitle: String) {
        let state = (NSApplication.shared.delegate as? AppDelegate)?.windowControllers
            .first(where: { $0.appState.id == configId })?.appState
        guard (state?.toConfig() ?? repository.config(id: configId))?.canRenameTitle == true else { return }
        flushPendingListSaves()
        historyMutationGeneration &+= 1
        // 同步活跃箔片，避免下一次自动保存覆盖刚改好的历史标题。
        state?.applyFoilTitle(newTitle)
        guard state?.isIncognito != true else { return }
        repository.rename(id: configId, title: newTitle)
        refreshUI()
    }

    private func refreshUI() {
        refresh()
        NotificationCenter.default.post(name: Notification.Name("ContentCacheDidChange"), object: nil)
        DispatchQueue.main.async {
            (NSApplication.shared.delegate as? AppDelegate)?.updateHistoryMenu()
        }
    }

    private func enqueuePendingListSaves() {
        listSaveWorkItem?.cancel()
        listSaveWorkItem = nil
        guard !pendingListConfigs.isEmpty else { return }
        let configs = Array(pendingListConfigs.values)
        pendingListConfigs.removeAll()
        let generation = historyMutationGeneration
        let repository = repository
        listSaveQueue.async { [weak self] in
            let saved = configs.filter { repository.upsert($0) }
            let recent = repository.recent(limit: 30)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.historyMutationGeneration == generation else { return }
                self.historyConfigs = recent
                (NSApplication.shared.delegate as? AppDelegate)?.updateHistoryMenu(preloadedConfigs: recent)
                for config in saved { ContentIndexCoordinator.shared.schedule(config: config) }
            }
        }
    }

    /// 退出和显式历史操作前落盘最后一次选择，避免防抖任务丢失恢复位置。
    func flushPendingListSaves() {
        enqueuePendingListSaves()
        listSaveQueue.sync {}
    }

    private func activeCachePaths() -> Set<String> {
        Set(((NSApplication.shared.delegate as? AppDelegate)?.windowControllers ?? []).flatMap { $0.appState.cachedContentPaths })
    }

    private func cachePaths(for config: WindowConfig) -> [String] {
        var paths = [config.imagePath, config.textPath, config.customCoverPath, config.imageSubjectPath].compactMap { $0 }
        paths.append(contentsOf: config.fileList?.items.map(\.path) ?? [])
        paths.append(contentsOf: config.archiveSource?.volumes.map(\.path) ?? [])
        if let value = config.webURLString, let url = URL(string: value), url.isFileURL { paths.append(url.path) }
        if let imagePath = config.imagePath,
           let copy = FragmentedMP4PlaybackCopy.copyURL(for: URL(fileURLWithPath: imagePath)) {
            paths.append(copy.path)
        }
        return paths
    }

    private func removeCacheFiles(for config: WindowConfig, preserving paths: Set<String>) {
        for path in cachePaths(for: config) where !paths.contains(path) {
            let url = URL(fileURLWithPath: path)
            if AppState.isManagedCacheURL(url) { contentCache.retire([path]) }
        }
    }

    func hasPersistableContent(_ config: WindowConfig) -> Bool {
        guard config.sourceFingerprint?.hasPrefix("archive-entry:") != true else { return false }
        return config.terminalConfiguration != nil || config.appleMusicReference != nil || config.extensionID != nil || config.imagePath != nil || config.webURLString != nil || config.textPath != nil || !config.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 收藏反馈文案留在历史领域，通用 toast 不依赖业务状态。
extension FoilToastCenter {
    func showFavoriteResult(pinned: Bool, succeeded: Bool) {
        let key = succeeded ? (pinned ? "Favorite Added Toast" : "Favorite Removed Toast") : "Favorite Update Failed"
        show(NSLocalizedString(key, comment: ""),
             symbolName: succeeded ? (pinned ? "bookmark.fill" : "bookmark.slash.fill") : "exclamationmark.triangle.fill",
             duration: succeeded ? .seconds(1.5) : .seconds(3))
    }
}
