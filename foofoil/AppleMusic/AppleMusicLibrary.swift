import Foundation
import MusicKit
import Combine

/// 历史保存来源、MusicKit 身份和展示元数据；重新打开时按来源查询当前条目。
nonisolated public struct AppleMusicReference: Codable, Sendable, Equatable {
    public static let symbolName = "music.pages.fill"
    public enum Kind: String, Codable, Sendable { case song, album, playlist }
    public enum Source: String, Codable, Sendable { case library, catalog }
    public let kind: Kind
    public let id: String
    public let title: String
    public let subtitle: String
    public var source: Source? = nil
    public var sourceFingerprint: String {
        source == .catalog ? "apple-music:catalog:\(kind.rawValue):\(id)" : "apple-music:\(kind.rawValue):\(id)"
    }
}

/// 搜索按专辑、歌曲、歌单分组；两种搜索入口共用显示顺序和折叠数量。
enum AppleMusicSearchCategory: CaseIterable, Identifiable, Hashable {
    case albums, songs, playlists
    var id: Self { self }
    var localizationKey: String {
        switch self {
        case .albums: "Music Albums"
        case .songs: "Music Songs"
        case .playlists: "Music Playlists"
        }
    }
    var symbolName: String {
        switch self {
        case .albums: "square.stack"
        case .songs: "music.note"
        case .playlists: "music.note.list"
        }
    }
    var moreLocalizationKey: String {
        switch self {
        case .albums: "Music More Albums"
        case .songs: "Music More Songs"
        case .playlists: "Music More Playlists"
        }
    }
}

struct AppleMusicSearchPage {
    let items: [AppleMusicLibraryItem]
    var hasMoreCategories: Set<AppleMusicSearchCategory> = []
}

/// 音乐条目保留 MusicKit 身份和来源，不转换成文件路径或伪造下载地址。
struct AppleMusicLibraryItem: Identifiable, Sendable {
    enum Content: Sendable {
        case song(Song)
        case album(Album)
        case playlist(Playlist)
    }
    let content: Content
    var source: AppleMusicReference.Source = .library
    static func song(_ item: Song) -> Self { .init(content: .song(item)) }
    static func album(_ item: Album) -> Self { .init(content: .album(item)) }
    static func playlist(_ item: Playlist) -> Self { .init(content: .playlist(item)) }

