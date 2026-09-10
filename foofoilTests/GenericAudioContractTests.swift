import Foundation
import FoofoilExtensionKit
import Testing
@testable import foofoil

@MainActor
struct GenericAudioContractTests {
    @Test func genericProviderExpressesTransportNavigationRestoreAndClose() async throws {
        let provider = GenericAudioTestProvider()
        let host = ExtensionHost.shared
        host.resolver.register(provider)
        defer { host.resolver.unregister(providerID: provider.descriptor.id) }

        var session = try await provider.makeSession(
            for: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/generic.gaud"))), negotiatedAPI: 1
        )
        #expect(session.providerID == "test.generic-audio")
        #expect(!session.navigatorContributions.contains { $0.id.contains("hifi") })
        #expect(session.playbackQueue?.items.map(\.id) == ["item-a", "item-b"])
        #expect(session.mediaPlayback?.allows(.play) == true)
        #expect(session.mediaPlayback?.allows(.pause) == false)

        session = try await host.perform(mediaAction: .play, in: session)
        #expect(session.mediaPlayback?.state == .playing)
        #expect(session.mediaPlayback?.allows(.pause) == true)
        session = try await host.perform(mediaAction: .pause, in: session)
        session = try await host.perform(mediaAction: .seek(1.5), in: session)
        #expect(session.mediaPlayback?.position == 1.5)

        session = try await host.perform(
            navigatorAction: .init(contributionID: "generic.playback-queue", kind: .activate, itemIDs: ["item-b"]),
            in: session
        )
        #expect(session.playbackQueue?.currentItemID == "item-b")

        let saved = session
        var fresh = try await provider.makeSession(
            for: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/generic.gaud"))), negotiatedAPI: 1
        )
        fresh = try await host.restorePlayback(from: saved, in: fresh)
        #expect(fresh.id != saved.id)
        #expect(fresh.playbackQueue?.currentItemID == "item-b")
        #expect(fresh.mediaPlayback?.position == 1.5)
        #expect(fresh.mediaPlayback?.state == .paused)

        try await provider.closeSession(fresh)
        try await provider.closeSession(fresh)
        #expect(provider.closeCount == 2)
        #expect(HiFiLegacyAdapter.mediaAction(for: "hifi.play", in: session) == nil)
        #expect(ExtensionPlaybackSupport.usesHostAudioChrome(session))
        #expect(ExtensionPlaybackSupport.presentationURL(in: session)?.pathExtension == "gaud")
        #expect(!ExtensionPlaybackSupport.requiresExclusiveHandoff(session))
        #expect(ExtensionPlaybackSupport.acceptsGaplessCollection(session))
        #expect(ExtensionPlaybackSupport.playbackContributionID(in: session) == "generic.playback-queue")
        #expect(ExtensionPlaybackSupport.showsPlaybackIndicator(
            for: session.navigatorContributions[0], session: session
        ))
        #expect(!ExtensionPlaybackSupport.showsPlaybackIndicator(
            for: NavigatorContribution(
                id: "hifi.playback-queue", titleLocalizationKey: "Queue", style: .flat, items: []
            ),
            session: session
        ))

        let state = AppState()
        defer {
            state.extensionSession = nil
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        state.extensionSession = session
        #expect(state.isAudioDocument)
        #expect(state.currentAudioPresentationURL?.pathExtension == "gaud")
    }

    @Test func staleMediaResultDoesNotReplaceNewerSession() async throws {
        let provider = GateableAudioTestProvider()
        let host = ExtensionHost.shared
        host.resolver.register(provider)
        defer { host.resolver.unregister(providerID: provider.descriptor.id) }

        let first = try await provider.makeSession(
            for: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/first.gaud"))), negotiatedAPI: 1
        )
        let second = try await provider.makeSession(
            for: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/second.gaud"))), negotiatedAPI: 1
        )
        #expect(first.id != second.id)

        let state = AppState()
        defer {
            state.extensionSession = nil
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        state.extensionSession = first
        state.performExtensionMediaAction(.play)
        for _ in 0..<100 where provider.mediaActions.isEmpty {
            await Task.yield()
        }
        #expect(!provider.mediaActions.isEmpty)
        state.extensionSession = second
        state.exclusivePlaybackGeneration &+= 1
        provider.releaseGate()
        for _ in 0..<100 where !provider.didFinish {
            await Task.yield()
        }
        #expect(provider.didFinish)
        #expect(state.extensionSession?.id == second.id)
        #expect(state.extensionSession?.mediaPlayback?.state != .playing)
    }

    @Test func explicitUnavailableActionIsRejectedBeforeProviderWork() async throws {
        let provider = GenericAudioTestProvider()
        var session = try await provider.makeSession(
            for: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/generic.gaud"))), negotiatedAPI: 1
        )
        session.mediaPlayback?.availableActions = [.pause, .refresh]
        let request = MediaPlaybackRequest(action: .play, session: session)
        #expect(throws: MediaTransportError.actionUnavailable) { try request.validate() }
        #expect(provider.mediaActions.isEmpty)
    }

    /// 显式禁用 seek 时不能发送请求，也不能修改权威会话位置。
    @Test func seekIsNotSentWhenActionIsUnavailable() async throws {
        let provider = GenericAudioTestProvider()
        let host = ExtensionHost.shared
        host.resolver.register(provider)
        defer { host.resolver.unregister(providerID: provider.descriptor.id) }
        var session = try await provider.makeSession(
            for: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/generic.gaud"))), negotiatedAPI: 1
        )
        session.mediaPlayback?.availableActions = [.play, .pause, .refresh]

        let state = AppState()
        defer {
            state.extensionSession = nil
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        state.extensionSession = session
        let before = state.extensionSession?.mediaPlayback?.position
        state.seekExtensionPlayback(to: 7)
        for _ in 0..<50 { await Task.yield() }
        #expect(provider.mediaActions.isEmpty)
        #expect(state.extensionSession?.mediaPlayback?.position == before)
    }

    /// 连续 seek 时旧回包必须被丢弃，不能覆盖后发 seek 的结果。
    @Test func staleSeekResultDoesNotOverwriteNewerSeek() async throws {
        let provider = GatedSeekTestProvider()
        let host = ExtensionHost.shared
        host.resolver.register(provider)
        defer { host.resolver.unregister(providerID: provider.descriptor.id) }
        let session = try await provider.makeSession(
            for: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/gated.gaud"))), negotiatedAPI: 1
        )

        let state = AppState()
        defer {
            state.extensionSession = nil
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        state.extensionSession = session

        state.seekExtensionPlayback(to: 3)
        state.seekExtensionPlayback(to: 9)
        for _ in 0..<200 where provider.mediaActions.count < 2 { await Task.yield() }
        #expect(provider.mediaActions.count == 2)

        // 先放行旧 seek（目标 3），它必须被序号校验丢弃，不能覆盖尚未回包的权威位置。
        await provider.releaseSeek(toPosition: 3)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(state.extensionSession?.mediaPlayback?.position == 0)

        // 再放行新 seek（目标 9），它才应更新会话快照。
        await provider.releaseSeek(toPosition: 9)
        for _ in 0..<200 where state.extensionSession?.mediaPlayback?.position != 9 { await Task.yield() }
        #expect(state.extensionSession?.mediaPlayback?.position == 9)
        #expect(state.extensionSession?.id == session.id)
    }

    @Test func deviceServiceDiscoveryPrefersUniqueOrPreferredExtension() {
        #expect(ExtensionAudioDeviceDiscovery.extensionID(amongCapable: ["app.foofoil.extension.hifi"], preferredExtensionID: nil) == "app.foofoil.extension.hifi")
        #expect(ExtensionAudioDeviceDiscovery.extensionID(
            amongCapable: ["app.foofoil.extension.other", "app.foofoil.extension.hifi"],
            preferredExtensionID: "app.foofoil.extension.hifi"
        ) == "app.foofoil.extension.hifi")
        #expect(ExtensionAudioDeviceDiscovery.extensionID(
            amongCapable: ["app.foofoil.extension.other", "app.foofoil.extension.hifi"],
            preferredExtensionID: nil
        ) == nil)
        #expect(ExtensionAudioDeviceDiscovery.extensionID(
            amongCapable: [],
            preferredExtensionID: "app.foofoil.extension.hifi"
        ) == nil)
        #expect(!ExtensionPlaybackSupport.usesDeviceService(ContentSession(
            extensionID: nil, providerID: "test.generic-audio",
            request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/generic.gaud"))),
            presentation: .text(titleKey: "Generic Audio", body: "generic.gaud"),
            capabilities: [
                .init(declaration: .init(id: ExtensionCapabilityIdentifier.mediaTransport, scope: .session), state: .active)
            ],
            mediaPlayback: .init(state: .paused, position: 0, duration: 10, isSeekable: true)
        )))
        #expect(ContentProbeRequest.isDeclared(in: [
            .init(id: ExtensionCapabilityIdentifier.contentProbe, scope: .application)
        ]))
    }
}

