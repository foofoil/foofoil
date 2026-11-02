import AppKit
import Combine
import FoofoilExtensionKit

/// 缓存由派生阅读器共同持有；视图/媒体退出并释放最后一个持有者后才回收。
nonisolated final class ArchivePreviewLease: Sendable {
    let directory: URL
    let byteCount: Int64
    private let retainedLeases: [ArchivePreviewLease]
    private let removesDirectory: Bool
    init(directory: URL, byteCount: Int64 = 0, retaining leases: [ArchivePreviewLease] = [], removesDirectory: Bool = true) {
        self.directory = directory; self.byteCount = byteCount; self.retainedLeases = leases; self.removesDirectory = removesDirectory
    }
    deinit { if removesDirectory { try? FileManager.default.removeItem(at: directory) } }
}

@MainActor final class ArchivePreviewRetention {
    var lease: ArchivePreviewLease?
    init(_ lease: ArchivePreviewLease?) { self.lease = lease }
}

@MainActor final class ArchiveSession: ObservableObject {
    static let navigatorID = "builtin.archive"
    let navigatorContributionID = ArchiveSession.navigatorID
    private(set) var source: ArchiveSource
    let urls: [URL]
    private let accessedURLs: [URL]
    @Published private(set) var index: ArchiveIndex?
    @Published private(set) var selectedID: String?
    @Published private(set) var preview: AppState?
    @Published private(set) var busy = false
    @Published private(set) var exporting = false
    @Published private(set) var exportedBytes: Int64 = 0
    @Published var message: String?
    @Published var needsPassword = false
    @Published var passwordInput = ""
    private let workQueue = ArchiveWorkQueue()
    private var password: String?
    private weak var passwordTarget: ArchiveSession?
    private var passwordNodeID: String?
    /// 内层包的来源必须覆盖异步扫描、预览与导出的整个生命周期。
    private(set) var sourceLease: ArchivePreviewLease?
    private final class NestedArchive {
        var isAudio = false
        var lease: ArchivePreviewLease?
        var session: ArchiveSession?
        var task: Task<Void, Never>?
        var error: String?
    }
    private var nestedArchives: [String: NestedArchive] = [:]
    private var archiveNodeIDs: Set<String> = []
    private var projectedMediaKinds: [String: FileListKind] = [:]
    private var mediaEntryIDsByPath: [String: String] = [:]
    private var itemParents: [String: String] = [:]
    private var itemLocations: [String: (origin: ArchiveSession?, entry: ArchiveEntry)] = [:]
    private var retry: (() -> Void)?
    private var previewObservation: AnyCancellable?
    private var task: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var generation = UUID()
    private var cachedContribution = NavigatorContribution(id: navigatorID, titleLocalizationKey: "Archive Contents", style: .outline, items: [], allowedActions: [.activate])
    weak var windowState: AppState?
    var onChange: (() -> Void)?
    var locateVolumes: (() -> Void)?
    var selected: ArchiveEntry? { selectedID.flatMap { itemLocations[$0]?.entry } }
    var selectedFormat: String? {
        selectedID.flatMap { itemLocations[$0]?.origin?.index?.format } ?? index?.format
    }
    var passwordPromptName: String {
        passwordNodeID.flatMap { itemLocations[$0]?.entry.name }
            ?? passwordTarget?.source.name
            ?? source.name
    }
    var canExport: Bool { selected.map { $0.isDirectory || $0.isRegular } == true && !exporting && index != nil }

    let hasTemporarySource: Bool

    init(source: ArchiveSource, sourceLease: ArchivePreviewLease? = nil) {
        self.hasTemporarySource = sourceLease != nil
        self.sourceLease = sourceLease
        var urls: [URL] = []
        var accessed: [URL] = []
        var refreshed: [ArchiveSource.Volume] = []
        for volume in source.volumes {
            var stale = false
            let url = volume.bookmark.flatMap { try? URL(resolvingBookmarkData: $0, options: .withoutUI, bookmarkDataIsStale: &stale) } ?? URL(fileURLWithPath: volume.path)
            if url.startAccessingSecurityScopedResource() { accessed.append(url) }
            urls.append(url)
            refreshed.append(.init(path: url.path, bookmark: AppState.makeSecurityScopedBookmark(for: url)))
        }
        var resolved = source
        resolved.volumes = refreshed
        resolved.localFiles = source.localFiles?.map { file in
            let url = file.bookmark.flatMap(AppState.resolveVideoBookmark) ?? URL(fileURLWithPath: file.path)
            return .init(path: url.path, bookmark: AppState.makeSecurityScopedBookmark(for: url))
        }
        self.source = resolved
        self.urls = urls
        self.accessedURLs = accessed
    }

