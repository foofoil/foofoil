import Foundation
import FoofoilExtensionKit

/// 宿主内部播放呈现、队列投影与独占交接入口。
/// 独占交接按已协商设备服务，不把所有 `media.transport` 纳入抢占。
enum ExtensionPlaybackSupport {
    /// 有播放快照、内容家族为音频，且已协商 `media.transport`（旧 Hi-Fi 兼容期暂放行）时才复用宿主音频 UI。
    static func usesHostAudioChrome(_ session: ContentSession) -> Bool {
        guard session.mediaPlayback != nil else { return false }
        guard MediaPlaybackRequest.isSupported(by: session) || HiFiLegacyAdapter.supports(session) else {
            return false
        }
        if let family = resolvedContentFamily(for: session) {
            return family == .audio
        }
        return true
    }

    /// 通用呈现只有在会话存在播放快照且实际协商 `media.transport` 时才显示可交互媒体控件；
    /// 否则只能显示只读状态，不能发送媒体动作。
    static func showsInteractiveMediaControls(_ session: ContentSession) -> Bool {
        session.mediaPlayback != nil && MediaPlaybackRequest.isSupported(by: session)
    }

    static func resolvedContentFamily(for session: ContentSession) -> ExtensionContentFamily? {
        ExtensionHost.shared.resolver.provider(id: session.providerID)?.descriptor.contentFamily
    }

    static func presentationURL(in session: ContentSession, fileList: FileListState? = nil) -> URL? {
        guard usesHostAudioChrome(session) else { return nil }
        return authorizedResource(in: session, fileList: fileList)?.url ?? session.request.primaryFileURL
    }

    /// 单资源容器用该资源；多文件集合用宿主列表上的不透明 ID 盖章，或资源与队列一一对应。
    static func authorizedResource(in session: ContentSession, fileList: FileListState? = nil) -> ExtensionResource? {
        let resources = session.request.resources
        guard !resources.isEmpty else { return nil }
        if resources.count == 1 { return resources[0] }
        guard let currentID = session.playbackQueue?.currentItemID else { return resources.first }
        if let item = fileList?.items.first(where: {
            $0.extensionItemID == currentID || $0.cue?.containerTrackID == currentID
        }) {
            let path = standardizedPath(item.url)
            return resources.first { standardizedPath($0.url) == path } ?? resources.first
        }
        if let queue = session.playbackQueue,
           queue.items.count == resources.count,
           let index = queue.items.firstIndex(where: { $0.id == currentID }) {
            return resources[index]
        }
        return resources.first
    }

    static func isActionAvailable(_ action: MediaPlaybackActionKind, in session: ContentSession) -> Bool {
        session.mediaPlayback?.allows(action, queueItemCount: session.playbackQueue?.items.count ?? 0) ?? false
    }

    static func isOutputDeviceEnabled(_ deviceID: String, in session: ContentSession) -> Bool {
        if let device = session.audioDeviceSelection?.devices.first(where: { $0.id == deviceID }),
           !device.isConnected {
            return false
        }
        if session.mediaPlayback?.availableActions != nil,
           !isActionAvailable(.selectDevice, in: session) {
            return false
        }
        if HiFiLegacyAdapter.supports(session) {
            return HiFiLegacyAdapter.isDeviceEnabled(deviceID, in: session)
        }
        return true
    }

    static func playbackContributionID(in session: ContentSession) -> String? {
        if let queue = session.playbackQueue {
            let ids = Set(queue.items.map(\.id))
            if let id = session.navigatorContributions.first(where: { contribution in
                contribution.items.contains { ids.contains($0.id) }
            })?.id {
                return id
            }
        }
        return session.navigatorContributions.first?.id
    }

    static func queueItemID(for item: FileListItem, in session: ContentSession) -> String? {
        guard let queue = session.playbackQueue else { return nil }
        if let id = item.cue?.containerTrackID, queue.items.contains(where: { $0.id == id }) {
            return id
        }
        if let id = item.extensionItemID, queue.items.contains(where: { $0.id == id }) {
            return id
        }
        let resources = session.request.resources
        guard queue.items.count == resources.count,
              let resourceIndex = resources.firstIndex(where: {
                  standardizedPath($0.url) == standardizedPath(item.url)
              }) else { return nil }
        return queue.items[resourceIndex].id
    }

    fileprivate static func standardizedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func showsPlaybackIndicator(
        for contribution: NavigatorContribution, session: ContentSession?
    ) -> Bool {
        guard let session, usesHostAudioChrome(session),
              let id = playbackContributionID(in: session) else { return false }
        return contribution.id == id
    }

    static func acceptsGaplessCollection(_ session: ContentSession) -> Bool {
        usesHostAudioChrome(session)
    }

    static func containerPlaybackQueue(from session: ContentSession) -> MediaPlaybackQueueSnapshot? {
        guard session.request.resources.count <= 1,
              let queue = session.playbackQueue, queue.items.count >= 2 else { return nil }
        return queue
    }

    /// 已协商 `audio.device-selection` 或会话带设备快照时，跨窗口 PCM/DSD 才走独占交接。
    static func usesDeviceService(_ session: ContentSession) -> Bool {
        AudioDeviceServiceRequest.isDeclared(in: session.capabilities.map(\.declaration))
            || session.audioDeviceSelection != nil
    }

    static func requiresExclusiveHandoff(_ session: ContentSession) -> Bool {
        usesHostAudioChrome(session) && usesDeviceService(session)
    }

    static func legacyMediaAction(for commandID: String, in session: ContentSession) -> MediaPlaybackAction? {
        HiFiLegacyAdapter.mediaAction(for: commandID, in: session)
    }
}
