import Foundation
import FoofoilExtensionKit

/// 宿主内部播放呈现、队列投影与独占交接入口。当前委托 Hi-Fi 兼容层，以保持现有行为。
/// 阶段 4 改为内容家族与已协商媒体能力；阶段 3 接管容器探测与私有 ID；阶段 5 按设备服务能力决定独占。
enum ExtensionPlaybackSupport {
    static func usesHostAudioChrome(_ session: ContentSession) -> Bool {
        session.mediaPlayback != nil && HiFiLegacyAdapter.supports(session)
    }

    static func presentationURL(in session: ContentSession) -> URL? {
        guard usesHostAudioChrome(session) else { return nil }
        return HiFiLegacyAdapter.currentURL(in: session)
    }

    static func authorizedResource(in session: ContentSession) -> ExtensionResource? {
        HiFiLegacyAdapter.currentResource(in: session)
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
        if let id = item.cue?.containerTrackID,
           session.playbackQueue?.items.contains(where: { $0.id == id }) == true {
            return id
        }
        return HiFiLegacyAdapter.legacyQueueItemID(for: item, in: session)
    }

    static func showsPlaybackIndicator(
        for contribution: NavigatorContribution, session: ContentSession?
    ) -> Bool {
        guard let session else { return false }
        return contribution.id == HiFiLegacyAdapter.playbackQueueID && usesHostAudioChrome(session)
    }

    static func acceptsGaplessCollection(_ session: ContentSession) -> Bool {
        HiFiLegacyAdapter.supports(session)
    }

    static func containerPlaybackQueue(from session: ContentSession) -> MediaPlaybackQueueSnapshot? {
        guard session.request.resources.count <= 1,
              let queue = session.playbackQueue, queue.items.count >= 2 else { return nil }
        return queue
    }

    static func requiresExclusiveHandoff(_ session: ContentSession) -> Bool {
        HiFiLegacyAdapter.supports(session)
    }

    static func legacyMediaAction(for commandID: String, in session: ContentSession) -> MediaPlaybackAction? {
        HiFiLegacyAdapter.mediaAction(for: commandID, in: session)
    }
}
