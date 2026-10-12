import Foundation

nonisolated enum SearchResultLimits {
    static let maximum = 60
    // 多取一项，用实际匹配证明还有未展示结果，不把恰好 60 项误报为截断。
    static let probe = maximum + 1
    static let initial = 6
    static let increment = 18
    /// 总览搜索的文件与每个音乐分组首次展示数量；每个分组单独封顶 maximum。
    static let overviewGroupInitial = 18
}

enum SearchResultFilter: CaseIterable, Identifiable, Equatable, Sendable {
    case all, history, files, folders, albums, playlists, songs
    var id: Self { self }
    var localizationKey: String {
        switch self {
        case .all: "Search Filter All"
        case .history: "Search History Section"
        case .files: "Search Filter Files"
        case .folders: "Search Filter Folders"
        case .albums: "Music Albums"
        case .playlists: "Music Playlists"
        case .songs: "Music Songs"
        }
    }
    var musicCategory: AppleMusicSearchCategory? {
        switch self {
        case .albums: .albums
        case .playlists: .playlists
        case .songs: .songs
        default: nil
        }
    }
    var includesFiles: Bool { self == .all || self == .files || self == .folders }
    var target: SpotlightSearchTarget {
        switch self {
        case .folders: .folders
        case .files: .files
        default: .all
        }
    }
    var fileSectionLocalizationKey: String {
        switch self {
        case .folders: "Local Folders Section"
        case .files: "Local Files Section"
        default: "Local Files and Folders Section"
        }
    }
    var searchingFilesLocalizationKey: String {
        switch self {
        case .folders: "Searching Local Folders"
        case .files: "Searching Local Files"
        default: "Searching Local Files and Folders"
        }
    }
    var noFilesLocalizationKey: String {
        switch self {
        case .folders: "No Local Folder Results"
        case .files: "No Local File Results"
        default: "No Local Files and Folders Results"
        }
    }
    var moreFilesLocalizationKey: String {
        switch self {
        case .folders: "Search More Folders"
        case .files: "Search More Files"
        default: "Search More Files and Folders"
        }
    }
    func includes(_ category: AppleMusicSearchCategory) -> Bool { self == .all || musicCategory == category }
}

/// 来源共享 60 个展示名额；综合结果先为文件和各音乐分组保留少量名额，再按顺序分配。
struct SearchResultBudget {
    var base = 0
    var files = 0
    var music: [AppleMusicSearchCategory: Int] = [:]

    init(baseCount: Int, fileCount: Int, musicCounts: [AppleMusicSearchCategory: Int],
         desiredMusicCounts: [AppleMusicSearchCategory: Int], filter: SearchResultFilter,
         initialCount: Int = SearchResultLimits.initial, desiredBaseCount: Int? = nil, desiredFileCount: Int? = nil) {
        var remaining = SearchResultLimits.maximum
        let categories = AppleMusicSearchCategory.allCases.filter { filter.includes($0) }
        for category in categories {
            let count = min(musicCounts[category, default: 0], initialCount, remaining)
            music[category] = count
            remaining -= count
        }
        if filter.includesFiles {
            files = min(fileCount, initialCount, remaining)
            remaining -= files
        }
        if filter == .all || filter == .history {
            base = min(baseCount, desiredBaseCount ?? baseCount, remaining)
            remaining -= base
        }
        if filter.includesFiles {
            let extra = min(max(0, min(fileCount, desiredFileCount ?? fileCount) - files), remaining)
            files += extra
            remaining -= extra
        }
        for category in categories {
            let desired = min(musicCounts[category, default: 0], desiredMusicCounts[category, default: initialCount])
            let extra = min(max(0, desired - music[category, default: 0]), remaining)
            music[category, default: 0] += extra
            remaining -= extra
        }
    }
}
