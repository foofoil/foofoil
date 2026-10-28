import Foundation

/// ⌘P 与 Exposé 搜索的限定范围定义
enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case history = "history"
    case file = "file"
    case folder = "folder"
    case url = "url"
    case clipboard = "clipboard"
    case album = "album"
    case playlist = "playlist"
    case song = "song"
    case terminal = "terminal"
    case camera = "camera"
    case enableFiles = "enable-files"
    case enableMusic = "enable-music"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .history: return "历史"
        case .file: return "文件"
        case .folder: return "目录"
        case .url: return NSLocalizedString("Quick Open URL Option", comment: "")
        case .clipboard: return NSLocalizedString("Clipboard Search Scope", comment: "")
        case .album: return "Apple Music 专辑"
        case .playlist: return "Apple Music 歌单"
        case .song: return "Apple Music 歌曲"
        case .terminal: return NSLocalizedString("Terminal", comment: "")
        case .camera: return NSLocalizedString("Foil Info Camera", comment: "")
        case .enableFiles: return NSLocalizedString("Enable Local File Search", comment: "")
        case .enableMusic: return NSLocalizedString("Music Enable Search", comment: "")
        }
    }

    var englishName: String {
        switch self {
        case .history: return "history"
        case .file: return "file"
        case .folder: return "folder"
        case .url: return "url"
        case .clipboard: return "clipboard"
        case .album: return "album"
        case .playlist: return "playlist"
        case .song: return "song"
        case .terminal: return "terminal"
        case .camera: return "camera"
        case .enableFiles: return "enable-files"
        case .enableMusic: return "enable-music"
        }
    }

    var symbolName: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        case .file: return "doc"
        case .folder: return "folder"
        case .url: return "link"
        case .clipboard: return "doc.on.clipboard"
        case .album: return "music.pages"
        case .playlist: return "music.note.list"
        case .song: return "music.note"
        case .terminal: return "terminal"
        case .camera: return "web.camera.fill"
        case .enableFiles: return "doc.badge.plus"
        case .enableMusic: return "music.note.list"
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
        case .terminal, .camera, .url, .clipboard, .enableFiles, .enableMusic: return .all
        }
    }

    var isOpeningCommand: Bool { self == .terminal || self == .camera || self == .url }

    var isEnableAction: Bool { self == .enableFiles || self == .enableMusic }

    static func availableScopes(musicLibraryEnabled: Bool, fileSearchEnabled: Bool = true, musicSearchEnabled: Bool = true) -> [SearchScope] {
        var scopes: [SearchScope] = [.clipboard, .history]
        if fileSearchEnabled { scopes += [.file, .folder] }
        scopes += [.url, .terminal, .camera]
        if !fileSearchEnabled { scopes.append(.enableFiles) }
        if !musicLibraryEnabled || !musicSearchEnabled { scopes.append(.enableMusic) }
        if musicLibraryEnabled && musicSearchEnabled { scopes += [.album, .playlist, .song] }
        return scopes
    }

    /// 三个搜索入口共用开启动作；启用资料库不代替系统的音乐访问授权。
    @MainActor
    func enableFeatureIfNeeded() -> Bool {
        switch self {
        case .enableFiles: LocalFileSearchSettings.shared.isEnabled = true
        case .enableMusic:
            SettingsStore.shared.appleMusicLibraryEnabled = true
            SettingsStore.shared.appleMusicSearchEnabled = true
        default: return false
        }
        return true
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
        case .url:
            return ["网址", "url", "web", "wangzhi", "wz"]
        case .clipboard:
            return ["剪贴板", "clipboard", "paste", "jiantieban", "jtb"]
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
        case .enableFiles:
            return ["开启本地文件搜索", "文件", "目录", "file", "folder", "enable-files", "wenjian", "mulu"]
        case .enableMusic:
            return ["开启 Apple Music 资料库", "音乐", "专辑", "歌单", "歌曲", "music", "album", "playlist", "song", "enable-music"]
        }
    }
}
