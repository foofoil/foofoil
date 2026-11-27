import Foundation
import Testing
import FoofoilExtensionKit

struct SessionLifecycleTests {
    private func requests() throws -> [SessionLifecycleRequest] {
        let url = try #require(ExtensionKitResources.fixture(named: "SessionLifecycleRequests"))
        return try JSONDecoder().decode([SessionLifecycleRequest].self, from: Data(contentsOf: url))
    }

    @Test func fixtureRoundTripsAndUsesGenericProvider() throws {
        let requests = try requests()
        #expect(requests.map(\.operation) == [.restore, .close])
        for request in requests {
            try request.validate()
            #expect(request.session.providerID == "test.generic-audio")
            #expect(try JSONDecoder().decode(SessionLifecycleRequest.self, from: JSONEncoder().encode(request)) == request)
        }
    }

    @Test func capabilityMustBeActiveAndVersionSupported() throws {
        var session = try requests()[0].session
        session.capabilities[0].state = .available
        #expect(!SessionLifecycleRequest.isSupported(by: session))
        session.capabilities = [.init(declaration: .init(id: "session.lifecycle", contractVersion: 2, scope: .session), state: .active)]
        #expect(!SessionLifecycleRequest.isSupported(by: session))
        session.capabilities = []
        #expect(throws: SessionLifecycleError.missingCapability) {
            try SessionLifecycleRequest(operation: .close, session: session).validate()
        }
        let negotiation = CapabilityNegotiator.negotiate([
            .init(id: "session.lifecycle", scope: .session)
        ])
        #expect(negotiation.accepted.count == 1)
        #expect(negotiation.rejected.isEmpty)
    }

    @Test(arguments: [Double.nan, .infinity, -1])
    func rejectsInvalidPositions(position: Double) throws {
        let session = try requests()[0].session
        #expect(throws: SessionLifecycleError.invalidRestoration) {
            try SessionLifecycleRequest(operation: .restore, session: session, restoration: .init(position: position)).validate()
        }
    }

    @Test func rejectsWrongVersionAndOperationPayload() throws {
        let session = try requests()[0].session
        #expect(throws: SessionLifecycleError.unsupportedContract) {
            try SessionLifecycleRequest(operation: .close, session: session, contractVersion: 2).validate()
        }
        #expect(throws: SessionLifecycleError.invalidRestoration) {
            try SessionLifecycleRequest(operation: .close, session: session, restoration: .init()).validate()
        }
        #expect(throws: SessionLifecycleError.invalidRestoration) {
            try SessionLifecycleRequest(operation: .restore, session: session).validate()
        }
        try SessionLifecycleRequest(operation: .restore, session: session, restoration: .init()).validate()
    }

    @Test func ignoresUnknownFieldsAndRejectsUnknownOperation() throws {
        let request = try requests()[0]
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        json["futureField"] = true
        let decoder = JSONDecoder()
        #expect(try decoder.decode(SessionLifecycleRequest.self, from: JSONSerialization.data(withJSONObject: json)) == request)
        json["operation"] = "future-operation"
        #expect(throws: DecodingError.self) {
            try decoder.decode(SessionLifecycleRequest.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }
}
