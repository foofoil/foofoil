import Foundation
import MusicKit
import Testing
@testable import foofoil

struct AppleMusicAudioQualityTests {
    @Test func currentPlaybackQualityDoesNotInventNumericFormat() {
        let result = AppleMusicAudioQuality.summary(current: .lossyStereo)
        #expect(result == NSLocalizedString("Music Quality Lossy Stereo", comment: ""))
        #expect(result?.contains("192") == false)
        #expect(result?.contains("Music Playing Quality Format") == false)
        #expect(AppleMusicAudioQuality.label(.lossyStereo)?.contains("Music Quality") == false)
    }

    @Test func unknownPlaybackQualityRemainsHidden() {
        #expect(AppleMusicAudioQuality.summary(current: nil) == nil)
        #expect(!AppleMusicAudioQuality.isLossless(current: nil))
    }

    @Test func losslessMarkFollowsActualQuality() {
        #expect(AppleMusicAudioQuality.isLossless(current: .lossless))
        #expect(AppleMusicAudioQuality.isLossless(current: .highResolutionLossless))
        #expect(!AppleMusicAudioQuality.isLossless(current: .lossyStereo))
        #expect(!AppleMusicAudioQuality.isLossless(current: .dolbyAtmos))
        #expect(!AppleMusicAudioQuality.isLossless(current: nil))
        #expect(AppleMusicAudioQuality.summary(current: .lossless) == AppleMusicAudioQuality.label(.lossless))
    }

    @Test func unavailableMetadataDoesNotCreateQualityLabel() {
        #expect(AppleMusicAudioQuality.summary(current: nil) == nil)
        #expect(AppleMusicAudioQuality.summary(current: .dolbyAtmos) != nil)
    }
}
