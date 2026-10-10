import Foundation

/// 分享扩展与主应用只传递内容，不依赖剪贴板，也不接受任意自定义协议。
nonisolated enum SharedContentLink: Equatable {
    case text(String)
    case website(URL)

    static let maximumTextBytes = 1_048_576

    var url: URL? {
        var components = URLComponents()
        components.scheme = "foofoil"
        components.host = "share"
        switch self {
        case .text(let text):
            guard !text.isEmpty, text.utf8.count <= Self.maximumTextBytes else { return nil }
            components.queryItems = [.init(name: "text", value: text)]
        case .website(let url):
            guard Self.isWebsite(url) else { return nil }
            components.queryItems = [.init(name: "url", value: url.absoluteString)]
        }
        return components.url
    }

    init?(url: URL) {
        guard url.scheme == "foofoil", url.host == "share",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.count == 1,
              let value = items.first?.value else { return nil }
        switch items.first?.name {
        case "text":
            guard !value.isEmpty, value.utf8.count <= Self.maximumTextBytes else { return nil }
            self = .text(value)
        case "url":
            guard let website = URL(string: value), Self.isWebsite(website) else { return nil }
            self = .website(website)
        default: return nil
        }
    }

    private static func isWebsite(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }
}

/// 来源应用的临时导出必须在 item-provider 回调结束前复制；主应用再保存自己的持久副本。
nonisolated enum ShareStaging {
    static let directoryName = "FoofoilShareInbox"

    static func isStaged(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let parent = url.deletingLastPathComponent()
        return UUID(uuidString: parent.lastPathComponent) != nil
            && parent.deletingLastPathComponent().lastPathComponent == directoryName
    }

    static func copy(_ source: URL, named name: String? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let proposed = name.map { URL(fileURLWithPath: $0).lastPathComponent } ?? source.lastPathComponent
        let safeName = proposed.isEmpty || proposed == "." || proposed == ".." ? source.lastPathComponent : proposed
        let destination = directory.appendingPathComponent(safeName)
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return destination
    }
}
