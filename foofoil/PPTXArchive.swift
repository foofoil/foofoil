//  PPTXArchive.swift
//  foofoil
//
//  Created by 董超 on 2026/9/13.
//

import Compression
import Foundation

/// PPTX ZIP 读取器（复用 EPUB 的本地 ZIP 算法）：解析中央目录，按需解压单个 entry，不整包落盘。
/// 所有 offset/size 在使用前校验，deflate 使用 Compression 的 raw DEFLATE 并核对 CRC。
nonisolated struct PPTXArchive {
    struct Entry: Sendable {
        let path: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    let url: URL
    let entries: [String: Entry]
    let entryCount: Int

    private let fileHandle: FileHandle
    private let fileSize: UInt64
    private let limits: PPTXArchiveLimits

    init(url: URL, limits: PPTXArchiveLimits = .default) throws {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, size > 0 else {
            throw PPTXError.invalidArchive
        }
        guard UInt64(size) <= limits.maxFileBytes else { throw PPTXError.limitExceeded }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PPTXError.invalidArchive
        }
        self.url = url
        self.fileHandle = handle
        self.fileSize = UInt64(size)
        self.limits = limits
        let directory = try Self.readCentralDirectory(handle: handle, fileSize: UInt64(size), limits: limits)
        self.entries = directory
        self.entryCount = directory.count
    }

    func contains(_ path: String) -> Bool {
        entries[path] != nil
    }

    func data(for path: String, maxBytes: Int? = nil) throws -> Data {
        guard let entry = entries[path] else { throw PPTXError.missingResource(path) }
        return try data(for: entry, maxBytes: maxBytes)
    }

    func data(for entry: Entry, maxBytes: Int? = nil) throws -> Data {
        let allowed = min(maxBytes ?? limits.maxEntryOutputBytes, limits.maxEntryOutputBytes)
        guard entry.uncompressedSize <= UInt64(allowed) else { throw PPTXError.limitExceeded }
        let header = try Self.read(handle: fileHandle, offset: entry.localHeaderOffset, count: 30)
        guard header.u32(0) == 0x04034b50 else { throw PPTXError.invalidArchive }
        let nameLength = Int(header.u16(26) ?? 0)
        let extraLength = Int(header.u16(28) ?? 0)
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(nameLength) + UInt64(extraLength)
        guard dataOffset >= entry.localHeaderOffset,
              dataOffset <= fileSize,
              entry.compressedSize <= fileSize - dataOffset else { throw PPTXError.invalidArchive }
        let compressed = try Self.read(handle: fileHandle, offset: dataOffset, count: Int(entry.compressedSize))
        let output: Data
        switch entry.method {
        case 0:
            output = compressed
        case 8:
            output = try Self.inflate(compressed, expectedSize: Int(entry.uncompressedSize), limit: allowed)
        default:
            throw PPTXError.unsupportedContent
        }
        guard output.count == Int(entry.uncompressedSize),
              PPTXCRC32.checksum(output) == entry.crc32 else { throw PPTXError.invalidArchive }
        return output
    }

    // MARK: - 中央目录

    private static func readCentralDirectory(
        handle: FileHandle,
        fileSize: UInt64,
        limits: PPTXArchiveLimits
    ) throws -> [String: Entry] {
        let searchSize = min(fileSize, UInt64(22 + 65_535))
        let tail = try read(handle: handle, offset: fileSize - searchSize, count: Int(searchSize))
        guard let eocd = lastIndex(of: 0x06054b50, in: tail), eocd + 22 <= tail.count else {
            throw PPTXError.invalidArchive
        }
        guard tail.u16(eocd + 4) == 0, tail.u16(eocd + 6) == 0 else { throw PPTXError.invalidArchive }
        var entryCount = Int(tail.u16(eocd + 10) ?? 0)
        var directorySize = UInt64(tail.u32(eocd + 12) ?? 0)
        var directoryOffset = UInt64(tail.u32(eocd + 16) ?? 0)

        if entryCount == 0xFFFF || directorySize == 0xFFFFFFFF || directoryOffset == 0xFFFFFFFF {
            guard eocd >= 20, tail.u32(eocd - 20) == 0x07064b50 else { throw PPTXError.invalidArchive }
            let zip64Offset = tail.u64(eocd - 12) ?? 0
            guard zip64Offset <= fileSize, fileSize - zip64Offset >= 56 else { throw PPTXError.invalidArchive }
            let zip64 = try read(handle: handle, offset: zip64Offset, count: 56)
            guard zip64.u32(0) == 0x06064b50 else { throw PPTXError.invalidArchive }
            entryCount = Int(zip64.u64(32) ?? 0)
            directorySize = zip64.u64(40) ?? 0
            directoryOffset = zip64.u64(48) ?? 0
        }

        guard entryCount <= limits.maxEntryCount else { throw PPTXError.limitExceeded }
        guard directorySize <= UInt64(limits.maxCentralDirectoryBytes) else { throw PPTXError.limitExceeded }
        guard directoryOffset <= fileSize, directorySize <= fileSize - directoryOffset else {
            throw PPTXError.invalidArchive
        }
        let directory = try read(handle: handle, offset: directoryOffset, count: Int(directorySize))

        var result: [String: Entry] = [:]
        result.reserveCapacity(entryCount)
        var cursor = 0
        while cursor + 46 <= directory.count {
            guard directory.u32(cursor) == 0x02014b50 else { throw PPTXError.invalidArchive }
            let flags = directory.u16(cursor + 8) ?? 0
            let method = directory.u16(cursor + 10) ?? 0
            let crc = directory.u32(cursor + 16) ?? 0
            var compressedSize = UInt64(directory.u32(cursor + 20) ?? 0)
            var uncompressedSize = UInt64(directory.u32(cursor + 24) ?? 0)
            let nameLength = Int(directory.u16(cursor + 28) ?? 0)
            let extraLength = Int(directory.u16(cursor + 30) ?? 0)
            let commentLength = Int(directory.u16(cursor + 32) ?? 0)
            let diskStart = directory.u16(cursor + 34) ?? 0
            let externalAttributes = directory.u32(cursor + 38) ?? 0
            var localHeaderOffset = UInt64(directory.u32(cursor + 42) ?? 0)
            let end = cursor + 46 + nameLength + extraLength + commentLength
            guard end <= directory.count else { throw PPTXError.invalidArchive }
            let nameData = directory.subdata(in: cursor + 46 ..< cursor + 46 + nameLength)

            try parseZIP64Extra(
                directory.subdata(in: cursor + 46 + nameLength ..< cursor + 46 + nameLength + extraLength),
                compressedSize: &compressedSize,
                uncompressedSize: &uncompressedSize,
                localHeaderOffset: &localHeaderOffset
            )

            guard flags & 0x0001 == 0 else { throw PPTXError.encrypted }
            guard diskStart == 0 else { throw PPTXError.invalidArchive }
            guard method == 0 || method == 8 else { throw PPTXError.unsupportedContent }
            guard localHeaderOffset < fileSize else { throw PPTXError.invalidArchive }
            guard (externalAttributes >> 16) & 0xF000 != 0xA000 else { throw PPTXError.invalidArchive }
            guard let rawName = String(data: nameData, encoding: .utf8) else { throw PPTXError.invalidArchive }
            let path = try validatedPath(rawName)
            guard result[path] == nil else { throw PPTXError.invalidArchive }
            result[path] = Entry(
                path: path,
                method: method,
                flags: flags,
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            )
            cursor = end
        }
        guard cursor == directory.count else { throw PPTXError.invalidArchive }
        guard result.count == entryCount else { throw PPTXError.invalidArchive }
        return result
    }

    /// ZIP64 extra（0x0001）按“仅对哨兵值补位”的顺序读取。
    private static func parseZIP64Extra(
        _ extra: Data,
        compressedSize: inout UInt64,
        uncompressedSize: inout UInt64,
        localHeaderOffset: inout UInt64
    ) throws {
        guard compressedSize == 0xFFFFFFFF || uncompressedSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF else {
            return
        }
        var cursor = 0
        while cursor + 4 <= extra.count {
            let fieldID = extra.u16(cursor) ?? 0
            let fieldSize = Int(extra.u16(cursor + 2) ?? 0)
            guard cursor + 4 + fieldSize <= extra.count else { throw PPTXError.invalidArchive }
            if fieldID == 0x0001 {
                var valueCursor = cursor + 4
                if uncompressedSize == 0xFFFFFFFF {
                    guard valueCursor + 8 <= cursor + 4 + fieldSize,
                          let value = extra.u64(valueCursor) else { throw PPTXError.invalidArchive }
                    uncompressedSize = value
                    valueCursor += 8
                }
                if compressedSize == 0xFFFFFFFF {
                    guard valueCursor + 8 <= cursor + 4 + fieldSize,
                          let value = extra.u64(valueCursor) else { throw PPTXError.invalidArchive }
                    compressedSize = value
                    valueCursor += 8
                }
                if localHeaderOffset == 0xFFFFFFFF {
                    guard valueCursor + 8 <= cursor + 4 + fieldSize,
                          let value = extra.u64(valueCursor) else { throw PPTXError.invalidArchive }
                    localHeaderOffset = value
                }
                return
            }
            cursor += 4 + fieldSize
        }
        throw PPTXError.invalidArchive
    }

    /// 拒绝绝对路径、NUL、反斜杠和任何 `..`／`.` 组件；规范化重复路径由调用方处理。
    static func validatedPath(_ raw: String) throws -> String {
        guard !raw.isEmpty, !raw.contains("\0"), !raw.hasPrefix("/"), !raw.contains("\\") else {
            throw PPTXError.invalidArchive
        }
        var components: [Substring] = []
        for component in raw.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty { continue }
            guard component != ".", component != ".." else { throw PPTXError.invalidArchive }
            components.append(component)
        }
        guard !components.isEmpty else { throw PPTXError.invalidArchive }
        return components.joined(separator: "/")
    }

    // MARK: - 二进制读取

    static func read(handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else { throw PPTXError.invalidArchive }
        if count == 0 { return Data() }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw PPTXError.invalidArchive
            }
            return data
        } catch let error as PPTXError {
            throw error
        } catch {
            throw PPTXError.invalidArchive
        }
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var index = data.count - 4
        while index >= 0 {
            if data.u32(index) == signature { return index }
            index -= 1
        }
        return nil
    }

    private static func inflate(_ input: Data, expectedSize: Int, limit: Int) throws -> Data {
        guard expectedSize <= limit else { throw PPTXError.limitExceeded }
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let produced = output.withUnsafeMutableBytes { destination -> Int in
            input.withUnsafeBytes { source -> Int in
                guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                      let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, expectedSize, src, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard produced == expectedSize else { throw PPTXError.invalidArchive }
        return output
    }
}

/// ZIP 使用的标准 CRC-32；测试 ZIP 生成器复用同一实现。
nonisolated enum PPTXCRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0 ..< 8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }
}