@MainActor
private final class GenericAudioTestProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.generic-audio", extensionID: "app.foofoil.extension.test-generic-audio",
        role: .primary, fallbackProviderID: nil, enhancementDomain: "audio", contentFamily: .audio,
        filenameExtensions: ["gaud"], isEnabled: true, isRuntimeAvailable: true
    )
    var mediaActions: [MediaPlaybackAction] = []
    var closeCount = 0

    func match(_ request: ContentRequest) -> ProviderMatch? {
        request.primaryFileURL?.pathExtension.lowercased() == "gaud"
            ? ProviderMatch(strength: .fileExtension, explanation: "generic-audio")
            : nil
    }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        var session = ContentSession(
            extensionID: descriptor.extensionID, providerID: descriptor.id, request: request,
            presentation: .text(titleKey: "Generic Audio", body: request.primaryFileURL?.lastPathComponent ?? ""),
            capabilities: [
                .init(declaration: .init(id: ExtensionCapabilityIdentifier.mediaTransport, scope: .session), state: .active),
                .init(declaration: .init(id: ExtensionCapabilityIdentifier.navigatorActions, scope: .presentation), state: .active),
                .init(declaration: .init(id: ExtensionCapabilityIdentifier.sessionLifecycle, scope: .session), state: .active),
                .init(declaration: .init(id: ExtensionCapabilityIdentifier.seekable, scope: .session), state: .active),
                .init(declaration: .init(id: ExtensionCapabilityIdentifier.mediaPlaybackQueue, scope: .session), state: .active),
                .init(declaration: .init(id: ExtensionCapabilityIdentifier.navigator, scope: .presentation), state: .active)
            ],
            navigatorContributions: [
                .init(
                    id: "generic.playback-queue", titleLocalizationKey: "Queue", style: .flat,
                    items: [
                        .init(id: "item-a", title: "A", isCurrent: true),
                        .init(id: "item-b", title: "B")
                    ],
                    selectedItemIDs: ["item-a"], allowedActions: [.activate, .move]
                )
            ],
            mediaPlayback: .init(state: .paused, position: 0, duration: 10, isSeekable: true),
            playbackQueue: .init(
                items: [.init(id: "item-a", title: "A", duration: 5), .init(id: "item-b", title: "B", duration: 5)],
                currentItemID: "item-a", title: "Generic Album"
            )
        )
        var playback = session.mediaPlayback
        playback?.availableActions = Self.actions(for: session)
        session.mediaPlayback = playback
        return session
    }

    func perform(mediaAction: MediaPlaybackAction, session: ContentSession) async throws -> ContentSession {
        mediaActions.append(mediaAction)
        var updated = session
        switch mediaAction {
        case .play: updated.mediaPlayback?.state = .playing
        case .pause: updated.mediaPlayback?.state = .paused
        case .seek(let position): updated.mediaPlayback?.position = position
        case .next, .previous:
            let ids = updated.playbackQueue?.items.map(\.id) ?? []
            if let current = updated.playbackQueue?.currentItemID, let index = ids.firstIndex(of: current) {
                let next = mediaAction == .next
                    ? ids[(index + 1) % ids.count]
                    : ids[(index - 1 + ids.count) % ids.count]
                updated.playbackQueue?.currentItemID = next
            }
        default: break
        }
        var playback = updated.mediaPlayback
        playback?.availableActions = Self.actions(for: updated)
        updated.mediaPlayback = playback
        return updated
    }

    func perform(navigatorAction: NavigatorAction, session: ContentSession) async throws -> ContentSession {
        guard navigatorAction.kind == .activate, let itemID = navigatorAction.itemIDs.first else { return session }
        var updated = session
        updated.playbackQueue?.currentItemID = itemID
        if let index = updated.navigatorContributions.firstIndex(where: { $0.id == navigatorAction.contributionID }) {
            updated.navigatorContributions[index].selectedItemIDs = [itemID]
            updated.navigatorContributions[index].items = updated.navigatorContributions[index].items.map {
                var item = $0
                item.isCurrent = item.id == itemID
                return item
            }
        }
        return updated
    }

    func restorePlayback(from saved: ContentSession, in fresh: ContentSession) async throws -> ContentSession {
        guard let request = ExtensionSessionLifecycle.restorationRequest(from: saved, in: fresh) else { return fresh }
        var restored = request.session
        if let itemID = request.restoration?.currentItemID,
           restored.playbackQueue?.items.contains(where: { $0.id == itemID }) == true {
            restored.playbackQueue?.currentItemID = itemID
        }
        restored.mediaPlayback?.position = request.restoration?.position ?? 0
        restored.mediaPlayback?.state = .paused
        var playback = restored.mediaPlayback
        playback?.availableActions = Self.actions(for: restored)
        restored.mediaPlayback = playback
        return restored
    }

    func closeSession(_ session: ContentSession) async throws {
        closeCount += 1
    }

    func perform(commandID: String, session: ContentSession) async throws -> ContentSession { session }

    private static func actions(for session: ContentSession) -> [MediaPlaybackActionKind] {
        var actions: [MediaPlaybackActionKind] = [.refresh, .seek, .previous, .next]
        if session.mediaPlayback?.state == .playing {
            actions.append(.pause)
        } else {
            actions.append(.play)
        }
        return actions
    }
}

