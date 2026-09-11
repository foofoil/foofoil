import Foundation
import FoofoilExtensionKit
import Testing
@testable import foofoil

private enum HandoffTestError: Error, Equatable {
    case release
    case start
}

extension ExtensionKitTests {
@MainActor
@Suite
struct ExclusiveHandoffFailureTests {
    /// 释放失败时保留旧持有者、阻止同设备新 start，并且只重试一次释放。
    @Test(arguments: ["PCM→ext", "ext→PCM", "ext→ext"])
    func releaseFailureBlocksNewStartAcrossHandoffPairs(pair: String) async throws {
        let coordinator = ExclusivePlaybackCoordinator()
        let first = UUID(), second = UUID()
        var releaseAttempts = 0
        var startCount = 0
        try await coordinator.perform(deviceID: "dac", ownerID: first, pause: {
            releaseAttempts += 1
            throw HandoffTestError.release
        }, start: {})
        #expect(releaseAttempts == 0, "\(pair): 首次登记不应触发释放")

        await #expect(throws: ExclusivePlaybackCoordinator.HandoffError.self) {
            try await coordinator.perform(
                deviceID: "dac", ownerID: second,
                pause: {}, start: { startCount += 1 }
            )
        }
        #expect(releaseAttempts == 2, "\(pair): 至多重试一次释放")
        #expect(startCount == 0, "\(pair): 释放失败后新 start 必须为零")
        #expect(coordinator.hasOwner(deviceID: "dac", otherThan: second), "\(pair): 旧持有者记录必须保留")
    }

    /// 释放恢复后再次请求可以成功完成交接。
    @Test func releaseRecoveryAllowsNextHandoff() async throws {
        let coordinator = ExclusivePlaybackCoordinator()
        let first = UUID(), second = UUID()
        var failing = true
        try await coordinator.perform(deviceID: "dac", ownerID: first, pause: {
            if failing { throw HandoffTestError.release }
        }, start: {})
        await #expect(throws: ExclusivePlaybackCoordinator.HandoffError.self) {
            try await coordinator.perform(deviceID: "dac", ownerID: second, pause: {}, start: {})
        }
        failing = false
        var started = false
        try await coordinator.perform(deviceID: "dac", ownerID: second, pause: {}, start: { started = true })
        #expect(started)
        #expect(!coordinator.hasOwner(deviceID: "dac", otherThan: second))
    }

    /// 一个设备的释放失败不应阻塞另一个设备或系统输出路径。
    @Test func releaseFailureOnOneDeviceDoesNotBlockAnother() async throws {
        let coordinator = ExclusivePlaybackCoordinator()
        let first = UUID(), second = UUID(), third = UUID(), fourth = UUID()
        try await coordinator.perform(deviceID: "a", ownerID: first, pause: {
            throw HandoffTestError.release
        }, start: {})
        var startedB = false
        try await coordinator.perform(deviceID: "b", ownerID: second, pause: {}, start: { startedB = true })
        #expect(startedB)

        await #expect(throws: ExclusivePlaybackCoordinator.HandoffError.self) {
            try await coordinator.perform(deviceID: "a", ownerID: third, pause: {}, start: {
                Issue.record("冲突设备不应启动新输出")
            })
        }
        var secondTakeover = false
        try await coordinator.perform(deviceID: "b", ownerID: fourth, pause: {}, start: { secondTakeover = true })
        #expect(secondTakeover)
    }

    /// 取消/过期结果不应暂停旧持有者或启动新输出。
    @Test func cancelBeforeReleaseDoesNotPauseOrStart() async throws {
        let coordinator = ExclusivePlaybackCoordinator()
        let first = UUID(), second = UUID()
        var paused = false, started = false
        try await coordinator.perform(deviceID: "dac", ownerID: first, pause: { paused = true }, start: {})
        await #expect(throws: CancellationError.self) {
            try await coordinator.perform(
                deviceID: "dac", ownerID: second, pause: {}, isCurrent: { false },
                start: { started = true }
            )
        }
        #expect(!paused)
        #expect(!started)
        #expect(coordinator.hasOwner(deviceID: "dac", otherThan: second))
    }

    /// 新获取失败时不登记新持有者。
    @Test func startFailureDoesNotRegisterNewOwner() async throws {
        let coordinator = ExclusivePlaybackCoordinator()
        let first = UUID()
        await #expect(throws: HandoffTestError.self) {
            try await coordinator.perform(deviceID: "dac", ownerID: first, pause: {}, start: {
                throw HandoffTestError.start
            })
        }
        #expect(!coordinator.hasOwner(deviceID: "dac"))
    }

    /// Provider 关闭失败必须能从 `closeSessionAndWait` 观察，而不是只写日志。
    @Test func closeSessionAndWaitPropagatesProviderFailure() async throws {
        let provider = FailingCloseTestProvider()
        let host = ExtensionHost.shared
        host.resolver.register(provider)
        defer { host.resolver.unregister(providerID: provider.descriptor.id) }
        let session = try await provider.makeSession(
            for: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/close.dsf"))), negotiatedAPI: 1
        )
        await #expect(throws: HandoffTestError.self) {
            try await host.closeSessionAndWait(session)
        }
        #expect(provider.closeCount == 1)
    }

    /// 可重试的关闭成功时正常返回并保留幂等计数。
    @Test func closeSessionAndWaitSucceedsForIdempotentProvider() async throws {
        let provider = FailingCloseTestProvider()
        provider.shouldFail = false
        let host = ExtensionHost.shared
        host.resolver.register(provider)
        defer { host.resolver.unregister(providerID: provider.descriptor.id) }
        let session = try await provider.makeSession(
            for: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/close-ok.dsf"))), negotiatedAPI: 1
        )
        try await host.closeSessionAndWait(session)
        try await host.closeSessionAndWait(session)
        #expect(provider.closeCount == 2)
    }
}
}

@MainActor
private final class FailingCloseTestProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.failing-close", extensionID: nil, role: .primary,
        fallbackProviderID: nil, enhancementDomain: nil, contentFamily: .audio, filenameExtensions: [],
        isEnabled: true, isRuntimeAvailable: true
    )
    var shouldFail = true
    var closeCount = 0

    func match(_ request: ContentRequest) -> ProviderMatch? { nil }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        ContentSession(
            extensionID: nil, providerID: descriptor.id, request: request,
            presentation: .text(titleKey: "Test", body: "Close")
        )
    }

    func closeSession(_ session: ContentSession) async throws {
        closeCount += 1
        if shouldFail { throw HandoffTestError.release }
    }
}
