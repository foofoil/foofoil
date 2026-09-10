import Foundation

extension HiFiLegacyAdapter {
    /// 仅给未声明 `content.probe` 的旧 Hi-Fi 做 P0 回退；新 Runtime 由扩展嗅探。
    nonisolated static func sniffSACDISOMagic(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "iso" else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let offset = UInt64(510) * 2048
        guard let size = try? handle.seekToEnd(), size >= offset + 8 else { return false }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: 8), data.count == 8 else { return false }
            return data == Data("SACDMTOC".utf8)
        } catch {
            return false
        }
    }
}
