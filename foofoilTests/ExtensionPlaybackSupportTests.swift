import Foundation
import FoofoilExtensionKit
import Testing
@testable import foofoil

@MainActor
struct ExtensionPlaybackSupportTests {
    private func session(
        providerID: String,
        mediaPlayback: Bool = true,
        queueIDs: [String] = ["file:0", "file:1"],
        currentItemID: String = "file:1",
        contributionID: String? = nil,
        transportCapability: Bool = true
    ) -> ContentSession {
        let queueContributionID = contributionID
            ?? (providerID == "audio.hifi" ? "hifi.playback-queue" : "generic.playback-queue")
        var capabilities: [NegotiatedCapability] = []
        if transportCapability && mediaPlayback {
            capabilities.append(.init(
                declaration: .init(id: ExtensionCapabilityIdentifier.mediaTransport, scope: .session),
                state: .active
            ))
        }
        if providerID == "audio.hifi" {
            capabilities.append(.init(
                declaration: .init(id: ExtensionCapabilityIdentifier.deviceSelector, scope: .application),
                state: .active
            ))
        }
        return ContentSession(
            extensionID: nil,
            providerID: providerID,
            request: .fileCollection([
                .init(url: URL(fileURLWithPath: "/tmp/first.dsf")),
                .init(url: URL(fileURLWithPath: "/tmp/second.dsf"))
            ]),
            presentation: .text(titleKey: "Test", body: "Fixture"),
            capabilities: capabilities,
            navigatorContributions: [
                .init(
                    id: queueContributionID, titleLocalizationKey: "Queue", style: .flat,
                    items: queueIDs.map { .init(id: $0, title: $0) }
                )
            ],
            mediaPlayback: mediaPlayback ? .init(state: .paused, position: 1, duration: 10, isSeekable: true) : nil,
            playbackQueue: .init(
                items: queueIDs.map { .init(id: $0, title: $0) },
                currentItemID: currentItemID
            )
        )
    }

