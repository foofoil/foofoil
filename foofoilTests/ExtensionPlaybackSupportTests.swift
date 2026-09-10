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
        currentItemID: String = "file:1"
    ) -> ContentSession {
        return ContentSession(
            extensionID: nil,
            providerID: providerID,
            request: .fileCollection([
                .init(url: URL(fileURLWithPath: "/tmp/first.dsf")),
                .init(url: URL(fileURLWithPath: "/tmp/second.dsf"))
            ]),
            presentation: .text(titleKey: "Test", body: "Fixture"),
            commands: [
                .init(id: "hifi.device.test-dac-uid", titleLocalizationKey: "Output", isEnabled: false)
            ],
            mediaPlayback: mediaPlayback ? .init(state: .paused, position: 1, duration: 10, isSeekable: true) : nil,
            playbackQueue: .init(
                items: queueIDs.map { .init(id: $0, title: $0) },
                currentItemID: currentItemID
            )
        )
    }

    @Test func genericProviderDoesNotTakeHiFiPresentationQueueOrHandoff() {
        let generic = session(providerID: "test.generic-audio")
        #expect(!ExtensionPlaybackSupport.usesHostAudioChrome(generic))
        #expect(ExtensionPlaybackSupport.presentationURL(in: generic) == nil)
        #expect(!ExtensionPlaybackSupport.requiresExclusiveHandoff(generic))
        #expect(!ExtensionPlaybackSupport.acceptsGaplessCollection(generic))
        #expect(ExtensionPlaybackSupport.containerPlaybackQueue(from: generic) == nil)
        #expect(ExtensionPlaybackSupport.legacyMediaAction(for: "hifi.play", in: generic) == nil)
        let contribution = NavigatorContribution(
            id: "hifi.playback-queue", titleLocalizationKey: "Queue", style: .flat,
            items: [.init(id: "file:1", title: "second")]
        )
        #expect(!ExtensionPlaybackSupport.showsPlaybackIndicator(for: contribution, session: generic))

        let state = AppState()
        defer {
            state.extensionSession = nil
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        state.extensionSession = generic
        #expect(!state.isAudioDocument)
    }

    @Test func hiFiSessionKeepsLegacyChromeQueueAndHandoff() {
        let hifi = session(providerID: "audio.hifi")
        #expect(ExtensionPlaybackSupport.usesHostAudioChrome(hifi))
        #expect(ExtensionPlaybackSupport.presentationURL(in: hifi)?.lastPathComponent == "second.dsf")
        #expect(ExtensionPlaybackSupport.requiresExclusiveHandoff(hifi))
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
    }
}
