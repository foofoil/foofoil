import Foundation

/// 只识别官方内容链接；专辑链接中的 i 参数优先指向单曲。
nonisolated struct AppleMusicLink: Equatable, Sendable {
    let url: URL
    let kind: AppleMusicReference.Kind
    let id: String

    init?(url: URL) {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "music.apple.com",
              url.user == nil, url.password == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var path = url.pathComponents.filter { $0 != "/" }
        if let first = path.first, first.count == 2 { path.removeFirst() }
        guard path.count == 2 || path.count == 3,
              let resource = path.first, let resourceID = path.last else { return nil }
        let kind: AppleMusicReference.Kind
        let id: String
        switch resource {
        case "album":
            guard Self.isNumericID(resourceID) else { return nil }
            if let songID = components.queryItems?.first(where: { $0.name == "i" }) {
                guard let value = songID.value, Self.isNumericID(value) else { return nil }
                kind = .song; id = value
            } else { kind = .album; id = resourceID }
        case "song":
            guard Self.isNumericID(resourceID) else { return nil }
            kind = .song; id = resourceID
        case "playlist":
            guard resourceID.hasPrefix("pl."), resourceID.count > 3,
                  resourceID.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0) }) else { return nil }
            kind = .playlist; id = resourceID
        default: return nil
        }
        self.url = url; self.kind = kind; self.id = id
    }

    private static func isNumericID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }
}

enum CatalogLinkError: LocalizedError {
    case unavailable
    var errorDescription: String? { NSLocalizedString("Music Link Unavailable", comment: "") }
}
