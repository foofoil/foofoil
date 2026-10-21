import Foundation

/// ⌘P 与 Exposé 搜索的限定范围定义
enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case history = "history"
    case file = "file"
    case folder = "folder"
    case album = "album"
    case playlist = "playlist"
    case song = "song"
    case terminal = "terminal"
    case camera = "camera"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .history: return "历史"
        case .file: return "文件"
        case .folder: return "目录"
        case .album: return "Apple Music 专辑"
        case .playlist: return "Apple Music 歌单"
        case .song: return "Apple Music 歌曲"
        case .terminal: return NSLocalizedString("Terminal", comment: "")
        case .camera: return NSLocalizedString("Foil Info Camera", comment: "")
        }
    }

    var englishName: String {
        switch self {
        case .history: return "history"
        case .file: return "file"
        case .folder: return "folder"
        case .album: return "album"
        case .playlist: return "playlist"
        case .song: return "song"
        case .terminal: return "terminal"
        case .camera: return "camera"
        }
    }

    var symbolName: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .file: return "doc"
        case .folder: return "folder"
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        case .song: return "music.note"
        case .terminal: return "terminal"
        case .camera: return "web.camera.fill"
        }
    }

    var filter: SearchResultFilter {
        switch self {
        case .history: return .history
        case .file: return .files
        case .folder: return .folders
        case .album: return .albums
        case .playlist: return .playlists
        case .song: return .songs
        case .terminal, .camera: return .all
        }
    }

    var isOpeningCommand: Bool { self == .terminal || self == .camera }

    static func availableScopes(musicLibraryEnabled: Bool) -> [SearchScope] {
        if musicLibraryEnabled {
            return [.history, .file, .folder, .album, .playlist, .song, .terminal, .camera]
        } else {
            return [.history, .file, .folder, .terminal, .camera]
        }
    }

    func matches(filter: String) -> Bool {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return true }
        let keywords = searchKeywords.map { $0.lowercased() }
        return keywords.contains { $0.contains(trimmed) }
    }

    var searchKeywords: [String] {
        switch self {
        case .history:
            return ["历史", "history", "lishi", "ls"]
        case .file:
            return ["文件", "file", "wenjian", "wj"]
        case .folder:
            return ["目录", "folder", "mulu", "dir", "directory", "ml"]
        case .album:
            return ["Apple Music 专辑", "专辑", "album", "zhuanji", "zj"]
        case .playlist:
            return ["Apple Music 歌单", "歌单", "playlist", "gedan", "gd"]
        case .song:
            return ["Apple Music 歌曲", "歌曲", "song", "gequ", "gq"]
        case .terminal:
            return ["终端", "terminal", "zhongduan", "zd"]
        case .camera:
            return ["摄像头", "camera", "shexiangtou", "sxt"]
        }
    }
}
