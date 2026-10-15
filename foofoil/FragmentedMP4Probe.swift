import AVFoundation
import Foundation

extension AVURLAsset {
    /// 创建用于播放或读取元数据的资源。AVFoundation 依据扩展名选择容器解析器，`.m4s` 没有对应类型，
    /// 因此以 MP4 容器提示打开；内容本身仍由系统解析，音视频轨道以文件实际内容为准。
    nonisolated static func media(url: URL) -> AVURLAsset {
        guard url.pathExtension.lowercased() == "m4s" else { return AVURLAsset(url: url) }
        let playable = FragmentedMP4PlaybackCopy.playableURL(for: url)
        return AVURLAsset(url: playable, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
    }
}

/// 分片 MP4（fMP4，常见扩展名 `.m4s`）的轨道类型探测。
///
/// 只按 ISO BMFF 的 box 结构读取：文件必须以 `ftyp` 开头，并且在第一个 `moof` 之前存在 `moov` 初始化段。
/// 轨道类型取自 `moov/trak/mdia/hdlr` 的 handler_type。缺少初始化段的纯媒体分段没有编码与轨道信息，返回 nil。
nonisolated enum FragmentedMP4Probe {
    enum TrackKind: Equatable, Sendable {
        case video
        case audio
    }

    /// 初始化段体积上限，超出即放弃探测，避免为异常文件读入大块数据。
    private static let maxMoovSize: UInt64 = 32 * 1024 * 1024
    private static let maxTopLevelBoxes = 256

    static func trackKind(of url: URL) -> TrackKind? {
        guard let moov = loadMoov(of: url) else { return nil }
        return trackKind(inMoov: moov.bytes)
    }

    /// 视频样本描述为 `hev1` 时，返回该四字符码在文件中的偏移；其它情况返回 nil。
    static func hev1TagOffset(of url: URL) -> UInt64? {
        guard let moov = loadMoov(of: url),
              let relative = hev1TagOffset(inMoov: moov.bytes) else { return nil }
        return moov.fileOffset + UInt64(relative)
    }

    private struct MoovPayload {
        let bytes: [UInt8]
        let fileOffset: UInt64
    }

    private struct Box {
        let type: String
        let start: UInt64
        let headerSize: UInt64
        let size: UInt64

        var payloadStart: UInt64 { start + headerSize }
        var end: UInt64 { start + size }
    }

    private static func loadMoov(of url: URL) -> MoovPayload? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(),
              let first = readBox(at: 0, handle: handle, fileSize: fileSize),
              first.type == "ftyp" else { return nil }

        var offset = first.end
        for _ in 0..<maxTopLevelBoxes {
            guard let box = readBox(at: offset, handle: handle, fileSize: fileSize) else { return nil }
            switch box.type {
            case "moov":
                guard box.size <= maxMoovSize,
                      let data = read(handle, at: box.payloadStart, count: Int(box.end - box.payloadStart))
                else { return nil }
                return MoovPayload(bytes: [UInt8](data), fileOffset: box.payloadStart)
            case "moof":
                return nil
            default:
                offset = box.end
            }
        }
        return nil
    }

    private static func readBox(at offset: UInt64, handle: FileHandle, fileSize: UInt64) -> Box? {
        guard offset + 8 <= fileSize,
              let data = read(handle, at: offset, count: Int(min(16, fileSize - offset))) else { return nil }
        let bytes = [UInt8](data)
        var size = readBigEndian(bytes, at: 0, count: 4)
        var headerSize: UInt64 = 8
        if size == 1 {
            guard bytes.count >= 16 else { return nil }
            size = readBigEndian(bytes, at: 8, count: 8)
            headerSize = 16
        } else if size == 0 {
            size = fileSize - offset
        }
        guard size >= headerSize, offset + size <= fileSize else { return nil }
        return Box(type: fourCC(bytes, at: 4), start: offset, headerSize: headerSize, size: size)
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard count > 0, (try? handle.seek(toOffset: offset)) != nil else { return nil }
        guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }

    private static func trackKind(inMoov bytes: [UInt8]) -> TrackKind? {
        var handlers = Set<String>()
        for trak in children(in: bytes, 0..<bytes.count) where trak.type == "trak" {
            guard let handler = handlerType(inTrak: trak, bytes: bytes) else { continue }
            handlers.insert(handler)
        }
        if handlers.contains("vide") { return .video }
        if handlers.contains("soun") { return .audio }
        return nil
    }

    private static func hev1TagOffset(inMoov bytes: [UInt8]) -> Int? {
        for trak in children(in: bytes, 0..<bytes.count) where trak.type == "trak" {
            guard handlerType(inTrak: trak, bytes: bytes) == "vide",
                  let minf = child("mdia", in: bytes, trak.payload).flatMap({ child("minf", in: bytes, $0.payload) }),
                  let stbl = child("stbl", in: bytes, minf.payload),
                  let stsd = child("stsd", in: bytes, stbl.payload),
                  stsd.payload.count >= 8 else { continue }
            // stsd 载荷：version/flags(4) + entry_count(4)，之后紧跟样本描述 box
            guard let entry = children(in: bytes, (stsd.payload.lowerBound + 8)..<stsd.payload.upperBound).first,
                  entry.type == "hev1" else { continue }
            return entry.start + 4
        }
        return nil
    }

    /// `hdlr` 载荷：version/flags(4) + pre_defined(4) + handler_type(4)。
    private static func handlerType(inTrak trak: Child, bytes: [UInt8]) -> String? {
        guard let mdia = child("mdia", in: bytes, trak.payload),
              let hdlr = child("hdlr", in: bytes, mdia.payload),
              hdlr.payload.count >= 12 else { return nil }
        return fourCC(bytes, at: hdlr.payload.lowerBound + 8)
    }

    private struct Child {
        let type: String
        let start: Int
        let payload: Range<Int>
    }

    private static func child(_ type: String, in bytes: [UInt8], _ range: Range<Int>) -> Child? {
        children(in: bytes, range).first { $0.type == type }
    }

    private static func children(in bytes: [UInt8], _ range: Range<Int>) -> [Child] {
        var result: [Child] = []
        var index = range.lowerBound
        while index + 8 <= range.upperBound {
            var size = readBigEndian(bytes, at: index, count: 4)
            var headerSize: UInt64 = 8
            if size == 1 {
                guard index + 16 <= range.upperBound else { break }
                size = readBigEndian(bytes, at: index + 8, count: 8)
                headerSize = 16
            } else if size == 0 {
                size = UInt64(range.upperBound - index)
            }
            guard size >= headerSize, size <= UInt64(range.upperBound - index) else { break }
            let length = Int(size)
            let payloadStart = index + Int(headerSize)
            result.append(Child(type: fourCC(bytes, at: index + 4), start: index, payload: payloadStart..<(index + length)))
            index += length
        }
        return result
    }

    private static func readBigEndian(_ bytes: [UInt8], at index: Int, count: Int) -> UInt64 {
        bytes[index..<(index + count)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func fourCC(_ bytes: [UInt8], at index: Int) -> String {
        String(decoding: bytes[index..<(index + 4)], as: UTF8.self)
    }
}