private extension Data {
    nonisolated func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }.littleEndian
    }

    nonisolated func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
    }

    nonisolated func u64(_ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }.littleEndian
    }
}

nonisolated struct PPTXArchiveLimits {
    static let `default` = Self()
    var maxFileBytes: UInt64 = 1 << 30
    var maxEntryCount = 50_000
    var maxCentralDirectoryBytes = 32 << 20
    var maxEntryOutputBytes = 8 << 20
}

nonisolated enum PPTXError: Error {
    case invalidArchive, limitExceeded, unsupportedContent, encrypted
    case missingResource(String)
}

extension PPTXArchive {
    /// 重写中央目录并原样复制压缩资源；只替换 presentation.xml，避免解压图片或执行外部程序。
    nonisolated func writePresentation(_ xml: Data, to destination: URL) throws {
        guard entries["ppt/presentation.xml"] != nil else { throw PPTXError.invalidArchive }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw PPTXError.invalidArchive }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var directory = Data()
        for entry in entries.values.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let offset = try output.offset()
            let replacement = entry.path == "ppt/presentation.xml" ? xml : nil
            let size = replacement.map { UInt64($0.count) } ?? entry.uncompressedSize
            let compressedSize = replacement.map { UInt64($0.count) } ?? entry.compressedSize
            guard offset <= UInt32.max, size <= UInt32.max, compressedSize <= UInt32.max else {
                throw PPTXError.limitExceeded
            }
            let method: UInt16 = replacement == nil ? entry.method : 0
            let crc = replacement.map(PPTXCRC32.checksum) ?? entry.crc32
            let name = Data(entry.path.utf8)
            let flags: UInt16 = 0x0800
            var header = Data()
            header.appendLE(UInt32(0x04034b50)); header.appendLE(UInt16(20))
            header.appendLE(flags); header.appendLE(method)
            header.appendLE(UInt16(0)); header.appendLE(UInt16(0))
            header.appendLE(crc); header.appendLE(UInt32(compressedSize)); header.appendLE(UInt32(size))
            header.appendLE(UInt16(name.count)); header.appendLE(UInt16(0)); header.append(name)
            try output.write(contentsOf: header)
            if let replacement {
                try output.write(contentsOf: replacement)
            } else {
                let sourceHeader = try Self.read(handle: fileHandle, offset: entry.localHeaderOffset, count: 30)
                guard sourceHeader.u32(0) == 0x04034b50 else { throw PPTXError.invalidArchive }
                var sourceOffset = entry.localHeaderOffset + 30 + UInt64(sourceHeader.u16(26)!) + UInt64(sourceHeader.u16(28)!)
                guard sourceOffset <= fileSize, compressedSize <= fileSize - sourceOffset else { throw PPTXError.invalidArchive }
                var remaining = compressedSize
                while remaining > 0 {
                    try Task.checkCancellation()
                    let count = Int(min(remaining, 1 << 20))
                    try output.write(contentsOf: Self.read(handle: fileHandle, offset: sourceOffset, count: count))
                    sourceOffset += UInt64(count); remaining -= UInt64(count)
                }
            }
            directory.appendLE(UInt32(0x02014b50)); directory.appendLE(UInt16(20)); directory.appendLE(UInt16(20))
            directory.appendLE(flags); directory.appendLE(method)
            directory.appendLE(UInt16(0)); directory.appendLE(UInt16(0))
            directory.appendLE(crc); directory.appendLE(UInt32(compressedSize)); directory.appendLE(UInt32(size))
            directory.appendLE(UInt16(name.count))
            for _ in 0..<4 { directory.appendLE(UInt16(0)) }
            directory.appendLE(UInt32(0)); directory.appendLE(UInt32(offset)); directory.append(name)
        }
        let directoryOffset = try output.offset()
        guard directoryOffset <= UInt32.max else { throw PPTXError.limitExceeded }
        try output.write(contentsOf: directory)
        var end = Data()
        end.appendLE(UInt32(0x06054b50)); end.appendLE(UInt16(0)); end.appendLE(UInt16(0))
        end.appendLE(UInt16(entries.count)); end.appendLE(UInt16(entries.count))
        end.appendLE(UInt32(directory.count)); end.appendLE(UInt32(directoryOffset)); end.appendLE(UInt16(0))
        try output.write(contentsOf: end)
    }
}

private extension Data {
    nonisolated mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
