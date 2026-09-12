import Foundation
import FoofoilExtensionKit
import Testing
@testable import foofoil

extension ExtensionKitTests {
@MainActor
@Suite
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
    /// APE 跟随系统默认时右上角必须写明跟随，不能只显示设备名。
    @Test func followingSystemDefaultMarksAPEOutputStatus() {
        let followLabel = NSLocalizedString("System Default Output", comment: "")
        let following = AudioDeviceSelectionSnapshot(
            devices: [.init(id: "built-in", displayName: "Built-in Output", isSystemDefault: true)],
            selectedDeviceID: "built-in",
            followsSystemDefault: true,
            statusDescription: "Built-in Output"
        )
        #expect(ExtensionPlaybackSupport.outputStatusTitle(for: following) == "Built-in Output · \(followLabel)")
        let playing = AudioDeviceSelectionSnapshot(
            devices: following.devices,
            selectedDeviceID: "built-in",
            followsSystemDefault: true,
            statusDescription: "44.1 kHz · 16-bit · 2ch PCM · Built-in Output"
        )
        #expect(ExtensionPlaybackSupport.outputStatusTitle(for: playing).hasSuffix(" · \(followLabel)"))
        let exclusive = AudioDeviceSelectionSnapshot(
            devices: following.devices,
            selectedDeviceID: "built-in",
            followsSystemDefault: false,
            statusDescription: "Built-in Output"
        )
        #expect(ExtensionPlaybackSupport.outputStatusTitle(for: exclusive) == "Built-in Output")
        let unlabeled = AudioDeviceSelectionSnapshot(
            devices: following.devices,
            selectedDeviceID: "built-in",
            followsSystemDefault: true
        )
        #expect(ExtensionPlaybackSupport.outputStatusTitle(for: unlabeled) == followLabel)
    }

    @Test func outputDeviceEnabledFollowsPublicAvailabilityAndConnection() {
        var session = session(providerID: "audio.hifi")
        session.audioDeviceSelection = .init(devices: [
            .init(id: "connected", displayName: "Connected"),
            .init(id: "gone", displayName: "Gone", isConnected: false),
            .init(id: "incompatible", displayName: "Incompatible", isCompatible: false)
        ])
        session.mediaPlayback?.availableActions = [.refresh, .seek, .selectDevice, .play]
        #expect(ExtensionPlaybackSupport.isOutputDeviceEnabled("connected", in: session))
        #expect(!ExtensionPlaybackSupport.isOutputDeviceEnabled("gone", in: session))
        #expect(!ExtensionPlaybackSupport.isOutputDeviceEnabled("incompatible", in: session))

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
        // 未知扩展容器使用宿主命名空间与通用样式，不显示 SACD 徽标或私有前缀。
        #expect(state.fileList?.items.dropLast().allSatisfy { $0.id.hasPrefix("container:") } == true)
        #expect(state.fileList?.sections.first?.resolvedFormat == .generic)
        #expect(state.navigatorContributions.first?.items.first?.badge == nil)
    }

