import CryptoKit
import Darwin
import Foundation

/// `hev1` 样本描述的 HEVC 在 macOS 上会因找不到解码器而无法播放（VideoToolbox -12906）。
/// 配置完整时在应用缓存目录生成 APFS 克隆副本并改写为 `hvc1`，原文件保持不变。
///
/// 副本路径由源路径、大小和修改时间派生，源文件变化后自然指向新副本；副本以 `cached_playable_` 开头，
/// 历史删除与清理会像其它缓存文件一样回收它。
nonisolated enum FragmentedMP4PlaybackCopy {
    static let filePrefix = "cached_playable_"
    private static let lock = NSLock()
    private static let preparationQueue = DispatchQueue(label: "com.foofoil.media-compatibility", qos: .userInitiated)

    /// 打开探测阶段在后台读取 moov 并准备克隆；播放器之后直接复用已发布的副本。
    static func prepare(for source: URL) async -> URL {
        await withCheckedContinuation { continuation in
            preparationQueue.async { continuation.resume(returning: playableURL(for: source)) }
        }
    }

    /// 源文件的播放副本路径；只处理系统播放器使用的 MP4 家族，不接受其它容器。
    static func copyURL(for source: URL) -> URL? {
        guard source.isFileURL,
              ["m4s", "mp4", "m4v", "mov"].contains(source.pathExtension.lowercased()),
              let directory = AppState.getFoofoilDirectoryURL(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let key = "hvc1-v2|\(source.resolvingSymlinksInPath().standardizedFileURL.path)|\(size.int64Value)|\(modified.timeIntervalSince1970)"
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(filePrefix)\(digest).mp4", isDirectory: false)
    }

    /// 可交给 AVFoundation 播放的地址：需要修正时返回副本，否则返回源文件。
    static func playableURL(for source: URL) -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let copy = copyURL(for: source) else { return source }
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        let offsets = FragmentedMP4Probe.hev1TagOffsets(of: source)
        guard !offsets.isEmpty,
              makeCopy(of: source, to: copy, patchingTagsAt: offsets) else { return source }
        return copy
    }

    /// 先克隆到临时文件并改写，完成后原子替换目标，避免其它窗口读到半成品。
    private static func makeCopy(of source: URL, to destination: URL, patchingTagsAt offsets: [UInt64]) -> Bool {
        let directory = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".playable_tmp_\(UUID().uuidString).tmp")
        guard clonefile(source.path, temporary.path, 0) == 0 else {
            // 不退回整片复制：跨卷或不支持克隆时保留系统原有的失败处理，避免额外占用数 GB。
            NSLog("无法克隆媒体兼容副本：%d", errno)
            return false
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let handle = try FileHandle(forUpdating: temporary)
            defer { try? handle.close() }
            for offset in offsets {
                try handle.seek(toOffset: offset)
                guard try handle.read(upToCount: 4) == Data("hev1".utf8) else { return false }
                try handle.seek(toOffset: offset)
                try handle.write(contentsOf: Data("hvc1".utf8))
            }
        } catch {
            return false
        }
        // 克隆共享影片的数据块，不按整片逻辑大小挤占普通缓存配额；历史清理及启动回收仍管理它。
        // 同目录原子发布，不再经 copyItem 复制一遍；源文件在准备期间变化则放弃该副本。
        guard copyURL(for: source) == destination else { return false }
        return rename(temporary.path, destination.path) == 0
    }
}
