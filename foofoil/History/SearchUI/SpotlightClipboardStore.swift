import Foundation
import Compression

/// 只读解析用户 Core Spotlight 的 dbStr 映射和压缩元数据页，不修改系统索引。
/// 格式说明：https://github.com/libyal/dtformats/blob/main/documentation/Apple%20Spotlight%20store%20database%20file%20format.asciidoc
/// 这里只实现当前剪贴板所需的 v2 记录；未知格式明确报错，不写入或迁移系统数据。
nonisolated struct SpotlightClipboardRecord: Sendable {
    let identifier: String
    let title: String
    let text: String?
    let attachments: [String]
    let contentType: String
    let date: Date
}

nonisolated struct SpotlightClipboardStore {
    enum ReadError: Error { case unsupportedFormat, invalidData, cancelled }
    private struct Property { let name: String; let type: UInt8; let flags: UInt8 }
    private enum Value {
        case strings([String]), date(Date), number(UInt64), other
        var strings: [String] { if case .strings(let values) = self { values } else { [] } }
    }
    private struct Cursor {
        let data: Data
        var offset = 0
        var remaining: Int { data.count - offset }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw ReadError.invalidData }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }
        mutating func byte() throws -> UInt8 {
            guard remaining > 0 else { throw ReadError.invalidData }
            defer { offset += 1 }; return data[offset]
        }
        mutating func word() throws -> Int {
            let bytes = try take(4)
            return bytes.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        }
        mutating func integer() throws -> UInt64 {
            let first = try byte()
            let length = first.leadingZeroBitCount == 0 ? (~first).leadingZeroBitCount : 0
            var result: UInt64 = length > 4 ? 0 : UInt64(first & (0xff >> min(length, 8)))
            if length == 0 { return UInt64(first) }
            for _ in 0..<length { result = (result << 8) | UInt64(try byte()) }
            return result
        }
        mutating func size() throws -> Int {
            let n = try integer()
            guard n <= UInt64(Int.max) else { throw ReadError.invalidData }; return Int(n)
        }
        mutating func double() throws -> Double {
            let bytes = try take(8)
            let bits = bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
            return Double(bitPattern: bits)
        }
    }
    private var properties: [Int: Property] = [:]
    private var categories: [Int: String] = [:]
    private var lists: [Int: [Int]] = [:]
    private var localized: [Int: [Int]] = [:]

    private static func strings(_ data: Data) -> [String] {
        data.split(separator: 0).map { bytes in
            String(decoding: bytes, as: UTF8.self).components(separatedBy: "\u{16}\u{2}")[0]
        }
    }
    private static func word(_ data: Data, _ offset: Int) throws -> Int {
        var cursor = Cursor(data: data, offset: offset); return try cursor.word()
    }
    private static func map(_ directory: URL, number: Int) throws -> [Int: Data] {
        let prefix = directory.appendingPathComponent("dbStr-\(number).map")
        let header = try Data(contentsOf: URL(fileURLWithPath: prefix.path + ".header"))
        let offsets = try Data(contentsOf: URL(fileURLWithPath: prefix.path + ".offsets"))
        let data = try Data(contentsOf: URL(fileURLWithPath: prefix.path + ".data"))
        let count = try word(header, 28), used = try word(header, 20)
        guard count <= offsets.count / 4, used <= data.count else { throw ReadError.invalidData }
        var result: [Int: Data] = [:]
        for index in 1..<max(1, count) {
            let start = try word(offsets, index * 4)
            guard start > 1, start < used, start != 0xffffffff else { continue }
            // 条目本身带长度，不依赖下一槽（下一槽可能是已删除的洞）。
            var cursor = Cursor(data: data, offset: start)
            var size: Int
            if number >= 4 {
                var length = 0, shift = 0
                while true {
                    let byte = try cursor.byte()
                    guard shift < 56 else { throw ReadError.invalidData }
                    length |= Int(byte & 0x7f) << shift
                    if byte & 0x80 == 0 { break }; shift += 7
                }
                size = min(length, cursor.remaining)
            } else { size = try cursor.size() }
            guard size <= cursor.remaining else { continue }
            result[index] = try cursor.take(size)
        }
        return result
    }
    private mutating func loadMaps(_ directory: URL) throws {
        for (id, data) in try Self.map(directory, number: 1) {
            var cursor = Cursor(data: data)
            let type = try cursor.byte(), flags = try cursor.byte()
            properties[id] = Property(name: Self.strings(try cursor.take(cursor.remaining)).first ?? "", type: type, flags: flags)
        }
        categories = try Self.map(directory, number: 2).mapValues { Self.strings($0).first ?? "" }
        func indices(_ number: Int) throws -> [Int: [Int]] {
            try Self.map(directory, number: number).mapValues { data in
                var cursor = Cursor(data: data)
                let size = try cursor.size()
                _ = try cursor.take(number == 5 ? 1 : 0)
                var values: [Int] = []
                for _ in 0..<(size / 4) { values.append(try cursor.word()) }
                return values
            }
        }
        lists = try indices(4); localized = try indices(5)
    }
    private func value(_ property: Property, cursor: inout Cursor) throws -> Value {
        let multiple = property.flags & 2 != 0
        switch property.type {
        case 0, 2, 6: return .number(try cursor.integer())
        case 7:
            if multiple { _ = try cursor.take(cursor.size()); return .other }
            return .number(try cursor.integer())
        case 8, 9, 10, 12:
            let width = property.type == 8 ? 1 : (property.type == 9 ? 4 : 8)
            let size = try multiple ? cursor.size() : width
            if property.type == 12, size >= 8 {
                let date = try cursor.double()
                _ = try cursor.take(size - 8)
                return .date(Date(timeIntervalSinceReferenceDate: date))
            }
            _ = try cursor.take(size); return .other
        case 11: return .strings(Self.strings(try cursor.take(cursor.size())))
        case 14: _ = try cursor.take(cursor.size()); return .other
        case 15:
            let raw = try cursor.integer()
            guard raw <= UInt64(Int.max) else { return .other }
            let index = Int(raw)
            if property.flags & 3 == 3 { return .strings((localized[index] ?? []).compactMap { categories[$0] }) }
            if multiple { return .strings((lists[index] ?? []).compactMap { categories[$0] }) }
            return .strings(categories[index].map { [$0] } ?? [])
        default: throw ReadError.unsupportedFormat
        }
    }
    private func record(_ data: Data) throws -> SpotlightClipboardRecord? {
        var cursor = Cursor(data: data)
        _ = try cursor.integer(); _ = try cursor.byte()
        _ = try cursor.integer(); _ = try cursor.integer(); _ = try cursor.integer()
        var propertyID = 0
        var fields: [String: Value] = [:]
        while cursor.remaining > 0 {
            let delta = try cursor.size()
            guard delta > 0, propertyID <= Int.max - delta, let property = properties[propertyID + delta] else { throw ReadError.invalidData }
            propertyID += delta
            fields[property.name] = try value(property, cursor: &cursor)
        }
        guard fields["_kMDItemDomainIdentifier"]?.strings.first?.hasPrefix("com.apple.spotlight.pasteboard") == true,
              let identifier = fields["_kMDItemExternalID"]?.strings.first else { return nil }
        let date: Date
        if case .date(let value) = fields["kMDItemContentCreationDate"] { date = value } else { return nil }
        return SpotlightClipboardRecord(identifier: identifier, title: fields["kMDItemTitle"]?.strings.first ?? "",
                                        text: fields["kMDItemDescription"]?.strings.first,
                                        attachments: fields["kMDItemAttachmentPaths"]?.strings ?? [],
                                        contentType: fields["kMDItemContentType"]?.strings.first ?? "", date: date)
    }
    private static func decompress(_ data: Data, expected: Int) throws -> Data {
        guard !data.isEmpty, expected > 0, expected <= 32 * 1024 * 1024 else { throw ReadError.invalidData }
        var output = Data(count: expected)
        let count = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZ4)
            }
        }
        guard count > 0 else { throw ReadError.unsupportedFormat }
        output.count = count
        return output
    }
    mutating func read(directory: URL) throws -> [SpotlightClipboardRecord] {
        try loadMaps(directory)
        let url = directory.appendingPathComponent(".store.db")
        // 使用普通读取取得本轮快照；不 mmap 正在被系统更新的索引。
        let data = try Data(contentsOf: url)
        guard data.prefix(4) == Data("8tsd".utf8), try Self.word(data, 4) & 0x10000 != 0 else { throw ReadError.unsupportedFormat }
        let mapOffset = try Self.word(data, 36), pageSize = try Self.word(data, 44)
        let count = try Self.word(data, mapOffset + 8)
        guard pageSize >= 20, pageSize <= 1024 * 1024, count <= (data.count - mapOffset - 20) / 16 else { throw ReadError.invalidData }
        var results: [SpotlightClipboardRecord] = []
        for index in 0..<count {
            if Task<Never, Never>.isCancelled { throw ReadError.cancelled }
            let page = try Self.word(data, mapOffset + 20 + index * 16 + 8) * 4096
            let used = try Self.word(data, page + 8), flags = try Self.word(data, page + 12)
            let expected = try Self.word(data, page + 16) - 20
            guard flags & 0xff == 9, flags & 0x1000 != 0, used > 20, used <= pageSize, page <= data.count - used else { throw ReadError.unsupportedFormat }
            let payload = try Self.decompress(data.subdata(in: (page + 20)..<(page + used)), expected: expected)
            var cursor = Cursor(data: payload)
            while cursor.remaining >= 4 {
                let length = try cursor.word()
                let body = try cursor.take(length)
                // 不相关来源可能包含本版本未识别的属性；每条记录有长度，可安全跳过。
                if let item = try? record(body) { results.append(item) }
            }
        }
        return results
    }
}
