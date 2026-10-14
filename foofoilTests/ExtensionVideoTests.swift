import Testing
import Foundation
import AppKit
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
    @Test func singleFileVideoHistoryKeepsSourceWithoutAList() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        for ext in ["mkv", "avi"] {
            let url = directory.appendingPathComponent("movie." + ext)
            try Data([0]).write(to: url)
            let state = AppState()
            state.extensionSession = ContentSession(extensionID: "app.foofoil.extension.sample", providerID: "sample.video",
                request: .singleFile(.init(url: url, securityScopedBookmark: Data([1, 2]))),
                presentation: .video(.init(surfaceID: 0, width: 1920, height: 1080, revision: 0)))
            let config = state.toConfig()
            defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
            #expect(config.imagePath == url.path)
            #expect(config.videoBookmark == Data([1, 2]))
            #expect(repo.upsert(config))
            #expect(repo.recent(limit: 10).contains { $0.id == config.id })
            state.extensionSession = nil
        }
    }
    @Test func allVideoResolutionsUseTheSameInitialDisplaySize() {
        for source in [NSSize(width: 1920, height: 1080), NSSize(width: 640, height: 360), NSSize(width: 3840, height: 2160)] {
            let size = FloatingWindowController.initialVideoContentSize(sourceSize: source)
            #expect(abs(size.width - 720) < 0.01)
            #expect(abs(size.height - 405) < 0.01)
        }
        let portrait = FloatingWindowController.initialVideoContentSize(sourceSize: NSSize(width: 1080, height: 1920))
        #expect(portrait.height == 480)
        #expect(portrait.width == 270)
    }
}
