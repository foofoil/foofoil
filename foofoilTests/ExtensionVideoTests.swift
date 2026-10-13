import Testing
import Foundation
import FoofoilExtensionKit
@testable import foofoil

@MainActor @Suite struct ExtensionVideoTests {
    private func session() -> ContentSession {
        .init(extensionID: "app.foofoil.extension.sample", providerID: "sample.video", request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/movie.mkv"))),
              presentation: .video(.init(surfaceID: 0, width: 1920, height: 1080, revision: 0)),
              capabilities: [.init(declaration: .init(id: "media.transport", scope: .session), state: .active)],
              mediaPlayback: .init(state: .paused, position: 2, duration: 10, volume: 0.5))
    }
    @Test func presentationUsesVideoInteractionAndHistoryWithoutAudioChrome() {
        let state = AppState()
        state.extensionSession = session()
        #expect(state.isVideoDocument)
        #expect(state.isExternalMediaDocument)
        #expect(!state.isAudioDocument)
        #expect(!ExtensionPlaybackSupport.usesHostAudioChrome(session()))
        #expect(state.toConfig().contentKind == .video)
        #expect(HistoryContentKind.infer(from: state.toConfig()) == .video)
        state.extensionSession = nil
    }
    @Test func videoVolumeIsSoftwareVolumeWithoutDeviceService() {
        let state = AppState()
        let controller = ExtensionAudioPlaybackController(appState: state, session: session())
        #expect(controller.supportsVolumeControl)
        #expect(controller.volume == 0.5)
        #expect(!controller.isMuted)
    }
}
