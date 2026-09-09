import Foundation
import FoofoilExtensionKit
import Testing
@testable import foofoil

extension ExtensionKitTests {
    @Test func genericProviderReceivesTypedMediaActionsWithoutPrivateCommands() async throws {
        let provider = MediaRoutingTestProvider()
        let host = ExtensionHost.shared
        host.resolver.register(provider)
        defer { host.resolver.unregister(providerID: provider.descriptor.id) }
        let session = try await provider.makeSession(
            for: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/routing.audio"))), negotiatedAPI: 1
        )
        let updated = try await host.perform(mediaAction: .seek(42), in: session)
        #expect(updated.mediaPlayback?.position == 42)
        #expect(provider.mediaActions == [.seek(42)])
        #expect(provider.commands.isEmpty)
        await #expect(throws: MediaTransportError.invalidAction) {
            try await host.perform(mediaAction: .seek(-1), in: session)
        }
        #expect(provider.mediaActions.count == 1)
        #expect(HiFiLegacyAdapter.mediaAction(for: "hifi.play", in: session) == nil)
    }

    @Test func legacyMediaSeekEncodesPositionWithoutMutatingOriginal() async throws {
        let provider = MediaRoutingTestProvider()
        var session = ContentSession(
            extensionID: nil, providerID: "audio.hifi",
            request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/routing.dsf"))),
            presentation: .text(titleKey: "Test", body: "DSD")
        )
        session.mediaPlayback = .init(duration: 100, isSeekable: true)
        let updated = try await HiFiLegacyAdapter.perform(mediaAction: .seek(42), session: session, provider: provider)
        #expect(provider.commands == ["hifi.seek"])
        #expect(updated.mediaPlayback?.position == 42)
        #expect(session.mediaPlayback?.position == 0)
        #expect(HiFiLegacyAdapter.mediaAction(for: "hifi.pause", in: session) == .pause)
        #expect(HiFiLegacyAdapter.mediaAction(for: "hifi.device.opaque-uid", in: session) == .selectDevice("opaque-uid"))
        #expect(ExtensionSessionOperation.media(.selectDevice("opaque-uid")).selectedDeviceID == "opaque-uid")
        #expect(ExtensionSessionOperation.command("other.command").mediaAction == nil)
    }
}

@MainActor
private final class MediaRoutingTestProvider: ContentProvider {
    let descriptor = ProviderDescriptor(
        id: "test.generic-media-routing", extensionID: nil, role: .primary,
        fallbackProviderID: nil, enhancementDomain: nil, contentFamily: .audio, filenameExtensions: [],
        isEnabled: true, isRuntimeAvailable: true
    )
    var mediaActions: [MediaPlaybackAction] = []
    var commands: [String] = []
    func match(_ request: ContentRequest) -> ProviderMatch? { nil }
    func makeSession(for request: ContentRequest, negotiatedAPI: UInt32) async throws -> ContentSession {
        var session = ContentSession(
            extensionID: nil, providerID: descriptor.id, request: request,
            presentation: .text(titleKey: "Test", body: "Generic")
        )
        session.mediaPlayback = .init(duration: 100, isSeekable: true)
        return session
    }
    func perform(mediaAction: MediaPlaybackAction, session: ContentSession) async throws -> ContentSession {
        mediaActions.append(mediaAction)
        var updated = session
        if case .seek(let position) = mediaAction { updated.mediaPlayback?.position = position }
        return updated
    }
    func perform(commandID: String, session: ContentSession) async throws -> ContentSession {
        commands.append(commandID)
        return session
    }
}
