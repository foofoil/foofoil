import Foundation
import Cocoa
import Combine

/// 供现有视图观察的兼容门面；历史权威数据由 `HistoryRepository` 管理。
public final class HistoryManager: ObservableObject {
    public static let shared = HistoryManager()

    @Published public private(set) var historyConfigs: [WindowConfig] = []
    private let repository = HistoryRepository.shared
    private let listSaveQueue = DispatchQueue(label: "com.foofoil.history.large-list", qos: .utility)
    private var pendingListConfigs: [UUID: WindowConfig] = [:]
    private var listSaveWorkItem: DispatchWorkItem?
    private var historyMutationGeneration: UInt64 = 0

    private init() { refresh() }

    public func refresh() {
        let configs = repository.recent(limit: 30)
        if Thread.isMainThread { historyConfigs = configs }
        else { DispatchQueue.main.async { self.historyConfigs = configs } }
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

    public func removeFromHistory(_ config: WindowConfig) {
        historyMutationGeneration &+= 1
        pendingListConfigs.removeValue(forKey: config.id)
        // 排空已提交写入，防止后台任务在删除之后重新创建历史项。
        listSaveQueue.sync {}
        ContentIndexCoordinator.shared.cancel(historyID: config.id)
        repository.remove(id: config.id)
        let referencedPaths = Set(repository.recent(limit: Int.max).flatMap(cachePaths(for:)))
        removeCacheFiles(for: config, preserving: activeCachePaths().union(referencedPaths))
        refreshUI()
    }

    public func clearHistory(preserving activeConfigs: [WindowConfig]? = nil) {
        historyMutationGeneration &+= 1
        listSaveWorkItem?.cancel()
        pendingListConfigs.removeAll()
        listSaveQueue.sync {}
        let configs = activeConfigs ?? (NSApplication.shared.delegate as? AppDelegate)?.windowControllers.map { $0.appState.toConfig() } ?? []
        let active = configs.filter(hasPersistableContent)
        let activeIDs = Set(active.map(\.id))
        ContentIndexCoordinator.shared.cancelAll(excluding: activeIDs)
        repository.removeAll(excluding: activeIDs)
        active.forEach { _ = repository.upsert($0) }

        let activePaths = Set(active.flatMap(cachePaths(for:)))
        for directoryURL in AppState.cacheDirectoryURLs() {
            guard let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let fileURL as URL in enumerator where AppState.isManagedCacheURL(fileURL) && !activePaths.contains(fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        clearThumbnailFiles(preserving: activeIDs)
        refreshUI()
    }

    /// 清理所有不在活跃列表中的历史项的缩略图文件，兼容旧 Flofoil/Flamina 目录
    private func clearThumbnailFiles(preserving activeIDs: Set<UUID>) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in ["foofoil", "Flamina", "Flofoil"] {
            let root = appSupport.appendingPathComponent(name, isDirectory: true)
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

    public func updateHistoryTitle(configId: UUID, newTitle: String) {
        flushPendingListSaves()
        historyMutationGeneration &+= 1
        // 已打开列表也同步内存标题，避免下一次窗口状态保存把刚改好的数据库标题覆盖掉。
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let state = appDelegate.windowControllers.first(where: { $0.appState.id == configId })?.appState,
           var fileList = state.fileList,
           fileList.isPresentable {
            fileList.title = FileListState.normalizedTitle(newTitle)
            state.fileList = fileList
        }
        repository.rename(id: configId, title: newTitle)
        refreshUI()
    }

    private func refreshUI() {
        refresh()
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
        var paths = [config.imagePath, config.textPath, config.customCoverPath].compactMap { $0 }
        if let value = config.webURLString, let url = URL(string: value), url.isFileURL { paths.append(url.path) }
        return paths
    }

    private func removeCacheFiles(for config: WindowConfig, preserving paths: Set<String>) {
        for path in cachePaths(for: config) where !paths.contains(path) {
            let url = URL(fileURLWithPath: path)
            if AppState.isManagedCacheURL(url) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func hasPersistableContent(_ config: WindowConfig) -> Bool {
        config.extensionID != nil || config.imagePath != nil || config.webURLString != nil || config.textPath != nil || !config.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
