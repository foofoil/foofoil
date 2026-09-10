import Foundation
import FoofoilExtensionKit
import Testing
@testable import foofoil

@MainActor
struct HiFiLegacyAdapterTests {
    private func session() -> ContentSession {
        ContentSession(
            extensionID: "app.foofoil.extension.hifi",
            providerID: "audio.hifi",
            request: .fileCollection([
                .init(url: URL(fileURLWithPath: "/tmp/first.dsf")),
                .init(url: URL(fileURLWithPath: "/tmp/second.dsf"))
            ]),
            presentation: .text(titleKey: "Test", body: "DSD")
        )
    }

    /// 队列裁剪后仍靠宿主列表上的不透明 ID 指向原始资源，而不是解析 ID 布局。
    @Test func sourceURLSurvivesQueueTrimming() {
        var session = session()
        session.playbackQueue = .init(
            items: [.init(id: "item-b", title: "Second")], currentItemID: "item-b"
        )
        let list = FileListState(
            kind: .audio,
            items: [
                FileListItem(
                    id: "host:0", path: "/tmp/first.dsf", displayName: "first.dsf",
                    extensionItemID: "item-a"
                ),
                FileListItem(
                    id: "host:1", path: "/tmp/second.dsf", displayName: "second.dsf",
                    extensionItemID: "item-b"
                )
            ],
            currentID: "host:1"
        )
        #expect(HiFiLegacyAdapter.currentURL(in: session, fileList: list)?.lastPathComponent == "second.dsf")
    }

    @Test(arguments: ["file:99", "file:-1", "file:invalid", "missing"])
    func invalidResourceIDFallsBackToPrimaryFile(id: String) {
        var session = session()
        session.playbackQueue = .init(items: [], currentItemID: id)
        #expect(HiFiLegacyAdapter.currentURL(in: session) == session.request.primaryFileURL)
    }

    @Test func containerTrackUsesPrimaryResource() {
        var session = ContentSession(
            extensionID: "app.foofoil.extension.hifi", providerID: "audio.hifi",
            request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/disc.iso"))),
            presentation: .text(titleKey: "Test", body: "DSD")
        )
        session.playbackQueue = .init(
            items: [.init(id: "track-one", title: "One"), .init(id: "track-two", title: "Two")],
            currentItemID: "track-two"
        )
        #expect(HiFiLegacyAdapter.currentURL(in: session) == session.request.primaryFileURL)
    }

    @Test func navigationUsesLegacyWireFormatWithoutMutatingSnapshot() throws {
        var session = session()
        session.navigatorContributions = [.init(
            id: "hifi.playback-queue", titleLocalizationKey: "Queue", style: .flat,
            items: ["a", "b", "c"].map { .init(id: $0, title: $0) },
            selectedItemIDs: ["a"], allowedActions: [.activate, .move]
        )]
        let activation = try #require(HiFiLegacyAdapter.navigatorRequest(
            action: .init(contributionID: "hifi.playback-queue", kind: .activate, itemIDs: ["b"]),
            session: session
        ))
        #expect(activation.commandID == "hifi.navigator.activate")
        #expect(activation.session.navigatorContributions[0].selectedItemIDs == ["b"])
        let move = try #require(HiFiLegacyAdapter.navigatorRequest(
            action: .init(
                contributionID: "hifi.playback-queue", kind: .move, itemIDs: ["a"],
                destinationItemID: "b", movePosition: .after
            ), session: session
        ))
        #expect(move.commandID == "hifi.navigator.move")
        #expect(move.session.navigatorContributions[0].items.map(\.id) == ["b", "a", "c"])
        #expect(session.navigatorContributions[0].items.map(\.id) == ["a", "b", "c"])
        #expect(session.navigatorContributions[0].selectedItemIDs == ["a"])
        #expect(move.session.id == session.id)
    }

    @Test func missingContributionDoesNotSendNavigationCommand() {
        #expect(HiFiLegacyAdapter.navigatorRequest(
            action: .init(contributionID: "missing", kind: .activate, itemIDs: ["a"]),
            session: session()
        ) == nil)
    }

    /// 声明导航贡献但没有协商 `ui.navigator-actions` 的通用 Provider 不会收到 Hi-Fi 私有导航命令。
    @Test func nonHiFiSessionDoesNotBuildPrivateNavigationCommand() {
        let generic = ContentSession(
            extensionID: nil,
            providerID: "test.content",
            request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/content.foo"))),
            presentation: .text(titleKey: "Test", body: "Fixture"),
            navigatorContributions: [.init(
                id: "test.items", titleLocalizationKey: "Items", style: .flat,
                items: ["a", "b", "c"].map { .init(id: $0, title: $0) },
                selectedItemIDs: ["a"], allowedActions: [.activate, .move]
            )]
        )
        #expect(HiFiLegacyAdapter.navigatorRequest(
            action: .init(contributionID: "test.items", kind: .activate, itemIDs: ["b"]),
            session: generic
        ) == nil)
        #expect(HiFiLegacyAdapter.navigatorRequest(
            action: .init(
                contributionID: "test.items", kind: .move, itemIDs: ["a"],
                destinationItemID: "b", movePosition: .after
            ),
            session: generic
        ) == nil)
    }

    @Test func restorationDoesNotReplayHiFiStateIntoAnotherProvider() async throws {
        let saved = session()
        let fresh = ContentSession(
            extensionID: nil, providerID: "builtin.audio", request: saved.request,
            presentation: .text(titleKey: "Test", body: "Fallback")
        )
        let restored = try await HiFiLegacyAdapter.restorePlayback(saved: saved, fresh: fresh) { _, value in
            Issue.record("Fallback must not receive a Hi-Fi activation")
            return value
        } seek: { value in
            Issue.record("Fallback must not receive a Hi-Fi seek")
            return value
        }
        #expect(restored == fresh)
    }

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

    @Test func probeRequiresSACDMagicAtMainTOCOffset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let iso = directory.appendingPathComponent("disc.iso")
        try Data("SACDMTOC".utf8).write(to: iso)
        #expect(!HiFiLegacyAdapter.sniffSACDISOMagic(iso))
        var contents = Data(repeating: 0, count: 510 * 2048)
        contents.append(Data("SACDMTOC".utf8))
        try contents.write(to: iso)
        #expect(HiFiLegacyAdapter.sniffSACDISOMagic(iso))
        let other = directory.appendingPathComponent("disc.bin")
        try contents.write(to: other)
        #expect(!HiFiLegacyAdapter.sniffSACDISOMagic(other))
        contents[510 * 2048] = 0
        try contents.write(to: iso)
        #expect(!HiFiLegacyAdapter.sniffSACDISOMagic(iso))
    }

    @Test func contentMatchingUsesProbeWhenDeclared() {
        let url = URL(fileURLWithPath: "/tmp/disc.iso")
        let probeCapability = [
            ExtensionCapabilityDeclaration(id: ExtensionCapabilityIdentifier.contentProbe, scope: .application)
        ]
        #expect(ExtensionContentMatching.sniff(url, providerID: "audio.hifi", capabilities: probeCapability) { _ in
            ContentProbeResult(disposition: .matched, reason: "sacd-master-toc")
        })
        #expect(!ExtensionContentMatching.sniff(url, providerID: "audio.hifi", capabilities: probeCapability) { _ in
            ContentProbeResult(disposition: .unmatched)
        })
        #expect(!ExtensionContentMatching.sniff(url, providerID: "other.audio", capabilities: []))
    }
}
