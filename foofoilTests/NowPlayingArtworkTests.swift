import AppKit
import Combine
import MediaPlayer
import Testing
@testable import foofoil

@MainActor
struct NowPlayingArtworkTests {
    @Test func artworkFollowsActiveTargetAndClearsWhenMissing() {
        let coordinator = MediaRemoteCommandCoordinator.shared
        let first = ArtworkTransport()
        let second = ArtworkTransport()
        let cover = NSImage(size: NSSize(width: 120, height: 80))
        let otherCover = NSImage(size: NSSize(width: 60, height: 60))
        let center = MPNowPlayingInfoCenter.default()
        func artwork() -> MPMediaItemArtwork? {
            center.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        }
        defer { coordinator.deactivate(second) }

        coordinator.updateArtwork(cover, for: first)
        coordinator.activate(first, title: "First")
        #expect(artwork()?.bounds.size == cover.size)
        coordinator.update(first)
        #expect(artwork()?.bounds.size == cover.size)

        coordinator.updateArtwork(otherCover, for: second)
        #expect(artwork()?.bounds.size == cover.size)
        coordinator.activate(second, title: "Second")
        #expect(artwork()?.bounds.size == otherCover.size)
        coordinator.deactivate(first)
        #expect(artwork()?.bounds.size == otherCover.size)

        coordinator.updateArtwork(nil, for: second)
        #expect(artwork() == nil)
        coordinator.updateArtwork(otherCover, for: second)
        coordinator.deactivate(second)
        #expect(center.nowPlayingInfo == nil)
    }
}

@MainActor
private final class ArtworkTransport: MediaTransportControlling {
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 100
    var isMuted = false
    var volume: Float = 1
    var volumeIconName = "speaker.wave.2"
    var isScrubbing = false
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func togglePlayPause() { isPlaying.toggle() }
    func toggleMute() {}
    func setVolume(_ newValue: Float) {}
    func seek(to time: Double) {}
    func adjustTime(by delta: Double) {}
    func adjustVolume(by delta: Float) {}
    func playPreviousItem() -> Bool { false }
    func playNextItem() -> Bool { false }
}
