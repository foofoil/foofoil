import Foundation

nonisolated public struct ArchiveSource: Codable, Sendable, Equatable {
    struct Volume: Codable, Sendable, Equatable {
        var path: String
        var bookmark: Data?
    }
    var volumes: [Volume]
    var displayName: String? = nil
    var name: String { displayName ?? primaryURL.lastPathComponent }
    var primaryURL: URL { URL(fileURLWithPath: volumes[0].path) }
}

nonisolated struct ArchiveEntry: Identifiable, Sendable, Equatable {
    let id: String
    let ordinal: Int?
    let path: String
    let parentID: String?
    let isDirectory: Bool
    let size: Int64?
    let encrypted: Bool
    let isRegular: Bool
    var name: String { (path as NSString).lastPathComponent }
}

nonisolated struct ArchiveIndex: Sendable {
    let entries: [ArchiveEntry]
    let format: String
    let signatures: [String]
}

nonisolated enum ArchiveFailure: String, Error, LocalizedError {
    case originalDestination = "Archive Original Destination"
    case unsafePath = "Archive Unsafe Path"
    case limit = "Archive Resource Limit"
    case changed = "Archive Source Changed"
    case password = "Archive Password Required"
    case conflict = "Archive Export Conflict"
    case unsupportedVolumes = "Archive Unsupported Volumes"
    case unsupportedEncryption = "Archive Unsupported Encryption"
    case unsupported = "Archive Unsupported Entry"
    case unreadable = "Archive Read Failed"
    var errorDescription: String? { NSLocalizedString(rawValue, comment: "") }
}

