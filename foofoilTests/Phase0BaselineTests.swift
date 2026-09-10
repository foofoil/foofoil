import Foundation
import FoofoilExtensionKit
import Testing
@testable import foofoil

@MainActor
struct Phase0BaselineTests {
    @Test func hostHistoryFixtureKeepsOpaqueContainerTrackIDs() throws {
        let url = try #require(ExtensionKitResources.fixture(named: "HistoryAndQueueSnapshots"))
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let hostHistory = try #require(catalog["hostHistory"] as? [String: Any])
        let windowObject = try #require(hostHistory["windowConfig"] as? [String: Any])
        let config = try JSONDecoder().decode(
            WindowConfig.self,
            from: JSONSerialization.data(withJSONObject: windowObject)
        )

        #expect(config.extensionID == "app.foofoil.extension.hifi")
        #expect(config.extensionStateReference == "00000000-0000-0000-0000-0000000000bb")
        #expect(HistoryContentKind.infer(from: config) == .audio)
        let list = try #require(config.fileList)
        #expect(list.isPresentable)
        #expect(list.isCueBased)
        #expect(!list.isReorderable)
        #expect(list.soleContainerFormat == .sacd)
        #expect(list.items.map(\.cue?.containerTrackID) == ["track:stereo:01", "track:stereo:02"])
        #expect(list.items.allSatisfy { $0.id != $0.cue?.containerTrackID })
        #expect(list.items.allSatisfy { $0.path.hasSuffix("fixture-disc.iso") })

        let sessions = try #require(catalog["sessions"] as? [[String: Any]])
        let legacy = try #require(sessions.first { $0["name"] as? String == "legacy-hifi-container-queue" })
        let session = try JSONDecoder().decode(
            ContentSession.self,
            from: JSONSerialization.data(withJSONObject: try #require(legacy["session"]))
        )
        #expect(session.playbackQueue?.items.map(\.id) == list.items.map(\.cue?.containerTrackID))
        #expect(session.stateReference == config.extensionStateReference)
    }
}
