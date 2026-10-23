import SwiftUI
import MusicKit
import ImageIO

struct HistorySearchResultRow: View {
    let result: HistorySearchResult
    let isSelected: Bool

    var body: some View {
        SearchResultRow(
            symbolName: result.symbolName,
            title: result.title,
            snippet: result.isClipboardContent ? NSLocalizedString("From Clipboard", comment: "") : result.matchedSnippet,
            pageNumber: result.matchedPageNumber,
            thumbnailPath: result.thumbnailPath,
            showsInlineIcon: true,
            isSelected: isSelected,
            historyIsPinned: result.historyIsPinned
        )
    }
}

struct OpenURLSearchResultRow: View {
    let url: URL
    let isSelected: Bool

    var body: some View {
        SearchResultRow(
            symbolName: "globe",
            title: String(format: NSLocalizedString("Open URL Search Result Format", comment: ""), url.absoluteString),
            snippet: nil,
            pageNumber: nil,
            thumbnailPath: nil,
            showsInlineIcon: false,
            isSelected: isSelected
        )
    }
}

/// 用户在搜索框直接输入且存在的路径；排在所有结果之前并默认选中。
struct DirectFilePathSearchResultRow: View {
    let file: DirectFilePath
    let isSelected: Bool

    var body: some View {
        let fileKey = file.isDirectory ? "Open Folder Search Result Format" : "Open File Search Result Format"
        let parentPath = file.url.deletingLastPathComponent().path
        SearchResultRow(symbolName: file.symbolName,
                        title: String(format: NSLocalizedString(fileKey, comment: ""), file.name),
                        snippet: parentPath,
                        pageNumber: nil, thumbnailPath: nil,
                        showsInlineIcon: false, isSelected: isSelected)
            .help(file.url.path)
            .accessibilityLabel(String(
                format: NSLocalizedString("Search File Accessibility Format", comment: ""),
                file.name,
                parentPath
            ))
    }
}

private struct SearchResultRow: View {
    let symbolName: String
    let title: String
    let snippet: String?
    let pageNumber: Int?
    let thumbnailPath: String?
    let showsInlineIcon: Bool
    let isSelected: Bool
    var historyIsPinned = false
    @StateObject private var thumbnail = HistorySearchThumbnailLoader()

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12))
                if let image = thumbnail.image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if symbolName == AppleMusicReference.symbolName {
                    AppleMusicTypeIcon(size: 28)
                } else {
                    Image(systemName: symbolName).font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .topTrailing) {
                if historyIsPinned {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                        .padding(3)
                        .background(.regularMaterial, in: Circle())
                        .padding(2)
                        .help(Text("Favorited History"))
                        .accessibilityLabel(Text("Favorited History"))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if showsInlineIcon {
                        if symbolName == AppleMusicReference.symbolName {
                            AppleMusicTypeIcon(size: 14)
                        } else {
                            Image(systemName: symbolName).foregroundStyle(.secondary)
                        }
                    }
                    Text(title).font(.headline).lineLimit(1)
                    if let page = pageNumber {
                        Text(String(format: NSLocalizedString("Search Result Page Format", comment: ""), page)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let snippet, !snippet.isEmpty {
                    Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.20) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .task(id: thumbnailPath) { await thumbnail.load(path: thumbnailPath) }
    }
}

struct SpotlightFileResultRow: View {
    let file: SpotlightFileResult
    let isSelected: Bool

    var body: some View {
        SearchResultRow(symbolName: file.symbolName, title: file.name,
                        snippet: file.url.deletingLastPathComponent().path,
                        pageNumber: nil, thumbnailPath: nil,
                        showsInlineIcon: false, isSelected: isSelected)
            .help(file.url.path)
            .accessibilityLabel(String(
                format: NSLocalizedString("Search File Accessibility Format", comment: ""),
                file.name,
                file.url.deletingLastPathComponent().path
            ))
    }
}

/// 音乐搜索与用户文件共用结果行；资料库浏览仍保留封面展示。
struct AppleMusicSearchResultRow: View {
    let item: AppleMusicLibraryItem
    let isSelected: Bool

    var body: some View {
        SearchResultRow(symbolName: item.searchCategory.symbolName, title: item.title,
                        snippet: item.searchSubtitle,
                        pageNumber: nil, thumbnailPath: nil,
                        showsInlineIcon: false, isSelected: isSelected)
    }
}

/// 分享链接解析前后保留同一个结果位置；目录封面直接使用 MusicKit 的 artwork URL。
struct AppleMusicLinkResultRow: View {
    let link: AppleMusicLink
    let item: AppleMusicLibraryItem?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: item?.artwork?.url(width: 112, height: 112)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                AppleMusicTypeIcon(size: 36)
            }
            .frame(width: 56, height: 56).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 4) {
                Text(item?.displayTitle ?? NSLocalizedString("Music Open Shared Link", comment: "")).lineLimit(2)
                Text(item?.searchSubtitle ?? link.url.absoluteString)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}
