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

    /// 私有文件 ID 在队列被裁剪后仍指向原始资源，而非当前队列下标。
    @Test func sourceURLSurvivesQueueTrimming() {
        var session = session()
        session.playbackQueue = .init(
            items: [.init(id: "file:1", title: "Second")], currentItemID: "file:1"
        )
        #expect(HiFiLegacyAdapter.currentURL(in: session)?.lastPathComponent == "second.dsf")
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
}
