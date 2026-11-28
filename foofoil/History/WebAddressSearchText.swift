import Foundation

/// 网页地址的搜索文本：只保留主机名与路径，忽略协议、端口、查询参数和片段。
/// 历史索引与即时过滤共用同一规则，避免搜索 “https” 或参数值命中无关网页记录。
nonisolated enum WebAddressSearchText {
    static func make(from raw: String) -> String? {
        guard let url = URL(string: raw) else { return nil }
        if let host = url.host, !host.isEmpty {
            let path = url.path
            return host + (path.isEmpty ? "/" : path)
        }
        // 本地 HTML 等 file URL 没有主机名，路径本身仍是可搜索的地址。
        guard url.isFileURL, !url.path.isEmpty else { return nil }
        return url.path
    }

    static func matches(_ raw: String, query: String) -> Bool {
        guard let text = make(from: raw) else { return false }
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
