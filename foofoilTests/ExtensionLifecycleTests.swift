import Foundation
import FoofoilExtensionKit
import Testing
@testable import foofoil

// 与现有共享 Host 测试使用同一串行 Suite，注册的测试 Provider 不跨用例残留。
extension ExtensionKitTests {
    @Test func defaultProviderLifecycleDoesNotReceiveHiFiCommands() async throws {
        let provider = DefaultLifecycleTestProvider()
        let host = ExtensionHost.shared
        host.resolver.register(provider)
        defer { host.resolver.unregister(providerID: provider.descriptor.id) }
        let fresh = try await provider.makeSession(for: lifecycleRequest, negotiatedAPI: 1)
        var saved = fresh
        saved.mediaPlayback = .init(position: 42, duration: 100)
        let restored = try await host.restorePlayback(from: saved, in: fresh)
        #expect(restored == fresh)
        try await host.closeSessionAndWait(fresh)
        #expect(provider.commands.isEmpty)
    }

    @Test(arguments: [false, true])
    func hostRoutesAndValidatesProviderRestoration(invalid: Bool) async throws {
        let provider = RestoringLifecycleTestProvider()
        provider.invalidRestoration = invalid
        let host = ExtensionHost.shared
        host.resolver.register(provider)
        defer { host.resolver.unregister(providerID: provider.descriptor.id) }
        let fresh = try await provider.makeSession(for: lifecycleRequest, negotiatedAPI: 1)
        var saved = fresh
        saved.mediaPlayback = .init(position: 42, duration: 100)
        if invalid {
            await #expect(throws: MediaSessionContractError.invalidPlaybackPosition) {
                try await host.restorePlayback(from: saved, in: fresh)
            }
        } else {
            let restored = try await host.restorePlayback(from: saved, in: fresh)
            #expect(restored.mediaPlayback?.position == 42)
            #expect(restored.id == fresh.id)
        }
        #expect(provider.restoreCount == 1)
    }

    @Test func providerChangeSkipsRestorationHook() async throws {
        let provider = RestoringLifecycleTestProvider()
        let host = ExtensionHost.shared
        host.resolver.register(provider)
        defer { host.resolver.unregister(providerID: provider.descriptor.id) }
        let fresh = try await provider.makeSession(for: lifecycleRequest, negotiatedAPI: 1)
        let saved = ContentSession(
            extensionID: nil, providerID: "previous.provider", request: lifecycleRequest,
            presentation: .text(titleKey: "Test", body: "Previous")
        )
        #expect(try await host.restorePlayback(from: saved, in: fresh) == fresh)
        #expect(provider.restoreCount == 0)
    }

    @Test func legacyCloseIsAwaitedAndNeverSentToUnrelatedProvider() async throws {
        let provider = DefaultLifecycleTestProvider()
        let unrelated = try await provider.makeSession(for: lifecycleRequest, negotiatedAPI: 1)
        try await HiFiLegacyAdapter.closeSession(unrelated, provider: provider)
        #expect(provider.commands.isEmpty)
        let legacy = ContentSession(
            extensionID: nil, providerID: "audio.hifi", request: lifecycleRequest,
            presentation: .text(titleKey: "Test", body: "DSD")
        )
        try await HiFiLegacyAdapter.closeSession(legacy, provider: provider)
        #expect(provider.commands == ["hifi.close"])
        #expect(provider.commandCompleted)
    }

    @Test(arguments: [false, true])
    func legacyRestoreValidatesActivationBeforeSeeking(invalid: Bool) async throws {
        let provider = RestoringLifecycleTestProvider()
        provider.invalidRestoration = invalid
        var fresh = ContentSession(
            extensionID: nil, providerID: "audio.hifi", request: lifecycleRequest,
            presentation: .text(titleKey: "Test", body: "DSD"),
            navigatorContributions: [.init(
                id: "hifi.playback-queue", titleLocalizationKey: "Queue", style: .flat,
                items: [.init(id: "a", title: "A"), .init(id: "b", title: "B")]
            )]
        )
        fresh.mediaPlayback = .init(duration: 100, isSeekable: true)
        fresh.playbackQueue = .init(
            items: [.init(id: "a", title: "A"), .init(id: "b", title: "B")], currentItemID: "a"
        )
        var saved = fresh
        saved.playbackQueue?.currentItemID = "b"
        saved.mediaPlayback?.position = 42
        if invalid {
            await #expect(throws: MediaSessionContractError.invalidPlaybackPosition) {
                try await HiFiLegacyAdapter.restorePlayback(saved: saved, fresh: fresh, provider: provider)
            }
            #expect(provider.events == ["activate:b"])
        } else {
            let restored = try await HiFiLegacyAdapter.restorePlayback(saved: saved, fresh: fresh, provider: provider)
            #expect(provider.events == ["activate:b", "hifi.seek"])
            #expect(restored.mediaPlayback?.position == 42)
            #expect(restored.mediaPlayback?.state == .paused)
            #expect(restored.id == fresh.id)
        }
    }

    @Test func inProcessDeviceServicePreservesRequestAndRunsOffMainThread() async throws {
        let request = AudioDeviceServiceRequest(
            command: .releasePCM, clientID: UUID(), selectedDeviceID: "test-dac",
            sourceSampleRate: 96000, channelCount: 2
        )
        let service = InProcessAudioDeviceService { received in
            #expect(!Thread.isMainThread)
            #expect(received == request)
            return AudioDeviceServiceSnapshot(devices: [], activeClientID: received.clientID)
        }
        let result = try await service.perform(request)
        #expect(result.activeClientID == request.clientID)
    }

    @Test func inProcessDeviceServicePropagatesRuntimeFailure() async throws {
        let service = InProcessAudioDeviceService { _ in
            throw ContentProviderError.unsupportedRequest
        }
        await #expect(throws: ContentProviderError.unsupportedRequest) {
            try await service.perform(.init(command: .snapshot, clientID: UUID()))
        }
    }

    private var lifecycleRequest: ContentRequest {
        .singleFile(.init(url: URL(fileURLWithPath: "/tmp/lifecycle-test.dsf")))
    }
}

