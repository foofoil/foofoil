import Foundation

nonisolated enum SearchResultLimits {
    static let maximum = 60
    // 多取一项，用实际匹配证明还有未展示结果，不把恰好 60 项误报为截断。
    static let probe = maximum + 1
    static let initial = 6
    static let increment = 18
}

enum SearchResultFilter: CaseIterable, Identifiable {
    case all, files, albums, songs
    var id: Self { self }
    var localizationKey: String {
        switch self {
        case .all: "Search Filter All"
        case .files: "Search Filter Files"
        case .albums: "Music Albums"
        case .songs: "Music Songs"
        }
    }
    var musicCategory: AppleMusicSearchCategory? {
        switch self {
        case .albums: .albums
        case .songs: .songs
        default: nil
        }
    }
    var includesFiles: Bool { self == .all || self == .files }
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
        if filter == .all {
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
