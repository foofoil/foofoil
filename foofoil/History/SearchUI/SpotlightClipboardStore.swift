import Foundation
import Compression
import CryptoKit

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
        // NSData 持有稳定的只读字节；子游标共享所有者，避免每个字段经过 Data 下标桥接或分配。
        private let owner: NSData
        private let bytes: UnsafeRawPointer
        var offset: Int
        private let end: Int
        init(data: Data, offset: Int = 0, end: Int? = nil) {
            owner = data as NSData
            bytes = owner.bytes
            self.offset = offset
            self.end = end ?? owner.length
        }
        private init(owner: NSData, bytes: UnsafeRawPointer, offset: Int, end: Int) {
            self.owner = owner; self.bytes = bytes; self.offset = offset; self.end = end
        }
        var remaining: Int { end - offset }
        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= remaining else { throw ReadError.invalidData }
            offset += count
        }
        mutating func segment(_ count: Int) throws -> Cursor {
            let start = offset
            try skip(count)
            return Cursor(owner: owner, bytes: bytes, offset: start, end: offset)
        }
        mutating func take(_ count: Int) throws -> Data {
            let start = offset
            try skip(count)
            return owner.subdata(with: NSRange(location: start, length: count))
        }
        mutating func byte() throws -> UInt8 {
            guard remaining > 0 else { throw ReadError.invalidData }
            defer { offset += 1 }
            return withExtendedLifetime(owner) { bytes.load(fromByteOffset: offset, as: UInt8.self) }
        }
        mutating func word() throws -> Int {
            guard remaining >= 4 else { throw ReadError.invalidData }
            let result = withExtendedLifetime(owner) { Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
            offset += 4
            return result
        }
        mutating func integer() throws -> UInt64 {
            try withExtendedLifetime(owner) {
                guard remaining > 0 else { throw ReadError.invalidData }
                let first = bytes.load(fromByteOffset: offset, as: UInt8.self)
                let length = first.leadingZeroBitCount == 0 ? (~first).leadingZeroBitCount : 0
                guard remaining > length else { throw ReadError.invalidData }
                offset += 1
                var result: UInt64 = length > 4 ? 0 : UInt64(first & (0xff >> min(length, 8)))
                if length == 0 { return UInt64(first) }
                for _ in 0..<length {
                    result = (result << 8) | UInt64(bytes.load(fromByteOffset: offset, as: UInt8.self))
                    offset += 1
                }
                return result
            }
        }
        mutating func size() throws -> Int {
            let n = try integer()
            guard n <= UInt64(Int.max) else { throw ReadError.invalidData }; return Int(n)
        }
        mutating func double() throws -> Double {
            guard remaining >= 8 else { throw ReadError.invalidData }
            let bits = withExtendedLifetime(owner) { UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
            offset += 8
            return Double(bitPattern: bits)
        }
    }
    private var properties: [Int: Property] = [:]
    private var categories: MapTable?
    private var lists: MapTable?
    private var localized: MapTable?
    private var categoryCache: [Int: String] = [:]

    /// 保留映射表的原始快照，只有命中的引用才解码，避免展开数万个无关字符串和列表。
    private struct MapTable: Equatable {
        let number: Int
        let data: Data
        let offsets: Data
        let count: Int
        let used: Int
        init(directory: URL, number: Int) throws {
            self.number = number
            let prefix = directory.appendingPathComponent("dbStr-\(number).map").path
            let header = try Data(contentsOf: URL(fileURLWithPath: prefix + ".header"))
            offsets = try Data(contentsOf: URL(fileURLWithPath: prefix + ".offsets"))
            data = try Data(contentsOf: URL(fileURLWithPath: prefix + ".data"))
            count = try SpotlightClipboardStore.word(header, 28)
            used = try SpotlightClipboardStore.word(header, 20)
            guard count <= offsets.count / 4, used <= data.count else { throw ReadError.invalidData }
        }
        func entry(_ index: Int) throws -> Cursor? {
            guard index > 0, index < count else { return nil }
            let start = try SpotlightClipboardStore.word(offsets, index * 4)
            guard start > 1, start < used, start != 0xffffffff else { return nil }
            var cursor = Cursor(data: data, offset: start)
            let size: Int
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
            guard size <= cursor.remaining else { return nil }
            return try cursor.segment(size)
        }
    }
    private static func strings(_ data: Data) -> [String] {
        data.split(separator: 0).map { bytes in
            String(decoding: bytes, as: UTF8.self).components(separatedBy: "\u{16}\u{2}")[0]
        }
    }
    private static func word(_ data: Data, _ offset: Int) throws -> Int {
        var cursor = Cursor(data: data, offset: offset); return try cursor.word()
    }
    private struct CachedPage {
        let digest: SHA256.Digest
        let records: [SpotlightClipboardRecord]
    }
    private var cachedPages: [Int: CachedPage] = [:]
    private var cachedDirectory: URL?
    private(set) var decodedPageCount = 0
    private var loadedTables: [MapTable] = []
    private mutating func loadMaps(_ directory: URL) throws {
        let tables = try [1, 2, 4, 5].map { try MapTable(directory: directory, number: $0) }
        guard tables != loadedTables else { return }
        var definitions: [Int: Property] = [:]
        for id in 1..<max(1, tables[0].count) {
            guard var cursor = try tables[0].entry(id) else { continue }
            let type = try cursor.byte(), flags = try cursor.byte()
            definitions[id] = Property(name: Self.strings(try cursor.take(cursor.remaining)).first ?? "", type: type, flags: flags)
        }
        properties = definitions
        // 引用表有变化时旧页结果失效；只改变索引页时仍可逐页复用。
        cachedPages = [:]
        categories = tables[1]; lists = tables[2]; localized = tables[3]
        categoryCache = [:]
        loadedTables = tables
    }
    private mutating func category(_ index: Int) throws -> String? {
        if let value = categoryCache[index] { return value }
        guard var entry = try categories?.entry(index) else { return nil }
        let value = Self.strings(try entry.take(entry.remaining)).first ?? ""
        categoryCache[index] = value
        return value
    }
    private mutating func referencedStrings(_ index: Int, localized: Bool) throws -> [String] {
        guard var entry = try (localized ? self.localized : lists)?.entry(index) else { return [] }
        let size = try entry.size()
        try entry.skip(localized ? 1 : 0)
        var values: [String] = []
        for _ in 0..<(size / 4) {
            let id = try entry.word()
            if let text = try category(id) { values.append(text) }
        }
        return values
    }
    private mutating func value(_ property: Property, cursor: inout Cursor) throws -> Value {
        let multiple = property.flags & 2 != 0
        switch property.type {
        case 0, 2, 6: return .number(try cursor.integer())
        case 7:
            if multiple { try cursor.skip(cursor.size()); return .other }
            return .number(try cursor.integer())
        case 8, 9, 10, 12:
            let width = property.type == 8 ? 1 : (property.type == 9 ? 4 : 8)
            let size = try multiple ? cursor.size() : width
            if property.type == 12, size >= 8 {
                let date = try cursor.double()
                try cursor.skip(size - 8)
                return .date(Date(timeIntervalSinceReferenceDate: date))
            }
            try cursor.skip(size); return .other
        case 11: return .strings(Self.strings(try cursor.take(cursor.size())))
        case 14: try cursor.skip(cursor.size()); return .other
        case 15:
            let raw = try cursor.integer()
            guard raw <= UInt64(Int.max) else { return .other }
            let index = Int(raw)
            if property.flags & 3 == 3 { return .strings(try referencedStrings(index, localized: true)) }
            if multiple { return .strings(try referencedStrings(index, localized: false)) }
            return .strings(try category(index).map { [$0] } ?? [])
        default: throw ReadError.unsupportedFormat
        }
    }
    /// 首遍只定位 domain，其余属性按长度跳过，避免为数万条无关记录构造正文与字典。
    private func skipValue(_ property: Property, cursor: inout Cursor) throws {
        switch property.type {
        case 0, 2, 6, 15: _ = try cursor.integer()
        case 7:
            if property.flags & 2 != 0 { try cursor.skip(cursor.size()) } else { _ = try cursor.integer() }
        case 8, 9, 10, 12:
            let width = property.type == 8 ? 1 : (property.type == 9 ? 4 : 8)
            try cursor.skip(property.flags & 2 != 0 ? cursor.size() : width)
        case 11, 14: try cursor.skip(cursor.size())
        default: throw ReadError.unsupportedFormat
        }
    }
    private mutating func record(_ body: Cursor) throws -> SpotlightClipboardRecord? {
        var cursor = body
        _ = try cursor.integer(); _ = try cursor.byte()
        _ = try cursor.integer(); _ = try cursor.integer(); _ = try cursor.integer()
        let attributes = cursor
        var propertyID = 0
        var isClipboard = false
        while cursor.remaining > 0 {
            let delta = try cursor.size()
            guard delta > 0, propertyID <= Int.max - delta, let property = properties[propertyID + delta] else { throw ReadError.invalidData }
            propertyID += delta
            if property.name == "_kMDItemDomainIdentifier" {
                isClipboard = try value(property, cursor: &cursor).strings.first?.hasPrefix("com.apple.spotlight.pasteboard") == true
                break
            }
            try skipValue(property, cursor: &cursor)
        }
        guard isClipboard else { return nil }
        cursor = attributes
        propertyID = 0
        var fields: [String: Value] = [:]
        let needed: Set<String> = ["_kMDItemExternalID", "kMDItemTitle", "kMDItemDescription", "kMDItemAttachmentPaths", "kMDItemContentType", "kMDItemContentCreationDate"]
        while cursor.remaining > 0 {
            let delta = try cursor.size()
            guard delta > 0, propertyID <= Int.max - delta, let property = properties[propertyID + delta] else { throw ReadError.invalidData }
            propertyID += delta
            if needed.contains(property.name) { fields[property.name] = try value(property, cursor: &cursor) }
            else { try skipValue(property, cursor: &cursor) }
        }
        guard let identifier = fields["_kMDItemExternalID"]?.strings.first else { return nil }
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
        if cachedDirectory != directory {
            cachedPages = [:]; loadedTables = []; cachedDirectory = directory
        }
        try loadMaps(directory)
        decodedPageCount = 0
        let url = directory.appendingPathComponent(".store.db")
        // 使用普通读取取得本轮快照；不 mmap 正在被系统更新的索引。
        let data = try Data(contentsOf: url)
        guard data.prefix(4) == Data("8tsd".utf8), try Self.word(data, 4) & 0x10000 != 0 else { throw ReadError.unsupportedFormat }
        let mapOffset = try Self.word(data, 36), pageSize = try Self.word(data, 44)
        let count = try Self.word(data, mapOffset + 8)
        guard pageSize >= 20, pageSize <= 1024 * 1024, count <= (data.count - mapOffset - 20) / 16 else { throw ReadError.invalidData }
        var results: [SpotlightClipboardRecord] = []
        var nextPages: [Int: CachedPage] = [:]
        for index in 0..<count {
            if Task<Never, Never>.isCancelled { throw ReadError.cancelled }
            let page = try Self.word(data, mapOffset + 20 + index * 16 + 8) * 4096
            let used = try Self.word(data, page + 8), flags = try Self.word(data, page + 12)
            let expected = try Self.word(data, page + 16) - 20
            guard flags & 0xff == 9, flags & 0x1000 != 0, used > 20, used <= pageSize, page <= data.count - used else { throw ReadError.unsupportedFormat }
            let digest = SHA256.hash(data: data.subdata(in: page..<(page + used)))
            if let cached = cachedPages[page], cached.digest == digest {
                results.append(contentsOf: cached.records); nextPages[page] = cached
                continue
            }
            decodedPageCount += 1
            let payload = try Self.decompress(data.subdata(in: (page + 20)..<(page + used)), expected: expected)
            var pageRecords: [SpotlightClipboardRecord] = []
            var cursor = Cursor(data: payload)
            while cursor.remaining >= 4 {
                let length = try cursor.word()
                let body = try cursor.segment(length)
                // 不相关来源可能包含本版本未识别的属性；每条记录有长度，可安全跳过。
                if let item = try? record(body) { pageRecords.append(item) }
            }
            results.append(contentsOf: pageRecords)
            nextPages[page] = CachedPage(digest: digest, records: pageRecords)
        }
        // 仅保留当前 map 中的页，删除/重排不会留下上一轮的历史条目。
        cachedPages = nextPages
        return results
    }
}
