import Foundation
import FoofoilExtensionKit

/// 宿主内部播放呈现、队列投影与独占交接入口。
/// 独占交接按已协商设备服务，不把所有 `media.transport` 纳入抢占。
enum ExtensionPlaybackSupport {
    /// 有播放快照、内容家族为音频，且已协商 `media.transport` 时才复用宿主音频 UI。
    static func usesHostAudioChrome(_ session: ContentSession) -> Bool {
        guard session.mediaPlayback != nil else { return false }
        guard MediaPlaybackRequest.isSupported(by: session) else { return false }
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
        if let item = fileList?.items.first(where: { queueItemID(for: $0, in: session) == currentID }) {
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
           !device.isConnected || !device.isCompatible {
            return false
        }
        if session.mediaPlayback?.availableActions != nil,
           !isActionAvailable(.selectDevice, in: session) {
            return false
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
        let resources = session.request.resources
        let itemPath = standardizedPath(item.url)
        // 容器曲目 ID 常按内部序号生成，多个容器会重名；先按资源路径确认条目属于当前会话，
        // 否则高亮、封面和队列投影会把另一张专辑的同号曲目当成当前项。
        if resources.contains(where: { standardizedPath($0.url) == itemPath }) {
            if let id = item.cue?.containerTrackID, queue.items.contains(where: { $0.id == id }) {
                return id
            }
            if let id = item.extensionItemID, queue.items.contains(where: { $0.id == id }) {
                return id
            }
        }
        guard queue.items.count == resources.count,
              let resourceIndex = resources.firstIndex(where: {
                  standardizedPath($0.url) == itemPath
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
            && session.audioDeviceSelection?.followsSystemDefault != true
    }

    /// 跟随系统默认时与宿主 PCM 右上角一致：在设备/格式状态后标明「跟随系统默认」。
    /// APE 扩展只回设备名或 PCM 格式，不带该标记；DSD 没有跟随模式，原样返回。
    static func outputStatusTitle(for selection: AudioDeviceSelectionSnapshot) -> String {
        let status = selection.statusDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard selection.followsSystemDefault == true else { return status }
        let followLabel = NSLocalizedString("System Default Output", comment: "")
        if status.isEmpty || status == followLabel { return followLabel }
        if status.contains(followLabel) { return status }
        return "\(status) · \(followLabel)"
    }
}
