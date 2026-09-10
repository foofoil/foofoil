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
            commands: [
                .init(id: "hifi.device.test-dac-uid", titleLocalizationKey: "Output", isEnabled: false)
            ],
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
        #expect(ExtensionPlaybackSupport.presentationURL(in: generic)?.lastPathComponent == "second.dsf")
        #expect(!ExtensionPlaybackSupport.requiresExclusiveHandoff(generic))
        #expect(!ExtensionPlaybackSupport.usesDeviceService(generic))
        #expect(ExtensionPlaybackSupport.acceptsGaplessCollection(generic))
        #expect(ExtensionPlaybackSupport.containerPlaybackQueue(from: generic) == nil)
        #expect(ExtensionPlaybackSupport.legacyMediaAction(for: "hifi.play", in: generic) == nil)
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
        let other = session(providerID: "test.content", mediaPlayback: false, transportCapability: false)
        #expect(!ExtensionPlaybackSupport.usesHostAudioChrome(other))
        #expect(ExtensionPlaybackSupport.presentationURL(in: other) == nil)
        #expect(!ExtensionPlaybackSupport.acceptsGaplessCollection(other))
        #expect(!ExtensionPlaybackSupport.requiresExclusiveHandoff(other))
    }

    @Test func hiFiSessionKeepsLegacyChromeQueueAndHandoff() {
        let hifi = session(providerID: "audio.hifi")
        #expect(ExtensionPlaybackSupport.usesHostAudioChrome(hifi))
        #expect(ExtensionPlaybackSupport.presentationURL(in: hifi)?.lastPathComponent == "second.dsf")
        #expect(ExtensionPlaybackSupport.requiresExclusiveHandoff(hifi))
        #expect(ExtensionPlaybackSupport.usesDeviceService(hifi))
        #expect(ExtensionPlaybackSupport.acceptsGaplessCollection(hifi))
        #expect(ExtensionPlaybackSupport.containerPlaybackQueue(from: hifi) == nil)
        #expect(ExtensionPlaybackSupport.legacyMediaAction(for: "hifi.pause", in: hifi) == .pause)
        #expect(!ExtensionPlaybackSupport.isOutputDeviceEnabled("test-dac-uid", in: hifi))
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
