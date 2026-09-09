import Foundation
import FoofoilExtensionKit

extension HiFiLegacyAdapter {
    /// 新会话先选容器曲目再定位；只发送不取得设备的命令，不恢复旧的播放意图。
    static func restorePlayback(
        saved: ContentSession,
        fresh: ContentSession,
        activate: (String, ContentSession) async throws -> ContentSession,
        seek: (ContentSession) async throws -> ContentSession
    ) async throws -> ContentSession {
        guard saved.providerID == HiFiLegacyAdapter.providerID, fresh.providerID == saved.providerID else { return fresh }
        var restored = fresh
        if let trackID = saved.playbackQueue?.currentItemID {
            // 文件可能已被替换；旧曲目不存在时不能把它的进度套到第一曲。
            guard restored.playbackQueue?.items.contains(where: { $0.id == trackID && $0.isPlayable }) == true else {
                return restored
            }
            if restored.playbackQueue?.currentItemID != trackID {
                restored = try await activate(trackID, restored)
            }
        }
        guard let savedPlayback = saved.mediaPlayback,
              savedPlayback.position.isFinite, savedPlayback.position >= 0,
              var playback = restored.mediaPlayback, playback.isSeekable else { return restored }
        playback.position = min(savedPlayback.position, playback.duration ?? savedPlayback.position)
        playback.state = .paused
        restored.mediaPlayback = playback
        return try await seek(restored)
    }
}
