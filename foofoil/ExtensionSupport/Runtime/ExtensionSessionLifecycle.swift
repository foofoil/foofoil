import FoofoilExtensionKit

enum ExtensionSessionLifecycle {
    /// 只从旧快照取通用恢复值，不重放旧 Session UUID，也不恢复播放意图。
    /// 播放会话恢复当前曲目；文档会话没有播放队列，回退到目录选中项以恢复阅读位置。
    static func restorationRequest(from saved: ContentSession, in fresh: ContentSession) -> SessionLifecycleRequest? {
        guard saved.providerID == fresh.providerID,
              SessionLifecycleRequest.isSupported(by: fresh) else { return nil }
        let position = (saved.mediaPlayback?.position).flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        }
        let currentItemID = saved.playbackQueue?.currentItemID
            ?? saved.navigatorContributions.first(where: { !$0.selectedItemIDs.isEmpty })?.selectedItemIDs.first
        return SessionLifecycleRequest(
            operation: .restore, session: fresh,
            restoration: .init(currentItemID: currentItemID, position: position)
        )
    }
}
