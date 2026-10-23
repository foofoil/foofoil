import Foundation

/// 搜索输入里可直接打开的目标：存在的文件/文件夹，或可识别的网址。
nonisolated enum DirectSearchAction: Equatable, Sendable, Identifiable {
    case file(DirectFilePath)
    case url(URL)

    var id: String {
        switch self {
        case .file(let file): file.id
        case .url(let url): "url:\(url.absoluteString)"
        }
    }

    /// 存在的文件路径优先；结构像路径但不存在时不再退化成网址。
    static func resolve(_ raw: String) -> DirectSearchAction? {
        if let file = DirectFilePathResolver.resolve(raw) { return .file(file) }
        guard !DirectFilePathResolver.looksLikePath(raw) else { return nil }
        guard let url = DirectURLResolver.url(from: raw) else { return nil }
        return .url(url)
    }
}

/// 识别网址输入：完整的 http(s) 地址，或含点 / localhost 的主机名。
nonisolated enum DirectURLResolver {
    static func url(from raw: String) -> URL? {
        guard let input = DirectFilePathResolver.normalizedText(from: raw),
              !input.contains(where: \.isWhitespace) else { return nil }
        let candidate: String
        if input.lowercased().hasPrefix("http://") || input.lowercased().hasPrefix("https://") {
            candidate = input
        } else if input == "localhost" || input.contains(".") {
            candidate = "https://\(input)"
        } else {
            return nil
        }
        guard let url = URL(string: candidate), let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