    @Test func hostCueItemsAreReplacedByExtensionContainerQueueByOrdinal() {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        let apePath = "/tmp/CDImage.ape"
        let cueItems = (1...3).map { number in
            FileListItem(
                id: "cue:\(number)",
                path: apePath,
                displayName: "Track \(number)",
                cue: FileListCueInfo(
                    startCueFrames: Int64(number - 1) * 1_000,
                    trackNumber: "\(number)",
                    sectionID: "cue-section"
                )
            )
        }
        state.fileList = FileListState(kind: .audio, items: cueItems, currentID: cueItems[0].id, title: "Album")
        let session = ContentSession(
            extensionID: nil,
            providerID: "audio.hifi",
            request: .singleFile(.init(url: URL(fileURLWithPath: apePath))),
            presentation: .text(titleKey: "Test", body: "Fixture"),
            navigatorContributions: [
                .init(
                    id: "hifi.playback-queue", titleLocalizationKey: "Queue", style: .flat,
                    items: (1...3).map { .init(id: "track:cue:0\($0)", title: "Track \($0)") },
                    selectedItemIDs: ["track:cue:01"], allowedActions: [.activate]
                )
            ],
            playbackQueue: .init(
                items: (1...3).map { .init(id: "track:cue:0\($0)", title: "Track \($0)") },
                currentItemID: "track:cue:01", title: "Album"
            )
        )
        state.installExtensionContainerListIfNeeded(
            url: URL(fileURLWithPath: apePath),
            session: session,
            preferredItemID: cueItems[2].id
        )
        // 宿主 CUE 项被扩展容器队列整体替换，并按点击的第 3 首对齐当前项。
        #expect(state.fileList?.items.map(\.cue?.containerTrackID) == ["track:cue:01", "track:cue:02", "track:cue:03"])
        #expect(state.fileList?.currentID == state.fileList?.items[2].id)
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

    @Test func contiguousAudioURLsFollowSharedProviderAndStopAtSniffedContainer() async throws {
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
        let sequence = await state.contiguousExtensionAudioURLs(startingAt: items[0].id)
        let containerSequence = await state.contiguousExtensionAudioURLs(startingAt: items[2].id)
        #expect(sequence == [first, second])
        #expect(containerSequence.isEmpty)
        // 直接扫描不执行任何 sniff/probe。
        #expect(provider.sniffCount == 0)
    }

    @Test(arguments: [false, true])
    func contiguousScanPreservesCueAndMissingFileBoundaries(cue: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["a.gaud", "boundary.gaud", "b.gaud"].map { directory.appendingPathComponent($0) }
        try Data().write(to: urls[0])
        try Data().write(to: urls[2])
        if cue { try Data().write(to: urls[1]) }
        var items = urls.map { FileListItem(id: $0.lastPathComponent, path: $0.path, displayName: $0.lastPathComponent) }
        if cue { items[1].cue = FileListCueInfo(startCueFrames: 0) }
        let provider = ContiguousAudioTestProvider()
        ExtensionHost.shared.resolver.register(provider)
        defer { ExtensionHost.shared.resolver.unregister(providerID: provider.descriptor.id) }
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.fileList = FileListState(kind: .audio, items: items, currentID: items[0].id)
        state.mediaPlaybackMode = .sequential
        #expect(await state.contiguousExtensionAudioURLs(startingAt: items[0].id) == [urls[0]])
        #expect(await state.contiguousExtensionAudioURLs(startingAt: items[1].id) == [])
    }

    /// 连续扫描只做声明级预判：100 个文件不触发逐项 probe。
    @Test func contiguousScanOfHundredFilesDoesNotProbe() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-contiguous-100-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var urls: [URL] = []
        for index in 0..<100 {
            let url = directory.appendingPathComponent(String(format: "track-%03d.gaud", index))
            try Data("x".utf8).write(to: url)
            urls.append(url)
        }

        let provider = ContiguousAudioTestProvider()
        ExtensionHost.shared.resolver.register(provider)
        defer { ExtensionHost.shared.resolver.unregister(providerID: provider.descriptor.id) }

        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        let items = urls.map { FileListItem(id: $0.lastPathComponent, path: $0.path, displayName: $0.lastPathComponent) }
        state.fileList = FileListState(kind: .audio, items: items, currentID: items[0].id)
        state.mediaPlaybackMode = .sequential
        let sequence = await state.contiguousExtensionAudioURLs(startingAt: items[0].id)
        #expect(sequence == urls)
        #expect(provider.sniffCount == 0)
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
    private let declarations = [
        ContentTypeDeclaration(extensions: ["iso"], strategy: .sniff),
        ContentTypeDeclaration(extensions: ["gaud"], strategy: .fileExtension)
    ]
    /// 记录 sniff 执行次数；连续扫描预判不应触发任何一次。
    private(set) var sniffCount = 0

    func match(_ request: ContentRequest) -> ProviderMatch? {
        ProviderContentMatcher.match(request, declarations: declarations) { [weak self] url in
            self?.sniffCount += 1
            return url.pathExtension.lowercased() == "iso"
        }
    }

    func preflightMatch(_ request: ContentRequest) -> ProviderMatch? {
        ProviderContentMatcher.preflightMatch(request, declarations: declarations)
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
