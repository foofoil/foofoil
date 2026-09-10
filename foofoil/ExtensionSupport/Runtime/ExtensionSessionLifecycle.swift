import FoofoilExtensionKit

enum ExtensionSessionLifecycle {
    /// 只从旧快照取通用恢复值，不重放旧 Session UUID，也不恢复播放意图。
    static func restorationRequest(from saved: ContentSession, in fresh: ContentSession) -> SessionLifecycleRequest? {
        guard saved.providerID == fresh.providerID,
              SessionLifecycleRequest.isSupported(by: fresh) else { return nil }
        let position = (saved.mediaPlayback?.position).flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        }
        return SessionLifecycleRequest(
            operation: .restore, session: fresh,
            restoration: .init(currentItemID: saved.playbackQueue?.currentItemID, position: position)
        )
    }
}
