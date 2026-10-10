import Foundation

/// 全应用只允许一个音频输出；交接只等待旧输出释放，不等待 MusicKit 网络准备，避免阻塞其它箔。
@MainActor
final class AudioPlaybackCoordinator {
    static let shared = AudioPlaybackCoordinator()
    private struct Owner {
        let id: UUID
        let pause: @MainActor () async throws -> Void
        var pending: PendingOutputRelease? = nil
    }
    private var owner: Owner?
    private var requestedOwnerID: UUID?
    private var generation: UInt64 = 0
    private var tail: Task<Void, Error>?

    /// 在用户发出意图时就登记代次；资料库查询期间的新操作也能使旧请求失效。
    func request(ownerID: UUID) -> UInt64 {
        generation &+= 1
        requestedOwnerID = ownerID
        return generation
    }

    func acquire(ownerID: UUID, requestToken: UInt64? = nil, pause: @escaping @MainActor () async throws -> Void,
                 isCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> UInt64 {
        let token = requestToken ?? request(ownerID: ownerID)
        let preceding = tail
        let task = Task { @MainActor in
            _ = try? await preceding?.value
            guard token == self.generation, isCurrent() else { throw CancellationError() }
            if let old = self.owner, old.id != ownerID || old.pending != nil {
                // 释放失败时保留旧持有者，阻止新音频抢占设备；下一次操作可以重试。
                try await old.pause()
                self.owner = nil
            }
            guard token == self.generation, isCurrent() else { throw CancellationError() }
            self.owner = Owner(id: ownerID, pause: pause)
        }
        tail = task
        try await task.value
        return token
    }

    /// 窗口销毁后仍保留实际释放操作；同一播放器重新起播也必须先等释放完成。
    func retainPendingRelease(ownerID: UUID, pending: PendingOutputRelease) {
        guard owner?.id == ownerID else { return }
        owner = Owner(id: ownerID, pause: { try await pending.release() }, pending: pending)
    }

    func isCurrent(ownerID: UUID, token: UInt64) -> Bool {
        token == generation && isOwner(ownerID)
    }

    func isOwner(_ ownerID: UUID) -> Bool {
        owner?.id == ownerID && requestedOwnerID == ownerID
    }

    /// 旧输出的暂停回调不能取消正在申请交接的新输出。
    func cancel(ownerID: UUID) {
        guard requestedOwnerID == ownerID else { return }
        generation &+= 1
        requestedOwnerID = nil
    }
}
