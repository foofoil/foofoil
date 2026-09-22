import Foundation

nonisolated enum SearchNGramEncoder {
    static func titleTerms(_ normalized: String) -> String {
        // 大文档下逐字符 String(format:) 会让一次历史保存多花一秒以上；
        // 这里直接在 UTF-8 缓冲区里写 16 进制 token，避免每个二元组都新建字符串。
        var bytes: [UInt8] = []
        bytes.reserveCapacity(normalized.utf8.count * 2 + 16)
        var hasTerm = false
        for character in normalized where !character.isWhitespace {
            if hasTerm { bytes.append(0x20) }
            hasTerm = true
            bytes.append(contentsOf: Self.titleUnigramTag)
            appendHex(of: character, to: &bytes)
        }
        var previous: Character?
        for character in normalized where !character.isWhitespace {
            if let last = previous {
                bytes.append(0x20)
                bytes.append(contentsOf: Self.titleBigramTag)
                appendHex(of: last, to: &bytes)
                appendHex(of: character, to: &bytes)
            }
            previous = character
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func bodyTerms(_ normalized: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(normalized.utf8.count * 2 + 16)
        var previous: Character?
        var hasTerm = false
        for character in normalized where !character.isWhitespace {
            if let last = previous {
                if hasTerm { bytes.append(0x20) }
                hasTerm = true
                bytes.append(contentsOf: Self.bodyBigramTag)
                appendHex(of: last, to: &bytes)
                appendHex(of: character, to: &bytes)
            }
            previous = character
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func matchExpression(for keyword: String) -> String? {
        let characters = Array(keyword.filter { !$0.isWhitespace })
        guard !characters.isEmpty else { return nil }
        if characters.count == 1 {
            return "title_terms:t1x\(hex(String(characters[0])))"
        }
        // detail=column 不支持短语查询；编码 token 不含分词符，可直接作为单 token 查询。
        let title = grams(characters).map { "title_terms:t2x\(hex($0))" }.joined(separator: " AND ")
        let body = grams(characters).map { "body_terms:b2x\(hex($0))" }.joined(separator: " AND ")
        return "(\(title)) OR (\(body))"
    }

    private static func grams(_ characters: [Character]) -> [String] {
        guard characters.count >= 2 else { return [] }
        return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
    }

    /// 单个字符按 UTF-8 字节写 16 进制；与 `String(character).utf8.map { String(format: "%02x", $0) }` 等价。
    @inline(__always)
    private static func appendHex(of character: Character, to bytes: inout [UInt8]) {
        for scalar in character.unicodeScalars {
            appendHex(of: scalar.value, to: &bytes)
        }
    }

    @inline(__always)
    private static func appendHex(of value: UInt32, to bytes: inout [UInt8]) {
        if value < 0x80 {
            appendHex(byte: UInt8(value), to: &bytes)
        } else if value < 0x800 {
            appendHex(byte: UInt8(0xC0 | (value >> 6)), to: &bytes)
            appendHex(byte: UInt8(0x80 | (value & 0x3F)), to: &bytes)
        } else if value < 0x10000 {
            appendHex(byte: UInt8(0xE0 | (value >> 12)), to: &bytes)
            appendHex(byte: UInt8(0x80 | ((value >> 6) & 0x3F)), to: &bytes)
            appendHex(byte: UInt8(0x80 | (value & 0x3F)), to: &bytes)
        } else {
            appendHex(byte: UInt8(0xF0 | (value >> 18)), to: &bytes)
            appendHex(byte: UInt8(0x80 | ((value >> 12) & 0x3F)), to: &bytes)
            appendHex(byte: UInt8(0x80 | ((value >> 6) & 0x3F)), to: &bytes)
            appendHex(byte: UInt8(0x80 | (value & 0x3F)), to: &bytes)
        }
    }

    @inline(__always)
    private static func appendHex(byte: UInt8, to bytes: inout [UInt8]) {
        bytes.append(hexDigits[Int(byte >> 4)])
        bytes.append(hexDigits[Int(byte & 0x0F)])
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
    private static let titleUnigramTag: [UInt8] = Array("t1x".utf8)
    private static let titleBigramTag: [UInt8] = Array("t2x".utf8)
    private static let bodyBigramTag: [UInt8] = Array("b2x".utf8)

    private static func hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }
}
