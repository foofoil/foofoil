import Foundation
import Testing
import FoofoilExtensionKit

struct ContentProbeTests {
    @Test func sharedFixtureRoundTripsAndRejectsInvalidBudget() throws {
        let url = try #require(ExtensionKitResources.fixture(named: "ContentProbeRequests"))
        let requests = try JSONDecoder().decode([ContentProbeRequest].self, from: Data(contentsOf: url))
        #expect(requests.map { $0.resource.url.lastPathComponent } == ["fixture-disc.iso", "ordinary.iso"])
        for request in requests {
            try request.validate()
            #expect(request.commandID == ContentProbeRequest.commandIdentifier)
            #expect(try JSONDecoder().decode(ContentProbeRequest.self, from: JSONEncoder().encode(request)) == request)
        }
        #expect(throws: ContentProbeError.unsupportedContract) {
            try ContentProbeRequest(resource: requests[0].resource, contractVersion: 2).validate()
        }
        var invalid = requests[0]
        invalid.maxReadBytes = 0
        #expect(throws: ContentProbeError.invalidBudget) { try invalid.validate() }
    }

    @Test func capabilityDiscoveryUsesExistingNegotiator() {
        #expect(ContentProbeRequest.isDeclared(in: [
            .init(id: ExtensionCapabilityIdentifier.contentProbe, scope: .application)
        ]))
        #expect(!ContentProbeRequest.isDeclared(in: [
            .init(id: ExtensionCapabilityIdentifier.contentProbe, contractVersion: 2, scope: .application)
        ]))
        #expect(!ContentProbeRequest.isDeclared(in: [
            .init(id: ExtensionCapabilityIdentifier.contentProbe, scope: .session)
        ]))
        #expect(AudioDeviceServiceRequest.isDeclared(in: [
            .init(id: ExtensionCapabilityIdentifier.deviceSelector, scope: .application)
        ]))
        #expect(!AudioDeviceServiceRequest.isDeclared(in: [
            .init(id: ExtensionCapabilityIdentifier.mediaTransport, scope: .session)
        ]))
    }

    @Test func probeResultIgnoresUnknownFieldsAndRejectsUnknownDisposition() throws {
        let matched = ContentProbeResult(disposition: .matched, reason: "container", itemCount: 2, title: "Fixture Album")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(matched)) as? [String: Any])
        json["futureField"] = true
        #expect(try JSONDecoder().decode(ContentProbeResult.self, from: JSONSerialization.data(withJSONObject: json)) == matched)
        json["disposition"] = "future-disposition"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ContentProbeResult.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }
}