@MainActor
private final class GateableAudioTestProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.gateable-audio", extensionID: "app.foofoil.extension.test-gateable-audio",
        role: .primary, fallbackProviderID: nil, enhancementDomain: "audio", contentFamily: .audio,
        filenameExtensions: ["gaud"], isEnabled: true, isRuntimeAvailable: true
    )
    var mediaActions: [MediaPlaybackAction] = []
    var didFinish = false
    private var gate: CheckedContinuation<Void, Never>?

    func match(_ request: ContentRequest) -> ProviderMatch? { nil }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        ContentSession(
            extensionID: descriptor.extensionID, providerID: descriptor.id, request: request,
            presentation: .text(titleKey: "Generic Audio", body: request.primaryFileURL?.lastPathComponent ?? ""),
            capabilities: [
                .init(declaration: .init(id: ExtensionCapabilityIdentifier.mediaTransport, scope: .session), state: .active)
            ],
            mediaPlayback: .init(state: .paused, position: 0, duration: 10, isSeekable: true)
        )
    }

    func perform(mediaAction: MediaPlaybackAction, session: ContentSession) async throws -> ContentSession {
        mediaActions.append(mediaAction)
        await withCheckedContinuation { continuation in
            gate = continuation
        }
        didFinish = true
        var updated = session
        updated.mediaPlayback?.state = .playing
        return updated
    }

    func releaseGate() {
        gate?.resume()
        gate = nil
    }
}

