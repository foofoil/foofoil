import Foundation
import Testing
@testable import foofoil

@MainActor
struct AudioPlaybackCoordinatorTests {
    @Test func changingSourceWaitsForReleaseAndInvalidatesOldPlayback() async throws {
        let coordinator = AudioPlaybackCoordinator()
        let music = UUID(), local = UUID()
        var events: [String] = []
        let first = try await coordinator.acquire(ownerID: music, pause: {
            events.append("pause music")
            await Task.yield()
            events.append("released")
        })
        let second = try await coordinator.acquire(ownerID: local, pause: {})
        events.append("start local")
        #expect(events == ["pause music", "released", "start local"])
        #expect(!coordinator.isCurrent(ownerID: music, token: first))
        #expect(coordinator.isCurrent(ownerID: local, token: second))
    }

    @Test func pauseDuringPreparationPreventsLatePlayback() async throws {
        let coordinator = AudioPlaybackCoordinator()
        let music = UUID()
        let token = try await coordinator.acquire(ownerID: music, pause: {})
        coordinator.cancel(ownerID: music)
        #expect(!coordinator.isCurrent(ownerID: music, token: token))
        #expect(!coordinator.isOwner(music))
    }

    @Test func oldPauseCallbackCannotCancelNewClaim() async throws {
        let coordinator = AudioPlaybackCoordinator()
        let old = UUID(), next = UUID()
        _ = try await coordinator.acquire(ownerID: old, pause: { coordinator.cancel(ownerID: old) })
        let token = try await coordinator.acquire(ownerID: next, pause: {})
        #expect(coordinator.isCurrent(ownerID: next, token: token))
    }

    @Test func onlyLatestConcurrentRequestGetsPlayback() async throws {
        let coordinator = AudioPlaybackCoordinator()
        let first = UUID(), second = UUID(), last = UUID()
        var resume: CheckedContinuation<Void, Never>?
        _ = try await coordinator.acquire(ownerID: first, pause: {
            await withCheckedContinuation { resume = $0 }
        })
        let pending = Task { try await coordinator.acquire(ownerID: second, pause: {}) }
        while resume == nil { await Task.yield() }
        var requested = false
        let latest = Task {
            requested = true
            return try await coordinator.acquire(ownerID: last, pause: {})
        }
        while !requested { await Task.yield() }
        resume?.resume()
        await #expect(throws: CancellationError.self) { try await pending.value }
        let token = try await latest.value
        #expect(coordinator.isCurrent(ownerID: last, token: token))
        #expect(!coordinator.isOwner(second))
    }

    @Test func delayedLibraryLookupCannotOverrideNewerLocalPlay() async throws {
        let coordinator = AudioPlaybackCoordinator()
        let music = UUID(), local = UUID()
        let delayed = coordinator.request(ownerID: music)
        let localToken = try await coordinator.acquire(ownerID: local, pause: {})
        await #expect(throws: CancellationError.self) {
            try await coordinator.acquire(ownerID: music, requestToken: delayed, pause: {})
        }
        #expect(coordinator.isCurrent(ownerID: local, token: localToken))
    }

    @Test func sameOwnerWaitsForPendingCloseBeforeRestarting() async throws {
        let coordinator = AudioPlaybackCoordinator()
        let audio = UUID()
        var released = false
        _ = try await coordinator.acquire(ownerID: audio, pause: {})
        coordinator.retainPendingRelease(ownerID: audio, pending: PendingOutputRelease { released = true })
        _ = try await coordinator.acquire(ownerID: audio, pause: {})
        #expect(released)
    }

    @Test func failedReleaseBlocksNewPlaybackAndCanRetry() async throws {
        enum ReleaseError: Error { case failed }
        let coordinator = AudioPlaybackCoordinator()
        let old = UUID(), next = UUID()
        var failing = true
        _ = try await coordinator.acquire(ownerID: old, pause: {
            if failing { throw ReleaseError.failed }
        })
        await #expect(throws: ReleaseError.self) {
            try await coordinator.acquire(ownerID: next, pause: {})
        }
        #expect(!coordinator.isOwner(next))
        failing = false
        let token = try await coordinator.acquire(ownerID: next, pause: {})
        #expect(coordinator.isCurrent(ownerID: next, token: token))
    }
}
