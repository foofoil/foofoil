import Foundation
import Testing
import FoofoilExtensionKit

struct BaselineFixtureTests {
    private func fixtureJSON(_ name: String) throws -> [String: Any] {
        let url = try #require(ExtensionKitResources.fixture(named: name))
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func deviceServiceRequestsRoundTripAndKeepLegacyDefaults() throws {
        let catalog = try fixtureJSON("AudioDeviceServiceMessages")
        let requests = try #require(catalog["requests"] as? [[String: Any]])
        #expect(requests.map { $0["body"] as? [String: Any] }.compactMap { $0?["command"] as? String } == [
            "snapshot", "selectSystemDefault", "prepareExclusivePCM", "releasePCM", "releaseAllPCM"
        ])

        for entry in requests {
            let body = try #require(entry["body"] as? [String: Any])
            let data = try JSONSerialization.data(withJSONObject: body)
            let request = try JSONDecoder().decode(AudioDeviceServiceRequest.self, from: data)
            #expect(try JSONDecoder().decode(AudioDeviceServiceRequest.self, from: JSONEncoder().encode(request)) == request)
            if request.command == .prepareExclusivePCM {
                #expect(request.selectedDeviceID == "test-dac-uid")
                #expect(request.sourceSampleRate == 96_000)
                #expect(request.channelCount == 2)
            }
        }

        let unknown = try JSONSerialization.data(withJSONObject: try #require(catalog["unknownFieldRequest"]))
        #expect(try JSONDecoder().decode(AudioDeviceServiceRequest.self, from: unknown).command == .snapshot)

        let snapshots = try #require(catalog["snapshots"] as? [[String: Any]])
        for entry in snapshots {
            let body = try #require(entry["body"] as? [String: Any])
            let snapshot = try JSONDecoder().decode(
                AudioDeviceServiceSnapshot.self,
                from: JSONSerialization.data(withJSONObject: body)
            )
            try MediaSessionContractValidator.validate(deviceSnapshot: snapshot)
            #expect(try JSONDecoder().decode(
                AudioDeviceServiceSnapshot.self,
                from: JSONEncoder().encode(snapshot)
            ) == snapshot)
        }

        let legacy = try JSONSerialization.data(withJSONObject: try #require(catalog["legacyDeviceDescriptor"]))
        let legacyDevice = try JSONDecoder().decode(AudioOutputDeviceDescriptor.self, from: legacy)
        #expect(!legacyDevice.supportsExclusiveMode)
        #expect(legacyDevice.supportedPCMSampleRates.isEmpty)
        #expect(legacyDevice.isConnected)
        // 旧快照没有 isCompatible 字段时缺省为可用。
        #expect(legacyDevice.isCompatible)
    }

    @Test func deviceServiceInvalidCommandsAreRejectedByCodable() throws {
        let catalog = try fixtureJSON("AudioDeviceServiceMessages")
        let invalid = try #require(catalog["invalidRequests"] as? [[String: Any]])
        let unknown = try JSONSerialization.data(withJSONObject: try #require(invalid[0]["body"]))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AudioDeviceServiceRequest.self, from: unknown)
        }
        let incomplete = try JSONDecoder().decode(
            AudioDeviceServiceRequest.self,
            from: JSONSerialization.data(withJSONObject: try #require(invalid[1]["body"]))
        )
        #expect(incomplete.command == .prepareExclusivePCM)
        #expect(incomplete.selectedDeviceID == nil)
    }

    @Test func historyAndQueueSnapshotsUseOpaqueIDsAndGenericProviders() throws {
        let catalog = try fixtureJSON("HistoryAndQueueSnapshots")
        let restored = try JSONDecoder().decode(
            ContentRequest.self,
            from: JSONSerialization.data(withJSONObject: try #require(catalog["restoredSessionRequest"]))
        )
        guard case .restoredSession(let extensionID, let reference) = restored else {
            Issue.record("expected restoredSession")
            return
        }
        #expect(extensionID == "app.foofoil.extension.hifi")
        #expect(reference == "00000000-0000-0000-0000-0000000000bb")

        var sessionsByName: [String: ContentSession] = [:]
        for entry in try #require(catalog["sessions"] as? [[String: Any]]) {
            let name = try #require(entry["name"] as? String)
            let session = try JSONDecoder().decode(
                ContentSession.self,
                from: JSONSerialization.data(withJSONObject: try #require(entry["session"]))
            )
            try MediaSessionContractValidator.validate(session)
            try NavigatorContributionValidator.validate(session)
            sessionsByName[name] = session
        }

        let files = try #require(sessionsByName["generic-external-file-queue"])
        #expect(files.providerID == "test.generic-audio")
        #expect(files.navigatorContributions[0].id == "generic.playback-queue")
        #expect(files.navigatorContributions[0].allowedActions.contains(.move))

        let container = try #require(sessionsByName["generic-container-queue"])
        #expect(container.providerID == "test.generic-audio")
        #expect(container.playbackQueue?.items.map(\.id) == ["track:stereo:01", "track:stereo:02"])
        #expect(container.navigatorContributions[0].id == "generic.container-tracks")
        #expect(container.navigatorContributions[0].allowedActions == [.activate])

        let legacy = try #require(sessionsByName["legacy-hifi-container-queue"])
        #expect(legacy.providerID == "audio.hifi")
        #expect(legacy.stateReference == "00000000-0000-0000-0000-0000000000bb")
        #expect(legacy.navigatorContributions[0].id == "hifi.playback-queue")
        #expect(legacy.navigatorContributions[0].allowedActions == [.activate])

        for object in try #require(catalog["genericMediaCommands"] as? [[String: Any]]) {
            let request = try JSONDecoder().decode(
                MediaPlaybackRequest.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            try request.validate()
            #expect(request.session.providerID == "test.generic-audio")
        }
    }
}

private extension MediaSessionContractValidator {
    static func validate(deviceSnapshot snapshot: AudioDeviceServiceSnapshot) throws {
        guard snapshot.contractVersion > 0, snapshot.contractVersion <= supportedContractVersion else {
            throw MediaSessionContractError.unsupportedContractVersion(snapshot.contractVersion)
        }
        var identifiers = Set<String>()
        for device in snapshot.devices {
            guard !device.id.isEmpty, !device.displayName.isEmpty, identifiers.insert(device.id).inserted else {
                throw MediaSessionContractError.duplicateDevice(device.id)
            }
        }
        if let selected = snapshot.selectedPCMDeviceID, !identifiers.contains(selected) {
            throw MediaSessionContractError.invalidSelectedDevice(selected)
        }
        if let active = snapshot.activeDeviceID, !identifiers.contains(active) {
            throw MediaSessionContractError.invalidSelectedDevice(active)
        }
    }
}