/// 允许多个 seek 同时在途并按目标位置放行，用于验证过期回包不会覆盖新状态。
@MainActor
private final class GatedSeekTestProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.gated-seek", extensionID: "app.foofoil.extension.test-gated-seek",
        role: .primary, fallbackProviderID: nil, enhancementDomain: "audio", contentFamily: .audio,
        filenameExtensions: ["gaud"], isEnabled: true, isRuntimeAvailable: true
    )
    var mediaActions: [MediaPlaybackAction] = []
    private var pending: [(action: MediaPlaybackAction, session: ContentSession, continuation: CheckedContinuation<ContentSession, Never>)] = []

    func match(_ request: ContentRequest) -> ProviderMatch? { nil }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        ContentSession(
            extensionID: descriptor.extensionID, providerID: descriptor.id, request: request,
            presentation: .text(titleKey: "Generic Audio", body: request.primaryFileURL?.lastPathComponent ?? ""),
            capabilities: [
                .init(declaration: .init(id: ExtensionCapabilityIdentifier.mediaTransport, scope: .session), state: .active),
                .init(declaration: .init(id: ExtensionCapabilityIdentifier.seekable, scope: .session), state: .active)
            ],
            mediaPlayback: .init(state: .paused, position: 0, duration: 100, isSeekable: true)
        )
    }

    func perform(mediaAction: MediaPlaybackAction, session: ContentSession) async throws -> ContentSession {
        mediaActions.append(mediaAction)
        return await withCheckedContinuation { continuation in
            pending.append((mediaAction, session, continuation))
        }
    }

    /// 按 seek 目标位置放行，避免依赖并发任务的入队顺序。
    func releaseSeek(toPosition position: Double) async {
        guard let index = pending.firstIndex(where: {
            if case .seek(let value) = $0.action { return value == position }
            return false
        }) else { return }
        let item = pending.remove(at: index)
        var updated = item.session
        updated.mediaPlayback?.position = position
        item.continuation.resume(returning: updated)
    }
}
