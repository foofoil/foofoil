import Foundation

/// ⌘P 输入直接命中的文件路径：去掉成对引号后确实存在，显示在结果首位并默认选中。
nonisolated struct DirectFilePath: Identifiable, Equatable, Sendable {
    let url: URL
    let isDirectory: Bool

    var id: String { "path:\(url.path)" }
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
    var symbolName: String {
        isDirectory ? "folder" : SpotlightFileResult(url: url, modifiedAt: .distantPast).symbolName
    }
}

/// 把用户输入解释为文件路径。只接受绝对路径、开头的 ~ 和 file URL，
/// 不用应用当前工作目录解析相对路径，避免打开与预期无关的文件。
nonisolated enum DirectFilePathResolver {
    static func resolve(_ raw: String) -> DirectFilePath? {
        guard let path = pathString(from: raw), path != "/" else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return DirectFilePath(url: URL(fileURLWithPath: path).standardizedFileURL,
                              isDirectory: isDirectory.boolValue)
    }

    /// 输入结构像路径时不再按搜索词处理，避免未命中的绝对路径被范围选择或网址识别接管。
    static func looksLikePath(_ raw: String) -> Bool {
        guard let path = pathString(from: raw), path != "/" else { return false }
        return path.dropFirst().contains("/")
    }

    /// 去掉成对引号与 shell 转义后的输入文本；路径与网址识别共用。
    static func normalizedText(from raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var wasQuoted = false
        while let unquoted = removingMatchingQuotes(text) {
            wasQuoted = true
            text = unquoted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
        }
        return wasQuoted ? text : unescapingShellEscapes(text)
    }

    /// 去掉成对引号与 shell 转义，并展开开头的 ~；file URL 转换为本地路径。
    static func pathString(from raw: String) -> String? {
        guard var text = normalizedText(from: raw) else { return nil }
        if text.lowercased().hasPrefix("file://") {
            guard let url = URL(string: text), url.isFileURL else { return nil }
            text = url.path
        }
        guard text.hasPrefix("/") || text.hasPrefix("~") else { return nil }
        let expanded = (text as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return expanded
    }

    private static let openingQuotes: Set<Character> = [
        "\"", "'", "`", "“", "‘", "「", "『", "《", "＂", "＇", "”", "’"
    ]
    private static let closingQuotes: Set<Character> = [
        "\"", "'", "`", "”", "’", "」", "』", "》", "＂", "＇", "“", "‘"
    ]

    private static func removingMatchingQuotes(_ text: String) -> String? {
        guard text.count >= 2, let first = text.first, let last = text.last,
              openingQuotes.contains(first), closingQuotes.contains(last) else { return nil }
        return String(text.dropFirst().dropLast())
    }

    /// 终端拖入的路径会把空格写成 `\ `；只处理常见的可转义字符，保留其他反斜杠。
    private static func unescapingShellEscapes(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = String()
        result.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            if next.isWhitespace || "\\\"'~()[]{}<>|&;*$`!? #".contains(next) {
                result.append(next)
            } else {
                result.append(character)
                result.append(next)
            }
        }
        return result
    }
}
