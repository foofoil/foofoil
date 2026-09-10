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
    func stampHostListWithExtensionQueueIDs(_ session: ContentSession) {
        guard var list = fileList, session.playbackQueue != nil else { return }
        var changed = false
        for index in list.items.indices {
            guard let id = ExtensionPlaybackSupport.queueItemID(for: list.items[index], in: session),
                  list.items[index].extensionItemID != id else { continue }
            list.items[index].extensionItemID = id
            changed = true
        }
        if changed { fileList = list }
    }

    /// 每次命令携带宿主允许的顺序；移除、排序或切换模式后废弃旧的预读后继。
    func sessionByApplyingHostPlaybackSequence(_ original: ContentSession) -> ContentSession {
        guard original.playbackQueue != nil, var queue = original.playbackQueue,
              let list = fileList else { return original }
        var session = original
        let currentID = queue.currentItemID
        var ids: [String] = []
        if let index = list.items.firstIndex(where: { ExtensionPlaybackSupport.queueItemID(for: $0, in: original) == currentID }) {
            for item in list.items.dropFirst(index) {
                guard let id = ExtensionPlaybackSupport.queueItemID(for: item, in: original),
                      queue.items.contains(where: { $0.id == id }) else { break }
                ids.append(id)
                if mediaPlaybackMode != .sequential && mediaPlaybackMode != .sequentialLoop { break }
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: queue.items.map { ($0.id, $0) })
        queue.items = ids.compactMap { byID[$0] }
        // 当前曲已从宿主列表移除时仍允许其收尾，但不能续播旧列表。
        if queue.items.isEmpty, let currentID, let item = byID[currentID] { queue.items = [item] }
        session.playbackQueue = queue
        return session
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