    @Test func genericAudioProviderReusesHostChromeWithoutExclusiveHandoff() {
        let generic = session(providerID: "test.generic-audio")
        #expect(ExtensionPlaybackSupport.usesHostAudioChrome(generic))
        #expect(ExtensionPlaybackSupport.showsInteractiveMediaControls(generic))
        #expect(ExtensionPlaybackSupport.presentationURL(in: generic)?.lastPathComponent == "second.dsf")
        #expect(!ExtensionPlaybackSupport.requiresExclusiveHandoff(generic))
        #expect(!ExtensionPlaybackSupport.usesDeviceService(generic))
        #expect(ExtensionPlaybackSupport.acceptsGaplessCollection(generic))
        #expect(ExtensionPlaybackSupport.containerPlaybackQueue(from: generic) == nil)
        let playbackContribution = NavigatorContribution(
            id: "generic.playback-queue", titleLocalizationKey: "Queue", style: .flat,
            items: [.init(id: "file:1", title: "second")]
        )
        #expect(ExtensionPlaybackSupport.showsPlaybackIndicator(for: playbackContribution, session: generic))
        #expect(!ExtensionPlaybackSupport.showsPlaybackIndicator(
            for: NavigatorContribution(
                id: "hifi.playback-queue", titleLocalizationKey: "Queue", style: .flat,
                items: [.init(id: "file:1", title: "second")]
            ),
            session: generic
        ))

        let state = AppState()
        defer {
            state.extensionSession = nil
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        state.extensionSession = generic
        #expect(state.isAudioDocument)
        #expect(state.currentAudioPresentationURL?.lastPathComponent == "second.dsf")
    }

    @Test func sessionWithoutTransportCapabilityDoesNotTakeAudioChrome() {
        let other = session(providerID: "test.content", mediaPlayback: true, transportCapability: false)
        #expect(other.mediaPlayback != nil)
        #expect(!MediaPlaybackRequest.isSupported(by: other))
        #expect(!ExtensionPlaybackSupport.usesHostAudioChrome(other))
        #expect(!ExtensionPlaybackSupport.showsInteractiveMediaControls(other))
        #expect(ExtensionPlaybackSupport.presentationURL(in: other) == nil)
        #expect(!ExtensionPlaybackSupport.acceptsGaplessCollection(other))
        #expect(!ExtensionPlaybackSupport.requiresExclusiveHandoff(other))
    }

    /// 音频家族且有播放快照，但没有协商 `media.transport` 时，专用音频界面与通用可交互控件都必须关闭。
    @Test func audioFamilyWithoutTransportOnlyShowsReadOnlyStatus() {
        let provider = AudioFamilyNoTransportTestProvider()
        ExtensionHost.shared.resolver.register(provider)
        defer { ExtensionHost.shared.resolver.unregister(providerID: provider.descriptor.id) }
        let session = ContentSession(
            extensionID: nil,
            providerID: provider.descriptor.id,
            request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/readonly.nta"))),
            presentation: .text(titleKey: "Test", body: "Fixture"),
            mediaPlayback: .init(state: .paused, position: 1, duration: 10, isSeekable: true)
        )
        #expect(session.mediaPlayback != nil)
        #expect(ExtensionPlaybackSupport.resolvedContentFamily(for: session) == .audio)
        #expect(!MediaPlaybackRequest.isSupported(by: session))
        #expect(!ExtensionPlaybackSupport.usesHostAudioChrome(session))
        #expect(!ExtensionPlaybackSupport.showsInteractiveMediaControls(session))
        #expect(ExtensionPlaybackSupport.presentationURL(in: session) == nil)
    }

    @Test func hiFiSessionUsesPublicChromeQueueAndHandoff() {
        let hifi = session(providerID: "audio.hifi")
        #expect(ExtensionPlaybackSupport.usesHostAudioChrome(hifi))
        #expect(ExtensionPlaybackSupport.presentationURL(in: hifi)?.lastPathComponent == "second.dsf")
        #expect(ExtensionPlaybackSupport.requiresExclusiveHandoff(hifi))
        #expect(ExtensionPlaybackSupport.usesDeviceService(hifi))
        #expect(ExtensionPlaybackSupport.acceptsGaplessCollection(hifi))
        #expect(ExtensionPlaybackSupport.containerPlaybackQueue(from: hifi) == nil)
        let contribution = NavigatorContribution(
            id: "hifi.playback-queue", titleLocalizationKey: "Queue", style: .flat,
            items: [.init(id: "file:1", title: "second")]
        )
        #expect(ExtensionPlaybackSupport.showsPlaybackIndicator(for: contribution, session: hifi))
        #expect(!ExtensionPlaybackSupport.showsPlaybackIndicator(
            for: NavigatorContribution(id: "other.queue", titleLocalizationKey: "Queue", style: .flat, items: []),
            session: hifi
        ))

        let state = AppState()
        defer {
            state.extensionSession = nil
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        state.extensionSession = hifi
        #expect(state.isAudioDocument)
        #expect(state.currentAudioPresentationURL?.lastPathComponent == "second.dsf")
    }

    /// 设备菜单可用性只来自公共设备连接快照与 `availableActions`，不再读旧 command 的 isEnabled。
    @Test func outputDeviceEnabledFollowsPublicAvailabilityAndConnection() {
        var session = session(providerID: "audio.hifi")
        session.audioDeviceSelection = .init(devices: [
            .init(id: "connected", displayName: "Connected"),
            .init(id: "gone", displayName: "Gone", isConnected: false)
        ])
        session.mediaPlayback?.availableActions = [.refresh, .seek, .selectDevice, .play]
        #expect(ExtensionPlaybackSupport.isOutputDeviceEnabled("connected", in: session))
        #expect(!ExtensionPlaybackSupport.isOutputDeviceEnabled("gone", in: session))

        session.mediaPlayback?.availableActions = [.refresh, .seek, .play]
        #expect(!ExtensionPlaybackSupport.isOutputDeviceEnabled("connected", in: session))
    }

    @Test func deviceSnapshotEnablesExclusiveHandoffWithoutHiFiProviderID() {
        var generic = session(providerID: "test.generic-audio")
        #expect(!ExtensionPlaybackSupport.requiresExclusiveHandoff(generic))
        generic.audioDeviceSelection = .init(devices: [
            .init(id: "dac", displayName: "DAC")
        ])
        #expect(ExtensionPlaybackSupport.usesDeviceService(generic))
        #expect(ExtensionPlaybackSupport.requiresExclusiveHandoff(generic))
    }

    @Test func genericContainerQueueInstallsWithoutHiFiProviderID() {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        let items = [
            FileListItem(id: "host:0", path: "/tmp/disc.iso", displayName: "disc.iso"),
            FileListItem(id: "host:1", path: "/tmp/song.dsf", displayName: "song.dsf")
        ]
        state.fileList = FileListState(kind: .audio, items: items, currentID: items[0].id)
        let generic = ContentSession(
            extensionID: nil,
            providerID: "test.generic-audio",
            request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/disc.iso"))),
            presentation: .text(titleKey: "Test", body: "Fixture"),
            navigatorContributions: [
                .init(
                    id: "generic.container-tracks", titleLocalizationKey: "Queue", style: .flat,
                    items: [
                        .init(id: "track:stereo:01", title: "One"),
                        .init(id: "track:stereo:02", title: "Two")
                    ],
                    selectedItemIDs: ["track:stereo:01"], allowedActions: [.activate]
                )
            ],
            playbackQueue: .init(
                items: [
                    .init(id: "track:stereo:01", title: "One"),
                    .init(id: "track:stereo:02", title: "Two")
                ],
                currentItemID: "track:stereo:01", title: "Fixture Album"
            )
        )
        #expect(ExtensionPlaybackSupport.playbackContributionID(in: generic) == "generic.container-tracks")
        state.installExtensionContainerListIfNeeded(url: items[0].url, session: generic, preferredItemID: nil)
        #expect(state.fileList?.items.map(\.cue?.containerTrackID) == ["track:stereo:01", "track:stereo:02", nil])
        #expect(state.fileList?.items.last?.id == "host:1")
        #expect(state.fileList?.items.map(\.extensionItemID) == ["track:stereo:01", "track:stereo:02", nil])
    }

    @Test func opaqueQueueIDsPairByStampAndResourceWithoutParsingLayout() {
        let first = URL(fileURLWithPath: "/tmp/first.dsf")
        let second = URL(fileURLWithPath: "/tmp/second.dsf")
        let session = ContentSession(
            extensionID: nil,
            providerID: "test.generic-audio",
            request: .fileCollection([.init(url: first), .init(url: second)]),
            presentation: .text(titleKey: "Test", body: "Fixture"),
            playbackQueue: .init(
                items: [.init(id: "item-a", title: "first"), .init(id: "item-b", title: "second")],
                currentItemID: "item-b"
            )
        )
        let unstamped = [
            FileListItem(id: "host:0", path: first.path, displayName: "first.dsf"),
            FileListItem(id: "host:1", path: second.path, displayName: "second.dsf")
        ]
        #expect(ExtensionPlaybackSupport.queueItemID(for: unstamped[0], in: session) == "item-a")
        #expect(ExtensionPlaybackSupport.queueItemID(for: unstamped[1], in: session) == "item-b")

        var trimmed = session
        trimmed.playbackQueue = .init(items: [.init(id: "item-b", title: "second")], currentItemID: "item-b")
        let stamped = [
            FileListItem(id: "host:0", path: first.path, displayName: "first.dsf", extensionItemID: "item-a"),
            FileListItem(id: "host:1", path: second.path, displayName: "second.dsf", extensionItemID: "item-b")
        ]
        let list = FileListState(kind: .audio, items: stamped, currentID: "host:1")
        #expect(ExtensionPlaybackSupport.queueItemID(for: stamped[1], in: trimmed) == "item-b")
        #expect(ExtensionPlaybackSupport.authorizedResource(in: trimmed, fileList: list)?.url == second)
        #expect(ExtensionPlaybackSupport.queueItemID(for: stamped[0], in: trimmed) == nil)
    }

    @Test func contiguousAudioURLsFollowSharedProviderAndStopAtSniffedContainer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-contiguous-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("one.gaud")
        let second = directory.appendingPathComponent("two.gaud")
        let container = directory.appendingPathComponent("disc.iso")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)
        try Data("iso".utf8).write(to: container)

        let provider = ContiguousAudioTestProvider()
        ExtensionHost.shared.resolver.register(provider)
        defer { ExtensionHost.shared.resolver.unregister(providerID: provider.descriptor.id) }

        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        let items = [first, second, container].map { FileListItem(id: $0.lastPathComponent, path: $0.path, displayName: $0.lastPathComponent) }
        state.fileList = FileListState(kind: .audio, items: items, currentID: items[0].id)
        state.mediaPlaybackMode = .sequential
        #expect(state.contiguousExtensionAudioURLs(startingAt: items[0].id) == [first, second])
        #expect(state.contiguousExtensionAudioURLs(startingAt: items[2].id).isEmpty)
    }

    /// 迁移自旧 Hi-Fi 适配测试：容器曲目 ID 不被曲目序号或私有布局推导。
    @Test func trackNumberIsNotInterpretedAsContainerID() {
        let queue = MediaPlaybackQueueSnapshot(
            items: [.init(id: "track:stereo:01", title: "One"), .init(id: "track:stereo:02", title: "Two")],
            currentItemID: "track:stereo:01"
        )
        let item = FileListItem(
            id: "host-track",
            path: "/tmp/disc.iso",
            displayName: "One",
            cue: FileListCueInfo(startCueFrames: 0, trackNumber: "2")
        )
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        #expect(state.containerTrackID(for: item, in: queue) == nil)
    }

    /// 迁移自旧 Hi-Fi 适配测试：只有声明 `content.probe` 才交给扩展嗅探，不再读 SACD 魔数。
    @Test func contentMatchingRequiresProbeCapability() {
        let url = URL(fileURLWithPath: "/tmp/disc.iso")
        let probeCapability = [
            ExtensionCapabilityDeclaration(id: ExtensionCapabilityIdentifier.contentProbe, scope: .application)
        ]
        #expect(ExtensionContentMatching.sniff(url, capabilities: probeCapability) { _ in
            ContentProbeResult(disposition: .matched, reason: "sacd-master-toc")
        })
        #expect(!ExtensionContentMatching.sniff(url, capabilities: probeCapability) { _ in
            ContentProbeResult(disposition: .unmatched)
        })
        // 没有 content.probe 声明时不再回退到旧 SACD 魔数嗅探。
        #expect(!ExtensionContentMatching.sniff(url, capabilities: []))
    }
}

