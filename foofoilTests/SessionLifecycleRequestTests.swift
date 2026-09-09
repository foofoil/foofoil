import Foundation
import FoofoilExtensionKit
import Testing
@testable import foofoil

@MainActor
struct SessionLifecycleRequestTests {
    private func session() throws -> ContentSession {
        let url = try #require(ExtensionKitResources.fixture(named: "SessionLifecycleRequests"))
        return try JSONDecoder().decode([SessionLifecycleRequest].self, from: Data(contentsOf: url))[0].session
    }

    @Test func genericProviderRestoresIntoFreshSessionWithOpaqueItemID() throws {
        let fresh = try session()
        var saved = ContentSession(
            extensionID: nil, providerID: fresh.providerID, request: fresh.request,
            presentation: fresh.presentation
        )
        saved.playbackQueue = .init(items: [.init(id: "opaque:item", title: "Item")], currentItemID: "opaque:item")
        saved.mediaPlayback = .init(state: .playing, position: 42, duration: 100)
        let request = try #require(ExtensionSessionLifecycle.restorationRequest(from: saved, in: fresh))
        try request.validate()
        #expect(request.session.id == fresh.id)
        #expect(request.session.id != saved.id)
        #expect(request.restoration?.currentItemID == "opaque:item")
        #expect(request.restoration?.position == 42)
        #expect(request.session.providerID == "test.generic-audio")
    }

    @Test(arguments: [Double.nan, .infinity, -1])
    func invalidLegacyPositionIsOmitted(position: Double) throws {
        let fresh = try session()
        var saved = fresh
        saved.mediaPlayback = .init(position: position)
        let request = try #require(ExtensionSessionLifecycle.restorationRequest(from: saved, in: fresh))
        try request.validate()
        #expect(request.restoration?.position == nil)
    }

    @Test func oldAndUnsupportedCapabilitiesUseCompatibilityPath() throws {
        let saved = try session()
        var fresh = saved
        fresh.capabilities = []
        #expect(ExtensionSessionLifecycle.restorationRequest(from: saved, in: fresh) == nil)
        fresh.capabilities = [.init(declaration: .init(id: "session.lifecycle", contractVersion: 2, scope: .session), state: .active)]
        #expect(ExtensionSessionLifecycle.restorationRequest(from: saved, in: fresh) == nil)
        let other = ContentSession(
            extensionID: nil, providerID: "different", request: saved.request,
            presentation: saved.presentation, capabilities: saved.capabilities
        )
        #expect(ExtensionSessionLifecycle.restorationRequest(from: saved, in: other) == nil)
    }
}
