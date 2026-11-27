import Foundation
import Testing
import FoofoilExtensionKit

struct MediaTransportTests {
    private func fixtures() throws -> [[String: Any]] {
        let url = try #require(ExtensionKitResources.fixture(named: "MediaNavigationRequests"))
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    }

    @Test func sharedFixtureValidatesAndRoundTrips() throws {
        for object in try fixtures() {
            let data = try JSONSerialization.data(withJSONObject: object)
            if object["commandID"] as? String == MediaPlaybackRequest.commandIdentifier {
                let request = try JSONDecoder().decode(MediaPlaybackRequest.self, from: data)
                try request.validate()
                #expect(try JSONDecoder().decode(MediaPlaybackRequest.self, from: JSONEncoder().encode(request)) == request)
            } else {
                let request = try JSONDecoder().decode(NavigatorActionRequest.self, from: data)
                try request.validate()
                #expect(try JSONDecoder().decode(NavigatorActionRequest.self, from: JSONEncoder().encode(request)) == request)
            }
        }
    }

    @Test func wireActionsIncludePlayAndDeviceSelection() throws {
        for action: MediaPlaybackAction in [.play, .pause, .seek(42), .selectDevice("opaque-device"), .selectSystemDefault, .previous, .next, .refresh] {
            try action.validate()
            #expect(try JSONDecoder().decode(MediaPlaybackAction.self, from: JSONEncoder().encode(action)) == action)
        }
    }

    @Test func systemDefaultSelectionSnapshotPreservesActualDevice() throws {
        var snapshot = AudioDeviceSelectionSnapshot(
            devices: [.init(id: "output", displayName: "Output")], selectedDeviceID: "output",
            followsSystemDefault: true
        )
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(AudioDeviceSelectionSnapshot.self, from: data) == snapshot)
        snapshot.followsSystemDefault = nil
        #expect(try JSONDecoder().decode(AudioDeviceSelectionSnapshot.self, from: JSONEncoder().encode(snapshot)).followsSystemDefault == nil)
        #expect(!MediaPlaybackSnapshot().allows(.selectSystemDefault))
    }

    @Test(arguments: [Double.nan, .infinity, -1])
    func rejectsInvalidSeek(position: Double) {
        #expect(throws: MediaTransportError.invalidAction) { try MediaPlaybackAction.seek(position).validate() }
    }

    @Test func capabilityVersionsAndActionValidation() throws {
        let data = try JSONSerialization.data(withJSONObject: fixtures()[0])
        var session = try JSONDecoder().decode(MediaPlaybackRequest.self, from: data).session
        #expect(throws: MediaTransportError.invalidAction) { try MediaPlaybackAction.selectDevice("").validate() }
        session.mediaPlayback?.isSeekable = false
        #expect(throws: MediaTransportError.invalidAction) { try MediaPlaybackRequest(action: .seek(1), session: session).validate() }
        #expect(throws: MediaTransportError.unsupportedContract) { try MediaPlaybackRequest(action: .pause, session: session, contractVersion: 2).validate() }
        session.capabilities = []
        #expect(!MediaPlaybackRequest.isSupported(by: session))
        #expect(!NavigatorActionRequest.isSupported(by: session))
        #expect(throws: MediaTransportError.missingCapability) { try MediaPlaybackRequest(action: .pause, session: session).validate() }
    }

    @Test func explicitAvailableActionsDisableWireActionsAndMissingListUsesDefaults() throws {
        let data = try JSONSerialization.data(withJSONObject: fixtures()[0])
        var session = try JSONDecoder().decode(MediaPlaybackRequest.self, from: data).session
        session.mediaPlayback?.availableActions = [.pause, .refresh]
        try MediaPlaybackRequest(action: .pause, session: session).validate()
        #expect(throws: MediaTransportError.actionUnavailable) {
            try MediaPlaybackRequest(action: .play, session: session).validate()
        }
        session.mediaPlayback?.availableActions = nil
        session.mediaPlayback?.state = .paused
        #expect(session.mediaPlayback?.allows(.play) == true)
        #expect(session.mediaPlayback?.allows(.pause) == false)
        #expect(session.mediaPlayback?.allows(.previous, queueItemCount: 2) == true)
        try MediaPlaybackRequest(action: .pause, session: session).validate()
    }

    @Test func navigationDoesNotInterpretContributionOrItemIDs() throws {
        let data = try JSONSerialization.data(withJSONObject: fixtures()[3])
        var session = try JSONDecoder().decode(NavigatorActionRequest.self, from: data).session
        session.navigatorContributions = [.init(
            id: "other.queue", titleLocalizationKey: "Queue", style: .flat,
            items: [.init(id: "opaque-track", title: "Track")]
        )]
        try NavigatorActionRequest(
            action: .init(contributionID: "other.queue", kind: .activate, itemIDs: ["opaque-track"]), session: session
        ).validate()
        #expect(throws: NavigatorContributionError.invalidAction("other.queue")) {
            try NavigatorActionRequest(action: .init(contributionID: "other.queue", kind: .activate, itemIDs: ["missing"]), session: session).validate()
        }
    }
}
