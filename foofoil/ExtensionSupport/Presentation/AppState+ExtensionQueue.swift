import Foundation
import FoofoilExtensionKit

/// 宿主文件列表与扩展队列之间的桥接。呈现与无缝序列按内容家族/能力；独占交接见阶段 5。
extension AppState {
    /// 同一非内置音频 Provider 的连续外部文件可共享会话；嗅探命中的容器单独打开。
    func contiguousExtensionAudioURLs(startingAt itemID: String) -> [URL] {
        guard let list = fileList, let index = list.items.firstIndex(where: { $0.id == itemID }),
              mediaPlaybackMode == .sequential || mediaPlaybackMode == .sequentialLoop else { return [] }
        var urls: [URL] = []
        var sharedProviderID: String?
        for item in list.items.dropFirst(index) {
            guard item.cue == nil, let url = resolvedURL(for: item) else { break }
            let candidates = ExtensionHost.shared.resolver.candidates(for: .singleFile(.init(url: url)))
            guard let candidate = candidates.first(where: { !$0.descriptor.isBuiltIn }),
                  candidate.descriptor.contentFamily == .audio else { break }
            if candidate.match.strength == .sniff { break }
            if let sharedProviderID, sharedProviderID != candidate.descriptor.id { break }
            sharedProviderID = candidate.descriptor.id
            urls.append(url)
        }
        return urls
    }

    /// 会话建立后把扩展队列 ID 盖到宿主列表项上，之后不再解析 ID 布局。
    /// 旧会话的盖章不能跨会话复用：先清除，再按新快照的资源对应关系重新映射。
    func stampHostListWithExtensionQueueIDs(_ session: ContentSession) {
        guard var list = fileList, session.playbackQueue != nil else { return }
        var changed = list.items.contains { $0.extensionItemID != nil }
        for index in list.items.indices {
            list.items[index].extensionItemID = nil
        }
        for index in list.items.indices {
            guard let id = ExtensionPlaybackSupport.queueItemID(for: list.items[index], in: session) else { continue }
            if list.items[index].extensionItemID != id {
                list.items[index].extensionItemID = id
                changed = true
            }
        }
        if changed { fileList = list }
    }

    /// 宿主对扩展播放队列的投影结果。宿主内部使用，不进入公共契约。
    enum HostPlaybackSequenceProjection: Equatable {
        /// 宿主无法可靠映射当前会话队列（含队列归扩展所有的单资源容器）；保持扩展队列不变。
        case unchanged
        /// 宿主确认的当前项与有效后继队列项 ID 顺序（含当前项）。
        case sequence([String])
        /// 当前项被宿主显式删除；只允许当前项收尾，不能续播旧列表。
        case currentOnly(String)
    }

    /// 区分“宿主确认的有效序列”“不改动”和“映射失效/显式删除”，不把映射失败解释为删除。
    func hostPlaybackSequenceProjection(
        for session: ContentSession,
        fileList explicitList: FileListState? = nil
    ) -> HostPlaybackSequenceProjection {
        // 单资源容器队列由扩展拥有，宿主只投影和转发动作，不按外部文件列表规则裁剪。
        if ExtensionPlaybackSupport.containerPlaybackQueue(from: session) != nil {
            return .unchanged
        }
        guard let queue = session.playbackQueue, let list = explicitList ?? fileList else {
            return .unchanged
        }
        guard let currentID = queue.currentItemID,
              let currentIndex = list.items.firstIndex(where: {
                  ExtensionPlaybackSupport.queueItemID(for: $0, in: session) == currentID
              }) else {
            // 无法定位当前项：只有宿主明确记录了删除意图才允许收尾，否则保持原队列。
            if let currentID = queue.currentItemID, extensionRemovedItemIDs.contains(currentID) {
                return .currentOnly(currentID)
            }
            return .unchanged
        }
        var ids: [String] = []
        for item in list.items.dropFirst(currentIndex) {
            guard let id = ExtensionPlaybackSupport.queueItemID(for: item, in: session) else { break }
            ids.append(id)
            if mediaPlaybackMode != .sequential && mediaPlaybackMode != .sequentialLoop { break }
        }
        guard !ids.isEmpty else { return .unchanged }
        return .sequence(ids)
    }

    /// 每次命令携带宿主允许的顺序；移除、排序或切换模式后废弃旧的预读后继。
    func sessionByApplyingHostPlaybackSequence(_ original: ContentSession) -> ContentSession {
        guard let queue = original.playbackQueue else { return original }
        let byID = Dictionary(uniqueKeysWithValues: queue.items.map { ($0.id, $0) })
        switch hostPlaybackSequenceProjection(for: original) {
        case .unchanged:
            return original
        case .currentOnly(let currentID):
            guard let current = byID[currentID] else { return original }
            var session = original
            session.playbackQueue?.items = [current]
            return session
        case .sequence(let ids):
            let items = ids.compactMap { byID[$0] }
            guard !items.isEmpty else { return original }
            var session = original
            session.playbackQueue?.items = items
            return session
        }
    }