    var reference: AppleMusicReference {
        switch content {
        case .song(let item): .init(kind: .song, id: item.id.rawValue, title: title, subtitle: subtitle, source: source == .catalog ? .catalog : nil)
        case .album(let item): .init(kind: .album, id: item.id.rawValue, title: title, subtitle: subtitle, source: source == .catalog ? .catalog : nil)
        case .playlist(let item): .init(kind: .playlist, id: item.id.rawValue, title: title, subtitle: subtitle, source: source == .catalog ? .catalog : nil)
        }
    }
    var id: String {
        switch content {
        case .song(let item): "song:\(item.id)"
        case .album(let item): "album:\(item.id)"
        case .playlist(let item): "playlist:\(item.id)"
        }
    }
    var title: String {
        switch content {
        case .song(let item): item.title
        case .album(let item): item.title
        case .playlist(let item): item.name
        }
    }
    var displayTitle: String {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return title }
        let key: String
        switch content {
        case .album: key = "Music Untitled Album"
        case .song: key = "Music Untitled Song"
        case .playlist: key = "Music Untitled Playlist"
        }
        return NSLocalizedString(key, comment: "")
    }
    var subtitle: String {
        switch content {
        case .song(let item): item.artistName
        case .album(let item): item.artistName
        case .playlist(let item): item.curatorName ?? ""
        }
    }
    var artwork: Artwork? {
        switch content {
        case .song(let item): item.artwork
        case .album(let item): item.artwork
        case .playlist(let item): item.artwork
        }
    }
    var typeKey: String {
        switch content {
        case .song: "Music Songs"
        case .album: "Music Albums"
        case .playlist: "Music Playlists"
        }
    }
    var searchCategory: AppleMusicSearchCategory {
        switch content {
        case .album: .albums
        case .song: .songs
        case .playlist: .playlists
        }
    }
    var searchSubtitle: String {
        if case .song(let song) = content {
            return [song.artistName, song.albumTitle ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return subtitle
    }
}

@MainActor
final class AppleMusicLibrary: ObservableObject {
    static let shared = AppleMusicLibrary()
    @Published private(set) var authorization = MusicAuthorization.currentStatus {
        didSet {
            if authorization != oldValue {
                NotificationCenter.default.post(name: .appleMusicSearchDidChange, object: nil)
            }
        }
    }
    var isAuthorized: Bool { authorization == .authorized }

    func refreshAuthorization() { authorization = MusicAuthorization.currentStatus }

    func authorize() async {
        authorization = await MusicAuthorization.request()
    }

    func search(_ term: String) async throws -> [AppleMusicLibraryItem] {
        try await searchPage(term, filter: .all).items
    }

    /// 资料库窗口只向 MusicKit 请求当前分类；快速打开仍保留跨分类搜索。
    func search(_ term: String, category: String) async throws -> [AppleMusicLibraryItem] {
        guard isAuthorized else { return [] }
        let types: [any MusicLibrarySearchable.Type]
        switch category {
        case "Music Songs": types = [Song.self]
        case "Music Playlists": types = [Playlist.self]
        default: types = [Album.self]
        }
        var request = MusicLibrarySearchRequest(term: term, types: types)
        request.limit = 60
        let response = try await request.response()
        try Task.checkCancellation()
        switch category {
        case "Music Songs": return response.songs.map(AppleMusicLibraryItem.song)
        case "Music Playlists": return response.playlists.map(AppleMusicLibraryItem.playlist)
        default: return response.albums.map(AppleMusicLibraryItem.album)
        }
    }

    func searchPage(_ term: String, filter: SearchResultFilter) async throws -> AppleMusicSearchPage {
        guard isAuthorized, filter != .files else { return .init(items: []) }
        let types: [any MusicLibrarySearchable.Type]
        switch filter {
        case .albums: types = [Album.self]
        case .songs: types = [Song.self]
        default: types = [Album.self, Song.self, Playlist.self]
        }
        var request = MusicLibrarySearchRequest(term: term, types: types)
        request.limit = SearchResultLimits.probe
        let response = try await request.response()
        try Task.checkCancellation()
        var more: Set<AppleMusicSearchCategory> = []
        if response.albums.hasNextBatch { more.insert(.albums) }
        if response.songs.hasNextBatch { more.insert(.songs) }
        if response.playlists.hasNextBatch { more.insert(.playlists) }
        return .init(items: response.albums.prefix(SearchResultLimits.probe).map(AppleMusicLibraryItem.album)
            + response.songs.prefix(SearchResultLimits.probe).map(AppleMusicLibraryItem.song)
            + response.playlists.prefix(SearchResultLimits.probe).map(AppleMusicLibraryItem.playlist), hasMoreCategories: more)
    }

    func browse(_ category: String, offset: Int) async throws -> [AppleMusicLibraryItem] {
        guard isAuthorized else { return [] }
        switch category {
        case "Music Songs":
            var request = MusicLibraryRequest<Song>()
            request.limit = 60; request.offset = offset
            request.sort(by: \.title, ascending: true)
            return try await request.response().items.map(AppleMusicLibraryItem.song)
        case "Music Playlists":
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 60; request.offset = offset
            request.sort(by: \.name, ascending: true)
            return try await request.response().items.map(AppleMusicLibraryItem.playlist)
        default:
            var request = MusicLibraryRequest<Album>()
            request.limit = 60; request.offset = offset
            request.sort(by: \.title, ascending: true)
            return try await request.response().items.map(AppleMusicLibraryItem.album)
        }
    }

    func resolve(_ reference: AppleMusicReference) async throws -> AppleMusicLibraryItem {
        refreshAuthorization()
        guard isAuthorized else { throw LibraryRestoreError.authorizationRequired }
        if reference.source == .catalog { return try await resolveCatalog(kind: reference.kind, id: reference.id) }
        let id = MusicItemID(reference.id)
        switch reference.kind {
        case .song:
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: id)
            if let item = try await request.response().items.first { return .song(item) }
        case .album:
            var request = MusicLibraryRequest<Album>()
            request.filter(matching: \.id, equalTo: id)
            if let item = try await request.response().items.first { return .album(item) }
        case .playlist:
            var request = MusicLibraryRequest<Playlist>()
            request.filter(matching: \.id, equalTo: id)
            if let item = try await request.response().items.first { return .playlist(item) }
        }
        throw LibraryRestoreError.itemMissing
    }

    /// 分享链接按目录身份查询；不能用目录 ID 查询用户资料库。
    func resolve(_ link: AppleMusicLink) async throws -> AppleMusicLibraryItem {
        refreshAuthorization()
        guard isAuthorized else { throw LibraryRestoreError.authorizationRequired }
        return try await resolveCatalog(kind: link.kind, id: link.id)
    }

    private func resolveCatalog(kind: AppleMusicReference.Kind, id: String) async throws -> AppleMusicLibraryItem {
        let musicID = MusicItemID(id)
        let item: AppleMusicLibraryItem?
        switch kind {
        case .song:
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: musicID)
            item = try await request.response().items.first.map(AppleMusicLibraryItem.song)
        case .album:
            let request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: musicID)
            item = try await request.response().items.first.map(AppleMusicLibraryItem.album)
        case .playlist:
            let request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: musicID)
            item = try await request.response().items.first.map(AppleMusicLibraryItem.playlist)
        }
        try Task.checkCancellation()
        guard var item else { throw CatalogLinkError.unavailable }
        item.source = .catalog
        return item
    }

    private enum LibraryRestoreError: LocalizedError {
        case authorizationRequired, itemMissing
        var errorDescription: String? {
            NSLocalizedString(self == .authorizationRequired ? "Music Authorization Required" : "Music Library Item Missing", comment: "")
        }
    }

    func tracks(in item: AppleMusicLibraryItem) async throws -> [Track] {
        switch item.content {
        case .song(let song): return [.song(song)]
        case .album(let album):
            let detailed = try await album.with([.tracks])
            return try await allTracks(detailed.tracks)
        case .playlist(let playlist):
            let detailed = try await playlist.with([.tracks])
            return try await allTracks(detailed.tracks)
        }
    }

    private func allTracks(_ collection: MusicItemCollection<Track>?) async throws -> [Track] {
        guard var page = collection else { return [] }
        var result = Array(page)
        while page.hasNextBatch {
            try Task.checkCancellation()
            guard let next = try await page.nextBatch() else { break }
            result.append(contentsOf: next)
            page = next
        }
        return result
    }
}