    deinit {
        task?.cancel()
        thumbnailTask?.cancel()
        exportTask?.cancel()
        let nodes = Array(nestedArchives.values)
        Task { @MainActor in
            for node in nodes { node.task?.cancel(); node.session?.close() }
        }
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    var contribution: NavigatorContribution {
        var result = cachedContribution
        result.selectedItemIDs = selectedID.map { [$0] } ?? []
        return result
    }

    func selectNavigatorItem(_ id: String) { select(id) }

    func isArchiveNode(_ id: String) -> Bool { archiveNodeIDs.contains(id) }

    func isLoadingArchiveNode(_ id: String) -> Bool {
        guard let node = nestedArchives[id] else { return false }
        return node.task != nil || node.session?.busy == true
    }

    /// 只有显式展开才提取内层包；选择该行仅显示信息或导出原始包。
    func setArchiveExpanded(_ id: String, expanded: Bool) {
        guard itemLocations[id] != nil else { return }
        if !expanded {
            var cancelled = false
            for key in Array(nestedArchives.keys) where key == id || isDescendant(key, of: id) {
                guard let node = nestedArchives[key], node.task != nil || node.session?.busy == true || node.session?.needsPassword == true || passwordNodeID == key else { continue }
                if passwordNodeID == key { cancelUnlock() }
                node.task?.cancel()
                node.session?.close()
                nestedArchives.removeValue(forKey: key)
                cancelled = true
            }
            guard cancelled else { return }
            projectIndex()
            objectWillChange.send()
            onChange?()
            return
        }
        guard isArchiveNode(id) else { return }
        message = nil
        if let node = nestedArchives[id] {
            if node.session?.index != nil || isLoadingArchiveNode(id) { return }
            if let session = node.session {
                node.error = nil
                session.load()
                return
            }
        }
        guard let location = itemLocations[id] else { return }
        guard nodeDepth(id) < ArchiveReader.maximumDepth else {
            let node = NestedArchive()
            node.error = ArchiveFailure.limit.localizedDescription
            nestedArchives[id] = node
            projectIndex()
            objectWillChange.send()
            onChange?()
            return
        }
        let origin = location.origin ?? self
        guard let index = origin.index else { return }
        let localSourceURL = localURL(for: id)
        let cachedLease = nestedArchives[id]?.lease
        let node = NestedArchive()
        nestedArchives[id] = node
        let urls = origin.urls, password = origin.password, queue = origin.workQueue, entry = location.entry
        let sourceLease = origin.sourceLease
        let rootQueue = workQueue, rootURLs = self.urls, rootIndex = source.localFiles == nil ? self.index : nil
        node.task = Task { [weak self, weak node] in
            defer { withExtendedLifetime(sourceLease) {} }
            let worker = Task.detached(priority: .userInitiated) { () -> ArchivePreviewLease? in
                if localSourceURL != nil { return nil }
                if let rootIndex { try await rootQueue.validate(urls: rootURLs, index: rootIndex) }
                if let cachedLease { return cachedLease }
                return try await queue.preview(urls: urls, index: index, entry: entry, password: password, limit: ArchiveReader.maximumExportBytes)
            }
            do {
                let lease = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, let node, !Task.isCancelled, self.nestedArchives[id] === node else { return }
                let cachedBytes = self.nestedArchives.values.reduce(Int64(0)) { $0 + ($1.lease?.byteCount ?? 0) }
                guard (lease?.byteCount ?? 0) <= ArchiveReader.maximumExportBytes - cachedBytes else { throw ArchiveFailure.limit }
                let sourceURL = localSourceURL ?? lease!.directory.appendingPathComponent(entry.name)
                // 内层 ISO 在首次读取后使用同一内容探测分流，SACD 保持音频叶节点。
                if sourceURL.pathExtension.lowercased() == "iso", ExtensionHost.shared.canOpenAsAudio(url: sourceURL) {
                    node.lease = lease
                    node.isAudio = true
                    node.task = nil
                    self.projectIndex()
                    self.objectWillChange.send()
                    self.onChange?()
                    if self.selectedID == id { self.select(id) }
                    return
                }
                let child = ArchiveSession(source: ArchiveSource(volumes: [.init(path: sourceURL.path)]), sourceLease: lease)
                node.lease = lease
                node.session = child
                node.task = nil
                child.onChange = { [weak self, weak node, weak child] in
                    guard let self, let node, let child, self.nestedArchives[id] === node else { return }
                    if let index = child.index {
                        let existing = self.itemLocations.filter { !$0.key.hasPrefix(id + "/") }
                        let paths = existing.values.reduce(0) { $0 + $1.entry.path.utf8.count }
                            + index.entries.reduce(0) { $0 + $1.path.utf8.count }
                        let depth = self.nodeDepth(id) + (index.entries.map { $0.path.split(separator: "/").count }.max() ?? 0)
                        if existing.count + index.entries.count - 1 > ArchiveReader.maximumEntries || paths > 32 * 1_024 * 1_024 || depth > ArchiveReader.maximumDepth {
                            child.index = nil
                            child.projectIndex()
                            child.message = ArchiveFailure.limit.localizedDescription
                        }
                    }
                    if child.needsPassword {
                        self.passwordTarget = child
                        self.passwordNodeID = id
                        self.passwordInput = ""
                        self.needsPassword = true
                    }
                    self.projectIndex()
                    self.objectWillChange.send()
                    self.onChange?()
                }
                child.load()
            } catch {
                guard let self, let node, !Task.isCancelled, self.nestedArchives[id] === node else { return }
                node.task = nil
                node.error = error.localizedDescription
                self.projectIndex()
                self.objectWillChange.send()
                self.handle(error, passwordTarget: origin) { [weak self] in self?.setArchiveExpanded(id, expanded: true) }
                if error as? ArchiveFailure == .password { self.passwordNodeID = id }
            }
        }
        projectIndex()
        objectWillChange.send()
        onChange?()
    }

    private func nodeDepth(_ id: String) -> Int {
        var depth = 0
        var parent = itemParents[id]
        while let current = parent { depth += 1; parent = itemParents[current] }
        return depth
    }

    private func isDescendant(_ candidate: String, of ancestor: String) -> Bool {
        var parent = itemParents[candidate]
        while let current = parent {
            if current == ancestor { return true }
            parent = itemParents[current]
        }
        return false
    }

    private func clearNestedArchives() {
        for node in nestedArchives.values {
            node.task?.cancel()
            node.session?.close()
        }
        nestedArchives.removeAll()
        passwordTarget = nil
        passwordNodeID = nil
        projectIndex()
    }

    private func projectIndex() {
        var items: [NavigatorItem] = []
        itemLocations = [:]
        itemParents = [:]
        archiveNodeIDs = []
        func append(_ index: ArchiveIndex, origin: ArchiveSession?, prefix: String, parent: String?) {
            let counts = index.entries.reduce(into: [String: Int]()) { $0[$1.path, default: 0] += 1 }
            for entry in index.entries {
                if parent != nil && entry.id == "root" { continue }
                let id = prefix + entry.id
                let parentID = entry.parentID.map { $0 == "root" && parent != nil ? parent! : prefix + $0 }
                itemLocations[id] = (origin, entry)
                itemParents[id] = parentID
                let isArchive = entry.isRegular && nestedArchives[id]?.isAudio != true && ArchiveReader.recognizes(URL(fileURLWithPath: entry.path))
                if isArchive { archiveNodeIDs.insert(id) }
                let node = nestedArchives[id]
                let subtitle = isLoadingArchiveNode(id) ? NSLocalizedString("Archive Loading Contents", comment: "") : (node?.error ?? node?.session?.message)
                items.append(NavigatorItem(id: id, parentID: parentID, title: entry.id == "root" ? source.name : entry.name,
                    subtitle: subtitle,
                    symbolName: entry.isDirectory ? "folder" : (isArchive ? "archivebox" : (entry.encrypted ? "lock.doc" : "doc")),
                    badge: counts[entry.path, default: 0] > 1 ? entry.ordinal.map { ($0 + 1).formatted() } : nil))
                if let child = node?.session, let childIndex = child.index {
                    append(childIndex, origin: child, prefix: id + "/", parent: id)
                }
            }
        }
        if let index { append(index, origin: nil, prefix: "", parent: nil) }
        projectedMediaKinds = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            mediaKind(for: item.id).map { (item.id, $0) }
        })
        cachedContribution = NavigatorContribution(id: navigatorContributionID, titleLocalizationKey: source.localFiles == nil ? "Archive Contents" : "Directory Contents", style: .outline,
            items: items, selectedItemIDs: [], allowedActions: [.activate])
    }

    var sidebarMode: CollectionSidebarMode { source.sidebarMode ?? .folder }
    var displayedContributions: [NavigatorContribution] {
        guard sidebarMode != .folder else { return [contribution] }
        if let contributions = preview?.navigatorContributions, !contributions.isEmpty { return contributions }
        let items = cachedContribution.items.filter { projectedMediaKinds[$0.id] == sidebarMode.kind }
        return [.init(id: navigatorContributionID, titleLocalizationKey: sidebarMode.titleKey, style: .flat,
                      items: items, selectedItemIDs: items.first.map { [$0.id] } ?? [], allowedActions: [.activate])]
    }

    private func localURL(for id: String) -> URL? {
        guard let files = source.localFiles, itemLocations[id]?.origin == nil,
              let ordinal = itemLocations[id]?.entry.ordinal,
              files.indices.contains(ordinal) else { return nil }
        return URL(fileURLWithPath: files[ordinal].path)
    }

    private func mediaKind(for id: String) -> FileListKind? {
        guard let entry = itemLocations[id]?.entry, entry.isRegular else { return nil }
        let url = localURL(for: id) ?? URL(fileURLWithPath: entry.path)
        switch FileListGrouper.classify(url: url) {
        case .listable(let kind): return kind
        case .cueSheets: return .audio
        case .other: return nil
        }
    }

    var availableSidebarModes: [CollectionSidebarMode] {
        let kinds = Set(projectedMediaKinds.values)
        return CollectionSidebarMode.allCases.filter { $0.kind.map { kinds.contains($0) } ?? true }
    }

    @discardableResult
    private func makePreview(lease: ArchivePreviewLease?) -> AppState {
        let state = AppState(isIncognito: windowState?.isIncognito ?? true)
        state.isArchivePreview = true
        state.archiveWindowOwner = windowState
        state.archivePreviewLease = lease
        state.isFullScreen = windowState?.isFullScreen ?? false
        state.showBorder = windowState?.showBorder ?? true
        state.showCodeLineNumbers = windowState?.showCodeLineNumbers ?? true
        preview = state
        previewObservation = state.objectWillChange.debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send(); self?.onChange?() }
        return state
    }

    /// 媒体模式复用普通文件列表和播放控制；提取任务按代次取消，并共同持有所有预览缓存。
    func setSidebarMode(_ mode: CollectionSidebarMode, restoring: Bool = false) {
        guard (restoring || mode != sidebarMode), availableSidebarModes.contains(mode) else { return }
        cancelPreview()
        source.sidebarMode = mode
        windowState?.endNavigatorSearch()
        windowState?.navigatorFocusedItemID = nil
        if mode == .folder {
            if let selectedID { select(selectedID) }
            onChange?()
            windowState?.saveState()
            return
        }
        let ids = cachedContribution.items.map(\.id).filter { projectedMediaKinds[$0] == mode.kind }
        guard !ids.isEmpty else { return }
        busy = true
        onChange?()
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var resolvedURLs: [String: URL] = [:]
                var groups: [(origin: ArchiveSession, ids: [String], entries: [ArchiveEntry])] = []
                for id in ids {
                    if let url = self.localURL(for: id) { resolvedURLs[id] = url; continue }
                    guard let location = self.itemLocations[id] else { continue }
                    let origin = location.origin ?? self
                    if let index = groups.firstIndex(where: { $0.origin === origin }) {
                        groups[index].ids.append(id)
                        groups[index].entries.append(location.entry)
                    } else { groups.append((origin, [id], [location.entry])) }
                }
                var leases: [ArchivePreviewLease] = []
                var total: Int64 = 0
                for group in groups {
                    try Task.checkCancellation()
                    guard let index = group.origin.index else { continue }
                    let lease = try await group.origin.workQueue.previewEntries(urls: group.origin.urls, index: index,
                        entries: group.entries, password: group.origin.password, limit: ArchiveReader.maximumExportBytes - total)
                    total += lease.byteCount
                    guard total <= ArchiveReader.maximumExportBytes else { throw ArchiveFailure.limit }
                    leases.append(lease)
                    for (id, entry) in zip(group.ids, group.entries) {
                        resolvedURLs[id] = lease.directory.appendingPathComponent(entry.path)
                    }
                }
                let mediaURLs = ids.compactMap { resolvedURLs[$0] }
                guard !Task.isCancelled, self.generation == token, let kind = mode.kind else { return }
                self.mediaEntryIDsByPath = Dictionary(ids.compactMap { id in
                    resolvedURLs[id].map { ($0.standardizedFileURL.path, id) }
                }, uniquingKeysWith: { first, _ in first })
                let lease = leases.first.map { first in
                    ArchivePreviewLease(directory: first.directory, byteCount: total, retaining: leases, removesDirectory: false)
                }
                let state = self.makePreview(lease: lease)
                if kind == .audio { state.installAudioList(urls: mediaURLs, preservesIdentity: true) }
                else { state.installFileList(kind: kind, urls: mediaURLs, preservesIdentity: true) }
                self.busy = false
                self.onChange?()
                self.windowState?.saveState()
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.busy = false
                self.handle(error) { [weak self] in self?.setSidebarMode(mode, restoring: true) }
            }
        }
    }

    func canOpenInNewFoil(_ id: String) -> Bool {
        guard itemLocations[id]?.entry.isRegular == true else { return false }
        if let url = localURL(for: id), let windowState {
            return windowState.initialFileOpenFailure(url) == nil
        }
        return true
    }

    func isFileEntry(_ id: String) -> Bool { itemLocations[id]?.entry.isRegular == true }

    func mediaEntryID(for url: URL) -> String? {
        mediaEntryIDsByPath[url.standardizedFileURL.path]
    }

    func fileInformation(_ id: String) async throws -> FoilInformation.Details? {
        guard let location = itemLocations[id], location.entry.isRegular else { return nil }
        if let url = localURL(for: id) {
            return await FoilInformation.fileDetails(url: url, displayName: location.entry.name)
        }
        let origin = location.origin ?? self
        guard let index = origin.index else { return nil }
        let lease = try? await origin.workQueue.preview(urls: origin.urls, index: index, entry: location.entry,
                                                        password: origin.password, limit: ArchiveReader.maximumExportBytes)
        let url = (lease?.directory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            .appendingPathComponent(location.entry.name)
        var components: [String] = []
        var current: String? = id
        while let item = current, let entry = itemLocations[item]?.entry {
            if entry.id != "root" { components.append(entry.name) }
            current = itemParents[item]
        }
        let details = await FoilInformation.fileDetails(url: url, displayName: location.entry.name,
            archivePath: ([source.name] + components.reversed()).joined(separator: "/"), archiveSize: location.entry.size)
        withExtendedLifetime(lease) {}
        return details
    }

    func openInNewFoil(_ id: String) {
        guard canOpenInNewFoil(id) else { return }
        let incognito = windowState?.isIncognito ?? true
        Task { [weak self] in
            guard let self, let location = self.itemLocations[id] else { return }
            do {
                let url: URL
                let lease: ArchivePreviewLease?
                if let local = self.localURL(for: id) { url = local; lease = nil }
                else {
                    let origin = location.origin ?? self
                    guard let index = origin.index else { return }
                    lease = try await origin.workQueue.preview(urls: origin.urls, index: index, entry: location.entry,
                        password: origin.password, limit: ArchiveReader.maximumExportBytes)
                    url = lease!.directory.appendingPathComponent(location.entry.name)
                }
                defer { withExtendedLifetime(lease) {} }
                let state = AppState(isIncognito: incognito)
                // 独立箔持有托管副本，关闭包预览或重启后仍能从历史打开。
                if lease != nil, let managedURL = state.managedBodyURL(extension: url.pathExtension) {
                    try await Task.detached(priority: .userInitiated) {
                        try ContentCache.shared.copy(from: url, to: managedURL)
                    }.value
                    ContentCache.shared.retain([managedURL.path])
                    defer { ContentCache.shared.release([managedURL.path]) }
                    state.openFile(url: managedURL)
                    state.ownedBodyPaths.insert(managedURL.path)
                    state.originalImageName = location.entry.name
                    state.customTitle = location.entry.name
                    state.saveState()
                } else {
                    state.openFile(url: url)
                }
                (NSApp.delegate as? AppDelegate)?.showNewWindow(with: state)
            } catch {
                self.handle(error) { [weak self] in self?.openInNewFoil(id) }
            }
        }
    }

    func load() {
        cancelPreview()
        clearNestedArchives()
        index = nil
        projectIndex()
        if windowState?.archiveSession === self { windowState?.expandedNavigatorItemIDs = ["root"] }
        selectedID = nil
        busy = true
        message = nil
        let token = generation
        let source = source
        let urls = urls, password = password, workQueue = workQueue
        let sourceLease = sourceLease
        task = Task { [weak self] in
            defer { withExtendedLifetime(sourceLease) {} }
            let worker = Task.detached(priority: .userInitiated) {
                if source.localFiles != nil { return source.localIndex() }
                return try await workQueue.scan(urls: urls, password: password)
            }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.index = result
                self.projectIndex()
                self.busy = false
                // 仅在首次打开时按普通文件占比选择；恢复或手动选择的模式优先。
                if self.windowState != nil {
                    let total = result.entries.filter(\.isRegular).count
                    let counts = self.projectedMediaKinds.values.reduce(into: [FileListKind: Int]()) { $0[$1, default: 0] += 1 }
                    let dominant = CollectionSidebarMode.allCases.first {
                        guard let kind = $0.kind, total > 0 else { return false }
                        return counts[kind, default: 0] > total * 2 / 3
                    }
                    self.source.dominantMediaMode = dominant
                    if self.source.sidebarMode == nil { self.source.sidebarMode = dominant ?? .folder }
                    self.windowState?.saveState()
                    self.prepareHistoryThumbnail(index: result, mode: dominant)
                }
                self.onChange?()
                if self.sidebarMode != .folder {
                    if self.availableSidebarModes.contains(self.sidebarMode) { self.setSidebarMode(self.sidebarMode, restoring: true) }
                    else { self.source.sidebarMode = .folder; self.onChange?() }
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.busy = false
                self.handle(error) { [weak self] in self?.load() }
            }
        }
        onChange?()
    }

    private func prepareHistoryThumbnail(index: ArchiveIndex, mode: CollectionSidebarMode?) {
        thumbnailTask?.cancel()
        guard let owner = windowState, !owner.isIncognito else { return }
        HistoryRepository.shared.updateThumbnailPath(id: owner.id, path: nil)
        HistoryManager.shared.refresh()
        guard let mode, let kind = mode.kind else { return }
        let matches = index.entries.filter { projectedMediaKinds[$0.id] == kind }
        let candidates = (mode == .audio ? matches : Array(matches.prefix(1))).map { ($0, localURL(for: $0.id)) }
        guard !candidates.isEmpty else { return }
        let id = owner.id
        let thumbnailSource = source
        let urls = urls, password = password, workQueue = workQueue
        thumbnailTask = Task { [self] in
            defer { withExtendedLifetime(self) {} }
            do {
                let destination = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("foofoil/Thumbnails/\(id.uuidString).heic")
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("foofoil-thumbnail-\(UUID().uuidString).heic")
                defer { try? FileManager.default.removeItem(at: temporary) }
                let historyKind: HistoryContentKind = mode == .image ? .image : (mode == .audio ? .audio : .video)
                var generated = false
                for (entry, local) in candidates {
                    guard !Task.isCancelled else { return }
                    let lease = local == nil ? try? await workQueue.preview(urls: urls, index: index, entry: entry, password: password,
                                                                            limit: ArchiveReader.maximumExportBytes) : nil
                    guard let url = local ?? lease?.directory.appendingPathComponent(entry.name) else { continue }
                    generated = await Task.detached(priority: .utility) {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() }; withExtendedLifetime(lease) {} }
                        return HistoryThumbnailGenerator.generateThumbnail(for: url, kind: historyKind, destinationURL: temporary)
                    }.value
                    if generated { break }
                }
                guard generated, !Task.isCancelled,
                      let current = HistoryRepository.shared.config(id: id)?.archiveSource,
                      current.volumes == thumbnailSource.volumes, current.localFiles == thumbnailSource.localFiles,
                      current.dominantMediaMode == mode else { return }
                let data = try Data(contentsOf: temporary)
                try ContentCache.shared.write(data, to: destination)
                HistoryRepository.shared.updateThumbnailPath(id: id, path: destination.path)
                HistoryManager.shared.refresh()
            } catch { /* 无法预览时保留类型图标。 */ }
        }
    }

    func cancelPreview() {
        generation = UUID()
        task?.cancel()
        task = nil
        previewObservation = nil
        if let preview {
            let delegate = NSApp.delegate as? AppDelegate
            delegate?.dismissColorPanel(ownedBy: preview)
            delegate?.dismissDocumentStylePanel(ownedBy: preview)
            SubtitleStylePanelController.shared.dismiss(ownedBy: preview)
            preview.endExtensionSessionOnWindowClose()
        }
        preview = nil
        busy = false
    }

    func close() {
        cancelPreview()
        clearNestedArchives()
        exportTask?.cancel()
        password = nil
        passwordInput = ""
        needsPassword = false
        retry = nil
        onChange = nil
        locateVolumes = nil
    }

    func select(_ id: String) {
        cancelPreview()
        selectedID = id
        message = nil
        onChange?()
        guard let entry = selected, !entry.isDirectory else { return }
        if let url = localURL(for: id) {
            let state = makePreview(lease: nil)
            state.openFile(url: url)
            onChange?()
            return
        }
        let isISO = (entry.name as NSString).pathExtension.lowercased() == "iso"
        guard !isArchiveNode(id) || isISO else { return }
        guard entry.isRegular else { message = NSLocalizedString("Archive Unsupported Entry", comment: ""); return }
        // 文件类型不设另一份白名单；统一交给普通打开入口。解压仍受总输出预算约束。
        let limit = ArchiveReader.maximumExportBytes
        guard entry.size.map({ $0 <= limit && $0 >= 0 }) ?? true else { message = NSLocalizedString("Archive Preview Limit", comment: ""); return }
        let origin = itemLocations[id]?.origin ?? self
        guard let index = origin.index else { return }
        busy = true
        let token = generation
        let urls = origin.urls, password = origin.password, workQueue = origin.workQueue, sourceLease = origin.sourceLease
        let rootQueue = self.workQueue, rootURLs = self.urls, rootIndex = source.localFiles == nil ? self.index : nil
        let cachedLease = nestedArchives[id]?.lease
        task = Task { [weak self] in
            defer { withExtendedLifetime(sourceLease) {} }
            let worker = Task.detached(priority: .userInitiated) {
                if let rootIndex { try await rootQueue.validate(urls: rootURLs, index: rootIndex) }
                if let cachedLease { return cachedLease }
                return try await workQueue.preview(urls: urls, index: index, entry: entry, password: password, limit: limit)
            }

            do {
                let lease = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled, self.generation == token else { return }
                if isISO {
                    let node = self.nestedArchives[id] ?? NestedArchive()
                    let cachedBytes = self.nestedArchives.values.reduce(Int64(0)) { $0 + ($1.lease?.byteCount ?? 0) } - (node.lease?.byteCount ?? 0)
                    guard lease.byteCount <= ArchiveReader.maximumExportBytes - cachedBytes else { throw ArchiveFailure.limit }
                    node.lease = lease
                    node.isAudio = ExtensionHost.shared.canOpenAsAudio(url: lease.directory.appendingPathComponent(entry.name))
                    self.nestedArchives[id] = node
                    self.projectIndex()
                    if !node.isAudio {
                        self.busy = false
                        self.onChange?()
                        return
                    }
                }
                let state = AppState(isIncognito: self.windowState?.isIncognito ?? true)
                state.isArchivePreview = true
                state.archiveWindowOwner = self.windowState
                state.isFullScreen = self.windowState?.isFullScreen ?? false
                state.archivePreviewLease = lease
                self.preview = state
                self.previewObservation = state.objectWillChange
                    .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
                    .sink { [weak self] _ in
                        // 派生阅读器异步完成后，也要刷新包内预览的失败占位状态。
                        self?.objectWillChange.send()
                        self?.onChange?()
                    }
                state.openFile(url: lease.directory.appendingPathComponent(entry.name))
                if let windowState = self.windowState {
                    state.showBorder = windowState.showBorder
                    state.showCodeLineNumbers = windowState.showCodeLineNumbers
                }
                self.busy = false
                self.onChange?()
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.busy = false
                self.handle(error, passwordTarget: origin) { [weak self] in self?.select(id) }
            }
        }
    }

    private func handle(_ error: Error, passwordTarget: ArchiveSession? = nil, retry: @escaping () -> Void) {
        message = error.localizedDescription
        if error as? ArchiveFailure == .changed {
            cancelPreview()
            clearNestedArchives()
            index = nil
            selectedID = nil
            projectIndex()
        }
        if error as? ArchiveFailure == .password {
            self.retry = retry
            self.passwordTarget = passwordTarget
            passwordInput = ""
            needsPassword = true
        }
        onChange?()
    }

    func unlock() {
        let input = passwordInput
        let target = passwordTarget ?? self
        passwordInput = ""
        needsPassword = false
        message = nil
        passwordTarget = nil
        passwordNodeID = nil
        let action = retry
        retry = nil
        if target !== self && target.needsPassword {
            target.passwordInput = input
            target.unlock()
        } else {
            target.password = input
            action?()
        }
    }

    func cancelUnlock() {
        let target = passwordTarget
        passwordTarget = nil
        passwordNodeID = nil
        passwordInput = ""
        needsPassword = false
        retry = nil
        if let target, target !== self { target.cancelUnlock() }
    }

    func saveSelected() {
        guard canExport, let entry = selected, let id = selectedID else { return }
        let origin = itemLocations[id]?.origin ?? self
        guard let index = origin.index else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.id == "root" ? source.primaryURL.deletingPathExtension().lastPathComponent : entry.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // 目录使用新目录名，禁止合并/覆盖已有目录；文件覆盖由 NSSavePanel 明确确认。
        if entry.isDirectory, FileManager.default.fileExists(atPath: destination.path) {
            message = NSLocalizedString("Archive Export Conflict", comment: ""); return
        }
        let entries = entry.isDirectory ? index.entries.filter { entry.path.isEmpty || $0.path == entry.path || $0.path.hasPrefix(entry.path + "/") } : [entry]
        let base = entry.isDirectory ? entry.path : (entry.path as NSString).deletingLastPathComponent
        exporting = true
        exportedBytes = 0
        message = nil
        let protectedURLs = self.urls + nestedArchives.values.flatMap { $0.session?.urls ?? [] }
        let rootQueue = self.workQueue, rootIndex = source.localFiles == nil ? self.index : nil, rootURLs = self.urls
        let urls = origin.urls, password = origin.password, workQueue = origin.workQueue, sourceLease = origin.sourceLease
        exportTask = Task { [weak self] in
            defer { withExtendedLifetime(sourceLease) {} }
            let accessed = destination.startAccessingSecurityScopedResource()
            defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
            let updateProgress: @Sendable (Int64) -> Void = { [weak self] bytes in
                Task { @MainActor [weak self] in self?.exportedBytes = bytes }
            }
            let worker = Task.detached(priority: .userInitiated) {
                if let rootIndex { try await rootQueue.validate(urls: rootURLs, index: rootIndex) }
                return try await workQueue.export(urls: urls, index: index, entries: entries, selection: entry,
                    destination: destination, basePath: base == "." ? "" : base, password: password, protectedURLs: protectedURLs,
                    progress: updateProgress)
            }
            do {
                let skipped = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self else { return }
                self.exporting = false
                self.message = String(format: NSLocalizedString("Archive Export Complete Format", comment: ""), skipped)
            } catch {
                guard let self else { return }
                self.exporting = false
                if !(error is CancellationError) { self.handle(error, passwordTarget: origin) { [weak self] in self?.saveSelected() } }
                else { self.message = NSLocalizedString("Archive Export Cancelled", comment: "") }
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }
}
