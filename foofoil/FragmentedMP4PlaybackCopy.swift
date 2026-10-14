import CryptoKit
import Darwin
import Foundation

/// `hev1` 样本描述的分片 HEVC 在 macOS 上会因找不到解码器而无法播放（VideoToolbox -12906），
/// 同一码流标记为 `hvc1` 即可解码。播放时在应用缓存目录生成 APFS 克隆副本并改写该四字符码，原文件保持不变。
///
/// 副本路径由源路径、大小和修改时间派生，源文件变化后自然指向新副本；副本以 `cached_playable_` 开头，
/// 历史删除与清理会像其它缓存文件一样回收它。
nonisolated enum FragmentedMP4PlaybackCopy {
    static let filePrefix = "cached_playable_"

    /// 源文件的播放副本路径；非 `.m4s` 或无法读取属性时返回 nil。
    static func copyURL(for source: URL) -> URL? {
        guard source.isFileURL,
              source.pathExtension.lowercased() == "m4s",
              let directory = AppState.getFoofoilDirectoryURL(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let key = "\(source.resolvingSymlinksInPath().standardizedFileURL.path)|\(size.int64Value)|\(modified.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(filePrefix)\(digest).mp4", isDirectory: false)
    }

    /// 可交给 AVFoundation 播放的地址：需要修正时返回副本，否则返回源文件。
    static func playableURL(for source: URL) -> URL {
        guard let copy = copyURL(for: source) else { return source }
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        guard let offset = FragmentedMP4Probe.hev1TagOffset(of: source),
              makeCopy(of: source, to: copy, patchingTagAt: offset) else { return source }
        return copy
    }

    /// 先克隆到临时文件并改写，完成后原子替换目标，避免其它窗口读到半成品。
    private static func makeCopy(of source: URL, to destination: URL, patchingTagAt offset: UInt64) -> Bool {
        let directory = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".playable_tmp_\(UUID().uuidString).tmp")
        guard clonefile(source.path, temporary.path, 0) == 0 else {
            NSLog("无法克隆分片媒体副本：%d", errno)
            return false
        }
        do {
            let handle = try FileHandle(forUpdating: temporary)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data("hvc1".utf8))
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (try? ContentCache.shared.copy(from: temporary, to: destination)) != nil else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        return true
    }
}
