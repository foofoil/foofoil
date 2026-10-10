import Foundation
import MusicKit

/// 只使用播放器当前音质，不把曲目支持的格式当作正在播放的格式。
nonisolated enum AppleMusicAudioQuality {
    static func summary(current: AudioVariant?) -> String? {
        current.flatMap(label)
    }

    static func isLossless(current: AudioVariant?) -> Bool {
        current == .lossless || current == .highResolutionLossless
    }

    static func label(_ variant: AudioVariant) -> String? {
        let key: String
        switch variant {
        case .highResolutionLossless: key = "Music Quality Hi Res Lossless"
        case .lossless: key = "Music Quality Lossless"
        case .dolbyAtmos: key = "Music Quality Dolby Atmos"
        case .dolbyAudio: key = "Music Quality Dolby Audio"
        case .spatialAudio: key = "Music Quality Spatial Audio"
        case .lossyStereo: key = "Music Quality Lossy Stereo"
        @unknown default: return nil
        }
        return NSLocalizedString(key, comment: "")
    }
}