@MainActor
private final class DefaultLifecycleTestProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.default-lifecycle", extensionID: nil, role: .primary,
        fallbackProviderID: nil, enhancementDomain: nil, contentFamily: .audio, filenameExtensions: [],
        isEnabled: true, isRuntimeAvailable: true
    )
    var commands: [String] = []
    var commandCompleted = false

    func match(_ request: ContentRequest) -> ProviderMatch? { nil }
    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        ContentSession(
            extensionID: nil, providerID: descriptor.id, request: request,
            presentation: .text(titleKey: "Test", body: "Default")
        )
    }
    func perform(commandID: String, session: ContentSession) async throws -> ContentSession {
        commands.append(commandID)
        await Task.yield()
        commandCompleted = true
        return session
    }
}

@MainActor
private final class RestoringLifecycleTestProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.custom-lifecycle", extensionID: nil, role: .primary,
        fallbackProviderID: nil, enhancementDomain: nil, contentFamily: .audio, filenameExtensions: [],
        isEnabled: true, isRuntimeAvailable: true
    )
    var invalidRestoration = false
    var restoreCount = 0
    var events: [String] = []

    func match(_ request: ContentRequest) -> ProviderMatch? { nil }
    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        ContentSession(
            extensionID: nil, providerID: descriptor.id, request: request,
            presentation: .text(titleKey: "Test", body: "Custom")
        )
    }
    func restorePlayback(from saved: ContentSession, in fresh: ContentSession) async throws -> ContentSession {
        restoreCount += 1
        var restored = fresh
        restored.mediaPlayback = .init(position: invalidRestoration ? -1 : saved.mediaPlayback?.position ?? 0, duration: 100)
        return restored
    }
    func perform(navigatorAction: NavigatorAction, session: ContentSession) async throws -> ContentSession {
        var updated = session
        let selected = navigatorAction.itemIDs[0]
        events.append("activate:\(selected)")
        updated.playbackQueue?.currentItemID = selected
        if invalidRestoration { updated.mediaPlayback?.position = -1 }
        return updated
    }
    func perform(commandID: String, session: ContentSession) async throws -> ContentSession {
        events.append(commandID)
        return session
    }
}