@MainActor
private final class ContiguousAudioTestProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.contiguous-audio",
        extensionID: "app.foofoil.extension.test-contiguous-audio",
        role: .primary,
        fallbackProviderID: nil,
        enhancementDomain: "audio",
        contentFamily: .audio,
        filenameExtensions: ["gaud", "iso"],
        isEnabled: true,
        isRuntimeAvailable: true
    )

    func match(_ request: ContentRequest) -> ProviderMatch? {
        ProviderContentMatcher.match(
            request,
            declarations: [
                ContentTypeDeclaration(extensions: ["iso"], strategy: .sniff),
                ContentTypeDeclaration(extensions: ["gaud"], strategy: .fileExtension)
            ]
        ) { url in
            url.pathExtension.lowercased() == "iso"
        }
    }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        ContentSession(
            extensionID: descriptor.extensionID,
            providerID: descriptor.id,
            request: request,
            presentation: .text(titleKey: "Test", body: request.primaryFileURL?.lastPathComponent ?? "")
        )
    }
}

@MainActor
private final class AudioFamilyNoTransportTestProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.audio-family-no-transport",
        extensionID: nil,
        role: .primary,
        fallbackProviderID: nil,
        enhancementDomain: "audio",
        contentFamily: .audio,
        filenameExtensions: ["nta"],
        isEnabled: true,
        isRuntimeAvailable: true
    )

    func match(_ request: ContentRequest) -> ProviderMatch? {
        request.primaryFileURL?.pathExtension.lowercased() == "nta"
            ? ProviderMatch(strength: .fileExtension, explanation: "no-transport")
            : nil
    }

    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        ContentSession(
            extensionID: nil,
            providerID: descriptor.id,
            request: request,
            presentation: .text(titleKey: "Test", body: "Fixture"),
            mediaPlayback: .init(state: .paused, position: 1, duration: 10, isSeekable: true)
        )
    }
}