/// 使用系统读取器；输出路径由宿主验证和创建，绝不调用 archive_write_disk。
nonisolated enum ArchiveReader {
    static let maximumEntries = 100_000
    static let maximumDepth = 128
    static let maximumExportBytes: Int64 = 20 * 1_024 * 1_024 * 1_024
    static let extensions: Set<String> = ["zip", "zipx", "tar", "tgz", "gz", "bz2", "xz", "tbz", "tbz2", "txz", "7z", "rar", "apk", "jar", "war", "ear", "cbz", "cbr", "cb7", "cbt", "kra", "iso"]

    // 文档的 ZIP 容器仅由“打开包内容”显式进入，不抢占原有阅读器。
    static let documentExtensions: Set<String> = [
        "epub", "docx", "docm", "dotx", "dotm", "xlsx", "xlsm", "xlsb", "xltx", "xltm",
        "pptx", "pptm", "potx", "potm", "ppsx", "ppsm", "odt", "ods", "odp", "odg", "ott", "ots", "otp", "otg"
    ]

    static func supportsPackageContents(_ url: URL) -> Bool {
        documentExtensions.contains(url.pathExtension.lowercased())
    }

    static func recognizes(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased()) || url.lastPathComponent.range(of: #"\.(7z\.\d{3}|r\d{2}|z\d{2})$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func safePath(_ raw: String) throws -> String {
        let value = raw.replacingOccurrences(of: "\\", with: "/")
        guard !value.hasPrefix("/"), !value.contains("\0"), value.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil else { throw ArchiveFailure.unsafePath }
        let parts = value.split(separator: "/").filter { $0 != "." }
        guard !parts.contains(".."), parts.count <= maximumDepth, value.utf8.count <= 4096 else { throw ArchiveFailure.unsafePath }
        return parts.joined(separator: "/")
    }

    static func signatures(_ urls: [URL]) throws -> [String] {
        try urls.map { url in
            // URL 可缓存文件属性；复用会话 URL 时仍须重新读取原包签名。
            var freshURL = url
            freshURL.removeAllCachedResourceValues()
            let values = try freshURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
            guard let size = values.fileSize, size <= 8 * 1_024 * 1_024 * 1_024 else { throw ArchiveFailure.limit }
            return "\(FileReference.canonicalPath(url))|\(size)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(String(describing: values.fileResourceIdentifier))"
        }
    }

    static func isRARVolume(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 128) else { return false }
        let bytes = Array(data)
        if bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00]), bytes.count > 11 { return bytes[10] & 1 != 0 }
        if bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00]) {
            var cursor = 12
            func integer() -> UInt64? {
                var result: UInt64 = 0
                for shift in stride(from: 0, to: 63, by: 7) {
                    guard cursor < bytes.count else { return nil }
                    let byte = bytes[cursor]
                    cursor += 1
                    result |= UInt64(byte & 0x7f) << shift
                    if byte & 0x80 == 0 { return result }
                }
                return nil
            }
            guard integer() != nil, integer() == 1, let flags = integer() else { return false }
            if flags & 1 != 0, integer() == nil { return false }
            if flags & 2 != 0, integer() == nil { return false }
            return integer().map { $0 & 1 != 0 } ?? false
        }
        return false
    }

    private static func rejectSplitZIP(_ urls: [URL]) throws {
        guard let url = urls.first, ["zip", "zipx"].contains(url.pathExtension.lowercased()) else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > 65_557 ? size - 65_557 : 0)
        let tail = try handle.readToEnd() ?? Data()
        if let range = tail.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards) {
            let offset = range.lowerBound
            if offset + 8 <= tail.count, tail[(offset + 4)..<(offset + 8)].contains(where: { $0 != 0 }) { throw ArchiveFailure.unsupportedVolumes }
        }
    }

    /// libarchive 某些 RAR 路径在缺少后续卷时会把当前完整条目当作 EOF；额外验证末卷标记，防止伪完整导出。
    private static func validateLastRARVolume(_ urls: [URL]) throws {
        guard let first = urls.first, isRARVolume(first), let last = urls.last else { return }
        let handle = try FileHandle(forReadingFrom: last)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: max(0, Int64(size) - 4_096).magnitude)
        let bytes = Array(try handle.readToEnd() ?? Data())
        guard bytes.count >= 7 else { throw ArchiveFailure.unreadable }
        func crc(_ range: Range<Int>) -> UInt32 {
            var result: UInt32 = 0xffff_ffff
            for byte in bytes[range] {
                result ^= UInt32(byte)
                for _ in 0..<8 { result = (result >> 1) ^ (result & 1 == 0 ? 0 : 0xedb8_8320) }
            }
            return ~result
        }
        func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
        func integer(_ cursor: inout Int) -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 63, by: 7) {
                guard cursor < bytes.count else { return nil }
                let byte = bytes[cursor]
                cursor += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
        for start in 0...(bytes.count - 7) {
            // RAR4 ENDARC：NEXT_VOLUME 为 bit 0，校验码为头部 CRC32 的低 16 位。
            if bytes[start + 2] == 0x7b {
                let length = Int(u16(start + 5))
                let end = start + length
                if length >= 7, end <= bytes.count, bytes[end...].allSatisfy({ $0 == 0 }),
                   UInt16(truncatingIfNeeded: crc((start + 2)..<end)) == u16(start) {
                    guard u16(start + 3) & 1 == 0 else { throw ArchiveFailure.unreadable }
                    return
                }
            }
            // RAR5 ENDARC：CRC32 覆盖 header-size vint 和头部，允许卷大小填充的尾部零字节。
            var cursor = start + 4
            guard let headerSize = integer(&cursor), headerSize <= 4_096 else { continue }
            let end = cursor + Int(headerSize)
            guard end <= bytes.count, integer(&cursor) == 5, let flags = integer(&cursor) else { continue }
            if flags & 1 != 0, integer(&cursor) == nil { continue }
            if flags & 2 != 0, integer(&cursor) == nil { continue }
            guard let endFlags = integer(&cursor), cursor <= end,
                  bytes[end...].allSatisfy({ $0 == 0 }), crc((start + 4)..<end) == u32(start) else { continue }
            guard endFlags & 1 == 0 else { throw ArchiveFailure.unreadable }
            return
        }
        throw ArchiveFailure.unreadable
    }

    private static func withReader<T>(urls: [URL], password: String?, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard !urls.isEmpty, let reader = archive_read_new() else { throw ArchiveFailure.unreadable }
        defer { archive_read_free(reader) }
        archive_read_support_filter_gzip(reader)
        archive_read_support_filter_bzip2(reader)
        archive_read_support_filter_xz(reader)
        archive_read_support_format_zip(reader)
        archive_read_support_format_tar(reader)
        archive_read_support_format_iso9660(reader)
        archive_read_support_format_7zip(reader)
        archive_read_support_format_rar(reader)
        archive_read_support_format_rar5(reader)
        if urls.count == 1, ["gz", "bz2", "xz"].contains(urls[0].pathExtension.lowercased()) { archive_read_support_format_raw(reader) }
        if let password, !password.isEmpty { password.withCString { _ = archive_read_add_passphrase(reader, $0) } }
        let names = urls.map { strdup($0.path) }
        defer { names.forEach { free($0) } }
        var pointers = names.map { $0.map { UnsafePointer($0) } } + [nil]
        let status = pointers.withUnsafeMutableBufferPointer { archive_read_open_filenames(reader, $0.baseAddress, 64 * 1_024) }
        guard status >= 0 else { throw error(reader) }
        return try body(reader)
    }

    private static func error(_ reader: OpaquePointer) -> Error {
        // 密码错误与数据损坏并非总能精确区分，不向用户伪造确定原因。
        let message = archive_error_string(reader).map { String(cString: $0).lowercased() } ?? ""
        if (message.contains("encrypt") || message.contains("crypto")),
           message.contains("not supported") || message.contains("unsupported") || message.contains("unavailable") {
            return ArchiveFailure.unsupportedEncryption
        }
        if message.contains("passphrase") || message.contains("password") || message.contains("encrypted") { return ArchiveFailure.password }
        return ArchiveFailure.unreadable
    }

    static func scan(urls: [URL], password: String? = nil) throws -> ArchiveIndex {
        try rejectSplitZIP(urls)
        let signature = try signatures(urls)
        try validateLastRARVolume(urls)
        return try withReader(urls: urls, password: password) { reader in
            var entries = [ArchiveEntry(id: "root", ordinal: nil, path: "", parentID: nil, isDirectory: true, size: nil, encrypted: false, isRegular: false)]
            var directories = ["": "root"]
            var directoryPositions = ["root": 0]
            var ordinal = 0
            var metadataBytes = 0
            var accountedEntries = 0
            let deadline = Date().addingTimeInterval(120)
            while true {
                try Task.checkCancellation()
                for entry in entries[accountedEntries...] { metadataBytes += entry.path.utf8.count }
                accountedEntries = entries.count
                guard Date() < deadline, entries.count <= maximumEntries, metadataBytes <= 32 * 1_024 * 1_024 else { throw ArchiveFailure.limit }
                var header: OpaquePointer?
                let status = archive_read_next_header(reader, &header)
                if status == 1 { break }
                guard status >= -20, let header else { throw error(reader) }
                let pointer = archive_entry_pathname_utf8(header) ?? archive_entry_pathname(header)
                guard let pointer, let raw = String(validatingCString: pointer) else { throw ArchiveFailure.unreadable }
                var path = try safePath(raw)
                if path == "data", let source = urls.first, ["gz", "bz2", "xz"].contains(source.pathExtension.lowercased()), archive_format_name(reader).map({ String(cString: $0).lowercased().contains("raw") }) == true { path = source.deletingPathExtension().lastPathComponent }
                let type = archive_entry_filetype(header)
                let directory = type == 0o040000
                if !path.isEmpty {
                    let components = path.split(separator: "/")
                    var prefix = ""
                    var parent = "root"
                    for component in components.dropLast() {
                        prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                        if let id = directories[prefix] { parent = id }
                        else {
                            let id = "implicit:\(entries.count)"
                            directoryPositions[id] = entries.count
                            entries.append(ArchiveEntry(id: id, ordinal: nil, path: prefix, parentID: parent, isDirectory: true, size: nil, encrypted: false, isRegular: false))
                            directories[prefix] = id
                            parent = id
                        }
                    }
                    if directory, let id = directories[path], let position = directoryPositions[id], entries[position].ordinal == nil {
                        entries[position] = ArchiveEntry(id: id, ordinal: ordinal, path: path, parentID: parent, isDirectory: true, size: nil, encrypted: false, isRegular: false)
                    } else {
                        let id = "entry:\(ordinal)"
                        if directory { directoryPositions[id] = entries.count }
                        entries.append(ArchiveEntry(id: id, ordinal: ordinal, path: path, parentID: parent, isDirectory: directory, size: archive_entry_size_is_set(header) != 0 ? archive_entry_size(header) : nil, encrypted: archive_entry_is_encrypted(header) > 0, isRegular: type == 0o100000 && archive_entry_hardlink(header) == nil))
                        if directory { directories[path] = id }
                    }
                }
                ordinal += 1
                guard archive_read_data_skip(reader) >= -20 else { throw error(reader) }
            }
            guard signature == (try signatures(urls)) else { throw ArchiveFailure.changed }
            return ArchiveIndex(entries: entries, format: archive_format_name(reader).map { String(cString: $0) } ?? "", signatures: signature)
        }
    }

    /// 一次顺序扫描提取到私有暂存目录；调用者只在完整成功后提交输出。
    static func extract(urls: [URL], index: ArchiveIndex, entries: [ArchiveEntry], root: URL, basePath: String, password: String?, limit: Int64, progress: @Sendable (Int64) -> Void = { _ in }) throws -> Int {
        guard (try? signatures(urls)) == index.signatures else { throw ArchiveFailure.changed }
        if index.format.hasPrefix("RAR"), entries.contains(where: { $0.encrypted }) { throw ArchiveFailure.unsupportedEncryption }
        var paths = Set<String>()
        var targets: [Int: URL] = [:]
        var skipped = 0
        let fm = FileManager.default
        for entry in entries {
            try Task.checkCancellation()
            if !entry.isDirectory && !entry.isRegular { skipped += 1; continue }
            let relative = basePath.isEmpty ? entry.path : String(entry.path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let safe = try safePath(relative)
            if safe.isEmpty { continue }
            // 导出对大小写和 Unicode 规范等价碰撞统一报错，不覆盖任何现有条目。
            guard paths.insert(safe.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))).inserted else { throw ArchiveFailure.conflict }
            let target = root.appendingPathComponent(safe)
            if entry.isDirectory { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
            else if let ordinal = entry.ordinal { targets[ordinal] = target }
        }
        var total: Int64 = 0
        var work: Int64 = 0
        var lastProgress = Date.distantPast
        let deadline = Date().addingTimeInterval(limit <= 512 * 1_024 * 1_024 ? 60 : 300)
        try withReader(urls: urls, password: password) { reader in
            var ordinal = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while !targets.isEmpty {
                try Task.checkCancellation()
                guard Date() < deadline else { throw ArchiveFailure.limit }
                var header: OpaquePointer?
                let status = archive_read_next_header(reader, &header)
                guard status != 1, status >= -20, let header else { throw error(reader) }
                if archive_entry_size_is_set(header) != 0 {
                    let size = archive_entry_size(header)
                    guard size >= 0, size <= maximumExportBytes - work else { throw ArchiveFailure.limit }
                    work += size
                    guard work <= min(maximumExportBytes, max(limit * 4, 512 * 1_024 * 1_024)) else { throw ArchiveFailure.limit }
                }
                defer { ordinal += 1 }
                guard let target = targets.removeValue(forKey: ordinal) else {
                    guard archive_read_data_skip(reader) >= -20 else { throw error(reader) }
                    continue
                }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard !fm.fileExists(atPath: target.path) else { throw ArchiveFailure.conflict }
                guard fm.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                var entryBytes: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    guard Date() < deadline else { throw ArchiveFailure.limit }
                    let count = archive_read_data(reader, &buffer, buffer.count)
                    guard count >= 0 else { throw error(reader) }
                    if count == 0 { break }
                    total += Int64(count)
                    entryBytes += Int64(count)
                    guard total <= limit else { throw ArchiveFailure.limit }
                    try output.write(contentsOf: Data(buffer.prefix(count)))
                    if Date().timeIntervalSince(lastProgress) >= 0.15 {
                        progress(total)
                        lastProgress = Date()
                    }
                }
                if archive_entry_size_is_set(header) != 0, entryBytes != archive_entry_size(header) { throw ArchiveFailure.unreadable }
                try output.synchronize()
            }
        }
        guard (try? signatures(urls)) == index.signatures else { throw ArchiveFailure.changed }
        progress(total)
        return skipped
    }
}
