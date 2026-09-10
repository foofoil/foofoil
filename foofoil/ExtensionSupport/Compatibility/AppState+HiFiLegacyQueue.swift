import Foundation
import FoofoilExtensionKit

/// 旧 Hi-Fi 队列与宿主文件列表之间的过渡桥接。
/// 阶段 3 下沉容器曲目与私有 ID；阶段 4 按通用贡献 ID 传递操作，不再在此解释 `file:` 前缀。
extension AppState {
    /// 连续 DSF/DFF 可共享会话。阶段 3 改为由扩展声明可衔接的格式，而不是宿主写死后缀。
    func contiguousExtensionAudioURLs(startingAt itemID: String) -> [URL] {
        guard let list = fileList, let index = list.items.firstIndex(where: { $0.id == itemID }),
              mediaPlaybackMode == .sequential || mediaPlaybackMode == .sequentialLoop else { return [] }
        var urls: [URL] = []
        for item in list.items.dropFirst(index) {
            guard item.cue == nil, ["dsf", "dff"].contains(item.url.pathExtension.lowercased()),
                  let url = resolvedURL(for: item) else { break }
            urls.append(url)
        }
        return urls
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

    /// 同一 SACD ISO 会话内切歌，不重建 Session、不重配 HAL。
    /// 自然播完后由 Hi-Fi Runtime 在 activate 时继续播放下一曲；此处只切换队列项。
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

    /// 新列表显式保存容器内部 ID；旧版持久化数据则按原 ID 或曲目序号兼容恢复。
    func containerTrackID(for item: FileListItem, in queue: MediaPlaybackQueueSnapshot) -> String? {
        if let id = item.cue?.containerTrackID,
           queue.items.contains(where: { $0.id == id }) {
            return id
        }
        if queue.items.contains(where: { $0.id == item.id }) {
            return item.id
        }
        if let number = item.cue?.trackNumber.flatMap(Int.init) {
            let index = number - 1
            if queue.items.indices.contains(index) {
                return queue.items[index].id
            }
        }
        return nil
    }
}
