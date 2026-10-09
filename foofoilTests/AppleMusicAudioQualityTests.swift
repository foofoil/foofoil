import Foundation
import MusicKit
import Testing
@testable import foofoil

struct AppleMusicAudioQualityTests {
    @Test func currentPlaybackQualityTakesPriorityOverAvailableHiRes() {
        let result = AppleMusicAudioQuality.summary(current: .lossyStereo, available: [.lossless, .highResolutionLossless])
        #expect(result == String(format: NSLocalizedString("Music Playing Quality Format", comment: ""),
                                NSLocalizedString("Music Quality Lossy Stereo", comment: "")))
        #expect(result?.contains("192") == false)
        #expect(result?.contains("Music Playing Quality Format") == false)
        #expect(AppleMusicAudioQuality.label(.lossyStereo)?.contains("Music Quality") == false)
    }

    @Test func availableVersionsAreExplicitAndDoNotInventNumericFormat() {
        let result = AppleMusicAudioQuality.summary(current: nil, available: [.lossless, .highResolutionLossless, .lossless])
        let labels = ["Music Quality Hi Res Lossless", "Music Quality Lossless"].map { NSLocalizedString($0, comment: "") }
        #expect(result == String(format: NSLocalizedString("Music Available Quality Format", comment: ""), labels.joined(separator: " / ")))
        var info = AudioTrackInfo.fallback(fileName: "Test song")
        info.qualitySummary = result
        #expect(info.sampleRate == nil && info.bitDepth == nil && info.bitRate == nil && info.channelCount == nil)
        #expect(info.formatName == nil)
    }

    @Test func unavailableMetadataDoesNotCreateQualityLabel() {
        #expect(AppleMusicAudioQuality.summary(current: nil, available: nil) == nil)
        #expect(AppleMusicAudioQuality.summary(current: nil, available: []) == nil)
        #expect(AppleMusicAudioQuality.summary(current: .dolbyAtmos, available: nil) != nil)
    }
}
