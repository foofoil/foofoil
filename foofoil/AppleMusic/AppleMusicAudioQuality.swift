import Foundation
import MusicKit

/// 播放器当前音质与曲目可用版本分开处理，不从标签上限推断采样率或位深。
nonisolated enum AppleMusicAudioQuality {
    static func summary(current: AudioVariant?, available: [AudioVariant]?) -> String? {
        if let current, let label = label(current) {
            return label
        }
        let order: [AudioVariant] = [.highResolutionLossless, .lossless, .dolbyAtmos, .dolbyAudio, .spatialAudio, .lossyStereo]
        let labels = order.filter { available?.contains($0) == true }.compactMap(label)
        guard !labels.isEmpty else { return nil }
        return String(format: NSLocalizedString("Music Available Quality Format", comment: ""), labels.joined(separator: " / "))
    }

    static func isLossless(current: AudioVariant?, available: [AudioVariant]?) -> Bool {
        if let current { return current == .lossless || current == .highResolutionLossless }
        return available?.contains { $0 == .lossless || $0 == .highResolutionLossless } ?? false
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
