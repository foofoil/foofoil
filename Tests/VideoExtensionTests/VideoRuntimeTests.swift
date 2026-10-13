import Testing
import Foundation
import FoofoilExtensionKit
import FoofoilExtensionABI
import VideoExtensionRuntime

@Test func unsupportedInputsAreRejected() throws {
    let runtime = VideoRuntime()
    #expect(throws: ContentProviderError.self) {
        try runtime.create(.singleFile(.init(url: URL(fileURLWithPath: "/tmp/test.mp4"))))
    }
    #expect(throws: ContentProviderError.self) {
        try runtime.create(.singleFile(.init(url: URL(string: "https://example.com/movie.mkv")!)))
    }
    runtime.shutdown()
}
@Test func malformedCommandIsRejected() throws {
    let runtime = VideoRuntime()
    #expect(throws: ContentProviderError.self) { try runtime.perform(Data("{}".utf8)) }
    runtime.shutdown()
}
@Test func abiVersionAndLayout() {
    #expect(foofoilExtensionCreate(2) == nil)
    let pointer = foofoilExtensionCreate(1)
    #expect(pointer?.pointee.struct_size == MemoryLayout<FoofoilExtensionInterfaceV1>.size)
    #expect(pointer?.pointee.api_version == 1)
    #expect(pointer?.pointee.create_session != nil)
    #expect(pointer?.pointee.perform_command != nil)
}
@Test func videoPresentationRoundTrips() throws {
    let presentation = SessionPresentation.video(.init(surfaceID: 42, width: 1920, height: 1080, revision: 9))
    let decoded = try JSONDecoder().decode(SessionPresentation.self, from: JSONEncoder().encode(presentation))
    #expect(decoded == presentation)
}

@Test func realDecoderSeeksRestoresAndRejectsClosedSession() throws {
    let runtime = VideoRuntime()
    defer { runtime.shutdown() }
    let file = try #require(Bundle.module.url(forResource: "test", withExtension: "avi", subdirectory: "Fixtures"))
    var session = try runtime.create(.singleFile(.init(url: file)))
    guard case .video(let frame) = session.presentation else { Issue.record("Missing presentation"); return }
    #expect(frame.width == 64 && frame.height == 48 && frame.surfaceID != 0)
    #expect(session.mediaPlayback?.isSeekable == true)
    session = try runtime.perform(JSONEncoder().encode(MediaPlaybackRequest(action: .setVolume(0.25), session: session)))
    #expect(abs((session.mediaPlayback?.volume ?? 0) - 0.25) < 0.001)
    session = try runtime.perform(JSONEncoder().encode(MediaPlaybackRequest(action: .seek(1), session: session)))
    #expect(abs((session.mediaPlayback?.position ?? 0) - 1) < 0.05)
    let fresh = try runtime.create(.singleFile(.init(url: file)))
    let restored = try runtime.perform(JSONEncoder().encode(SessionLifecycleRequest(operation: .restore, session: fresh, restoration: .init(position: 1))))
    #expect(abs((restored.mediaPlayback?.position ?? 0) - 1) < 0.05)
    _ = try runtime.perform(JSONEncoder().encode(SessionLifecycleRequest(operation: .close, session: session)))
    #expect(throws: ContentProviderError.self) {
        try runtime.perform(JSONEncoder().encode(MediaPlaybackRequest(action: .refresh, session: session)))
    }
}
@Test func volumeActionRejectsNonFiniteAndOutOfRangeValues() {
    #expect(throws: MediaTransportError.self) { try MediaPlaybackAction.setVolume(-0.1).validate() }
    #expect(throws: MediaTransportError.self) { try MediaPlaybackAction.setVolume(1.1).validate() }
    #expect(throws: MediaTransportError.self) { try MediaPlaybackAction.setVolume(.nan).validate() }
}
