import Foundation

/// 后台探测结果包含原始条目，防止同 ID 更换文件后复用旧时长。
nonisolated struct FileListNavigatorMetadata: Sendable {
    let item: FileListItem
    let isAccessible: Bool
    let badge: String?

    static func load(item: FileListItem, kind: FileListKind) async -> Self {
        guard let url = AppState.resolveItemURL(item) else {
            return Self(item: item, isAccessible: false, badge: nil)
        }
        let seconds: Double?
        if let cue = item.cue {
            if let end = cue.endCueFrames, end > cue.startCueFrames {
                seconds = CueTime.seconds(from: end - cue.startCueFrames)
            } else {
                let timing: AudioPlaybackTiming?
                if let path = cue.cueSheetPath {
                    timing = CueSheetLoader.playbackTiming(audioURL: url, cueURL: URL(fileURLWithPath: path))
                } else {
                    let accessed = url.startAccessingSecurityScopedResource()
                    timing = AudioMetadataLoader.playbackTiming(for: url)
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                if let timing, timing.sampleRate > 0 {
                    let start = CueTime.sampleFrame(cueFrames: cue.startCueFrames, sampleRate: timing.sampleRate)
                    seconds = Double(max(0, timing.sampleCount - start)) / timing.sampleRate
                } else {
                    seconds = nil
                }
            }
        } else if kind == .audio || kind == .video {
            seconds = await MediaDurationLoader.duration(for: url, kind: kind)
        } else {
            seconds = nil
        }
        return Self(item: item, isAccessible: true, badge: seconds.flatMap(AudioMetadataLoader.formatDuration))
    }
}