    /// 记录宿主显式删除的扩展队列项目，供映射失效与用户删除的区分使用。
    func recordExtensionRemovals(in items: [FileListItem]) {
        guard let session = extensionSession, session.playbackQueue != nil else { return }
        for item in items {
            guard let id = extensionQueueItemID(for: item, in: session) else { continue }
            extensionRemovedItemIDs.insert(id)
        }
    }

    /// 不解析 ID 布局：依次尝试容器曲目 ID、会话盖章和不透明资源对应关系。
    func extensionQueueItemID(for item: FileListItem, in session: ContentSession) -> String? {
        let queueIDs = Set(session.playbackQueue?.items.map(\.id) ?? [])
        if let id = item.cue?.containerTrackID, queueIDs.contains(id) { return id }
        if let id = item.extensionItemID, queueIDs.contains(id) { return id }
        return ExtensionPlaybackSupport.queueItemID(for: item, in: session)
    }

    func synchronizeFileListWithExtensionQueue(_ session: ContentSession) {
        guard let currentID = session.playbackQueue?.currentItemID,
              var list = fileList,
              let item = list.items.first(where: { ExtensionPlaybackSupport.queueItemID(for: $0, in: session) == currentID }),
              list.currentID != item.id else { return }
        list.currentID = item.id
        fileList = list
        originalImageName = item.displayName
        holdExtensionAudioFileAccess(for: session)
        syncFileListNavigator()
    }

    func installExtensionContainerListIfNeeded(
        url: URL,
        session: ContentSession,
        preferredItemID: String?
    ) {
        guard let queue = ExtensionPlaybackSupport.containerPlaybackQueue(from: session) else { return }
        let normalizedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let alreadyInstalled = fileList?.items.contains(where: { item in
            item.cue != nil
                && item.url.resolvingSymlinksInPath().standardizedFileURL.path == normalizedPath
        }) == true
        if !alreadyInstalled {
            let bookmark = session.request.resources.first?.securityScopedBookmark
                ?? Self.makeSecurityScopedBookmark(for: url)
            installContainerAudioList(url: url, queue: queue, bookmark: bookmark)
        }
        if let preferredItemID,
           let preferredItem = fileList?.items.first(where: { $0.id == preferredItemID }),
           let containerTrackID = containerTrackID(for: preferredItem, in: queue),
           var list = fileList {
            list.currentID = preferredItemID
            fileList = list
            if containerTrackID != queue.currentItemID {
                if let contributionID = ExtensionPlaybackSupport.playbackContributionID(in: session) {
                    performNavigatorAction(
                        NavigatorAction(
                            contributionID: contributionID,
                            kind: .activate,
                            itemIDs: [containerTrackID]
                        )
                    )
                }
            }
        }
        syncFileListNavigator()
    }

    /// 同一容器会话内切歌，不重建 Session；扩展负责后续播放，此处只切换队列项。
    @discardableResult
    func activateExistingContainerTrack(_ item: FileListItem) -> Bool {
        guard let session = extensionSession,
              let queue = session.playbackQueue,
              let containerTrackID = containerTrackID(for: item, in: queue),
              let contributionID = ExtensionPlaybackSupport.playbackContributionID(in: session) else {
            return false
        }
        let sessionURL = session.request.primaryFileURL
        let itemURL = resolvedURL(for: item) ?? item.url
        if let sessionURL {
            let same = sessionURL.resolvingSymlinksInPath().standardizedFileURL.path
                == itemURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard same else { return false }
        }
        if queue.currentItemID != containerTrackID {
            performNavigatorAction(
                NavigatorAction(
                    contributionID: contributionID,
                    kind: .activate,
                    itemIDs: [containerTrackID]
                )
            )
        }
        return true
    }

    /// 只使用已保存的不透明 ID；不把曲目序号或 `file:` 布局当成协议。
    func containerTrackID(for item: FileListItem, in queue: MediaPlaybackQueueSnapshot) -> String? {
        if let id = item.cue?.containerTrackID,
           queue.items.contains(where: { $0.id == id }) {
            return id
        }
        if let id = item.extensionItemID, queue.items.contains(where: { $0.id == id }) {
            return id
        }
        if queue.items.contains(where: { $0.id == item.id }) {
            return item.id
        }
        return nil
    }
}
