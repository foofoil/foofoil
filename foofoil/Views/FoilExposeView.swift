//
//  FoilExposeView.swift
//  foofoil
//
//  Created by tolg on 2026/9/14.
//

import AppKit
import Combine
import SwiftUI
import ImageIO

private actor FoilExposeDecodeLimiter {
    private let limit: Int
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if activeCount < limit {
            activeCount += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            activeCount -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// 覆盖层缩略图的异步解码：按历史缩略图边长上限解码即可满足卡片显示，带缓存与并发限制，复用历史 HEIC/原路径文件。
@MainActor
final class FoilExposeThumbnailLoader: ObservableObject {
    private static let decodeLimiter = FoilExposeDecodeLimiter(limit: 2)
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // 640 px RGBA 缩略图约 1.6 MB；覆盖层一次性展示的条目有限，双重限制兜底防无界增长。
        cache.countLimit = 80
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    @Published private(set) var image: NSImage?

    func load(path: String?) async {
        guard let path, FileManager.default.fileExists(atPath: path) else {
            image = nil
            return
        }
        if let cached = Self.cache.object(forKey: path as NSString) {
            image = cached
            return
        }
        image = nil
        await Self.decodeLimiter.acquire()
        let loaded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [
                    kCGImageSourceShouldCache: false
                  ] as CFDictionary),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: HistoryThumbnailGenerator.pixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: .zero)
        }.value
        await Self.decodeLimiter.release()
        if let loaded {
            let pixelCost = max(1, Int(loaded.size.width * loaded.size.height * 4))
            Self.cache.setObject(loaded, forKey: path as NSString, cost: pixelCost)
            image = loaded
        }
    }
}

/// 汇总每张卡片在窗口坐标系里的外框，用于计算“当前可见条目”（只有可见项才有编号）。
private struct ItemFramesPreference: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct ItemFrameReporter: View {
    let id: UUID

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: ItemFramesPreference.self, value: [id: proxy.frame(in: .global)])
        }
    }
}

/// 分类切换和键盘选择一起观察，避免分类重排被误当成键盘导航而滚动。
private struct FoilExposeSelectionSnapshot: Equatable {
    let index: Int
    let historyCategory: FoilExposeHistoryCategory
}

/// 覆盖层主体：深色半透明背景 + 标题/搜索控件 + 自适应网格缩略图；点击背景关闭。
/// 只在当前活跃显示器上展示，包含全部打开的箔片；历史记录与文件搜索各自独立分区。
/// 编号随滚动实时重排，保证可见项都有编号。
struct FoilExposeView: View {
    @ObservedObject var model: FoilExposeModel

    private static let gridColumns = [
        GridItem(.adaptive(minimum: 212, maximum: 300), spacing: 18)
    ]

    /// 文件结果用较窄的自适应列：名称与父目录一行可读，同时避免单列铺满整屏。
    private static let fileColumns = [
        GridItem(.adaptive(minimum: 320, maximum: 620), spacing: 10)
    ]

    /// 当前可见条目的下标（显示顺序）；编号与编号直选都据此实时计算。
    @State private var visibleIndices: [Int] = []
    @State private var repositionAfterPageScroll = false
    @State private var scrollPosition = ScrollPosition()
    @State private var contentOffsetY: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var favoriteShortcut = KeyboardShortcutStore.shared.shortcut(forID: "history.toggleFavorite")
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        let entries: [(offset: Int, item: FoilExposeItem)] = model.currentItems.enumerated()
            .map { (offset: $0.offset, item: $0.element) }
        let shortcutByID = Self.shortcutByID(for: entries, visibleIndices: visibleIndices)
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Color.black.opacity(0.42))

            GeometryReader { geo in
                // 标题/搜索控件固定在顶部，不随内容多少或滚动而移动；只有网格区域滚动。
                let scrollAreaHeight = max(0, geo.size.height - headerHeight)
                VStack(spacing: 0) {
                    header
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headerHeight = $0 }
                    ScrollView {
                        content(for: entries, shortcutByID: shortcutByID)
                            .padding(.horizontal, 44)
                            // 高亮卡片放大约 3%，屏幕较矮时首行贴住滚动区顶部会被裁掉，这里留出余量。
                            .padding(.top, 8)
                            .padding(.bottom, 32)
                            .frame(maxWidth: 1240)
                            .frame(maxWidth: .infinity)
                            // 内容不足一屏时保持顶部对齐，分类切换不因内容高度变化而整体移位。
                            .frame(minHeight: scrollAreaHeight, alignment: .top)
                    }
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, newValue in
                        contentOffsetY = newValue
                        // 程序化翻页瞬时完成；滚动一停就用最新可见集重定位高亮。
                        if repositionAfterPageScroll {
                            repositionToFirstVisible()
                        }
                    }
                    .onPreferenceChange(ItemFramesPreference.self) { frames in
                        updateVisibleEntries(entries: entries, frames: frames, viewport: geo.frame(in: .global))
                    }
                    .onChange(of: FoilExposeSelectionSnapshot(index: model.selectedIndex, historyCategory: model.historyCategory)) { old, new in
                        guard old.historyCategory == new.historyCategory else { return }
                        let newIndex = new.index
                        // 高亮已在屏内（如翻页重定位）就不滚动，避免打断浏览位置。
                        guard model.currentItems.indices.contains(newIndex),
                              !visibleIndices.contains(newIndex) else { return }
                        scrollPosition.scrollTo(id: model.currentItems[newIndex].id, anchor: .center)
                    }
                    .onChange(of: model.pageScrollRequest) {
                        guard let request = model.pageScrollRequest else { return }
                        // 整页滚动按网格区域高度（留出边距）计算。
                        let page = max(160, scrollAreaHeight - 160)
                        let target = contentOffsetY + (request.direction == .down ? page : -page)
                        scrollPosition.scrollTo(x: 0, y: target)
                        repositionAfterPageScroll = true
                        // 滚动未引起几何变化（已在边界）时兜底重定位。
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            repositionToFirstVisible()
                        }
                    }
                    .onChange(of: model.historyCategory) { _, _ in
                        repositionAfterPageScroll = false
                        // 保留浏览位置；内容缩短时由 ScrollView 自然限制到有效范围。
                    }
                    .onChange(of: model.searchText) { _, _ in
                        // 关键字变化后结果集重排，回到顶部；可见编号由外框回调自然重算。
                        repositionAfterPageScroll = false
                        scrollPosition.scrollTo(edge: .top)
                    }
                }
            }
        }
        // 点击空白或操作筛选后，搜索框继续接收键盘输入。
        .onTapGesture { model.requestSearchFieldFocus() }
        .onAppear { isSearchFieldFocused = true }
        .onChange(of: isSearchFieldFocused) { _, focused in
            if !focused { model.requestSearchFieldFocus() }
        }
        .onChange(of: model.searchFieldFocusRequest) { _, _ in
            guard model.isSearching else { return }
            isSearchFieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .keyboardShortcutsDidChange)) { _ in
            favoriteShortcut = KeyboardShortcutStore.shared.shortcut(forID: "history.toggleFavorite")
        }
        .ignoresSafeArea()
        .foilToast(model.toast)
    }

    private func updateVisibleEntries(
        entries: [(offset: Int, item: FoilExposeItem)],
        frames: [UUID: CGRect],
        viewport: CGRect
    ) {
        let visible = entries.filter { entry in
            guard let frame = frames[entry.item.id] else { return false }
            return frame.intersects(viewport)
        }
        let indices = visible.map(\.offset)
        if indices != visibleIndices {
            visibleIndices = indices
        }
        model.setVisibleIDs(visible.map(\.item.id))
        if repositionAfterPageScroll {
            repositionToFirstVisible()
        }
    }

    /// 整页滚动完成后：高亮重定位到当前可见的第一项。
    private func repositionToFirstVisible() {
        guard repositionAfterPageScroll else { return }
        repositionAfterPageScroll = false
        if let first = visibleIndices.first {
            model.selectedIndex = first
        }
    }

    /// 可见条目按显示顺序拿到 1-9、A-Z 的编号；不可见条目不编号（编号直选也不命中）。
    private static func shortcutByID(
        for entries: [(offset: Int, item: FoilExposeItem)],
        visibleIndices: [Int]
    ) -> [UUID: String] {
        let itemByIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.offset, $0.item) })
        var result: [UUID: String] = [:]
        for (position, index) in visibleIndices.enumerated() {
            guard let key = FoilExposeShortcut.key(forIndex: position),
                  let item = itemByIndex[index] else { break }
            result[item.id] = key
        }
        return result
    }

    @ViewBuilder
    private func content(
        for entries: [(offset: Int, item: FoilExposeItem)],
        shortcutByID: [UUID: String]
    ) -> some View {
        VStack(spacing: 24) {
            // 剪贴板入口贴在内容区上方、与内容右对齐；只有剪贴板里有可打开内容时出现。
            if let clipboardContent = model.clipboardContent {
                ClipboardHintButton(content: clipboardContent, action: model.onOpenClipboard)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            contentSections(for: entries, shortcutByID: shortcutByID)
        }
    }

    @ViewBuilder
    private func contentSections(
        for entries: [(offset: Int, item: FoilExposeItem)],
        shortcutByID: [UUID: String]
    ) -> some View {
        // 有关键字时不再给整页空态：文件结果区会说明“主目录中没有匹配的文件”。
        if entries.isEmpty && model.searchQuery.isEmpty && !model.showsHistorySection {
            Text(NSLocalizedString("No Foils on This Screen", comment: ""))
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 120)
        } else {
            let openEntries = entries.filter { !$0.item.isHistoryEntry && $0.item.musicItem == nil }
            let historyEntries = entries.filter { $0.item.isHistoryEntry }
            let musicEntries = entries.filter { $0.item.musicItem != nil }
            VStack(spacing: 32) {
                if entries.isEmpty && model.resultFilter == .all && !model.showsHistorySection {
                    // 关键字有输入但没有匹配的箔片/历史：提示居中占住网格区域的一行位置，
                    // 文件结果仍紧接在其下方，不被推到屏幕底部。
                    Text(String(format: NSLocalizedString("No Matching Foils Format", comment: ""), model.searchQuery))
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
                }
                if !openEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeader("Expose Open Section", symbol: "macwindow", count: openEntries.filter { !$0.item.isNewFoil }.count, tint: .mint)
                        grid(for: openEntries, shortcutByID: shortcutByID)
                    }
                }
                if model.showsHistorySection {
                    VStack(alignment: .leading, spacing: 16) {
                        historySectionHeader
                        if historyEntries.isEmpty {
                            Text("Expose History Category Empty")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(maxWidth: .infinity, minHeight: 96)
                        } else {
                            grid(for: historyEntries, shortcutByID: shortcutByID)
                        }
                    }
                    .id("expose-history")
                }
                fileResultsSection
                if model.showsMusicResults {
                    ForEach(AppleMusicSearchCategory.allCases.filter { model.resultFilter.includes($0) }) { category in
                        if !model.musicItems(in: category).isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                sectionHeader(category.sectionLocalizationKey, symbol: category.symbolName,
                                              count: nil, tint: .pink)
                                musicResultsGrid(
                                    for: musicEntries.filter { $0.item.musicItem?.searchCategory == category },
                                    shortcutByID: shortcutByID
                                )
                                if model.canExpandMusicResults(in: category) {
                                    fileActionButton(category.moreLocalizationKey) {
                                        model.expandMusicResults(in: category)
                                    }
                                }
                            }
                        }
                    }
                    if model.isMusicSearching {
                        SearchLoadingStatusView(text: NSLocalizedString("Searching Music Library", comment: ""), foreground: .white.opacity(0.62))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !model.isMusicAuthorized {
                        Text("Music Search Authorization Note").foregroundStyle(.white.opacity(0.6))
                    } else if let error = model.musicError {
                        Text(error).foregroundStyle(.white.opacity(0.6))
                    } else if musicEntries.isEmpty {
                        Text("Music No Search Results").foregroundStyle(.white.opacity(0.6))
                    }
                }
                if model.showsResultLimitNotice {
                    Text(String(format: NSLocalizedString("Search Result Limit Notice Format", comment: ""), model.displayedResultCount))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
                }
            }
        }
    }

    private func musicResultsGrid(
        for entries: [(offset: Int, item: FoilExposeItem)], shortcutByID: [UUID: String]
    ) -> some View {
        LazyVGrid(columns: Self.fileColumns, spacing: 10) {
            ForEach(entries, id: \.item.id) { entry in
                if let music = entry.item.musicItem {
                    FoilExposeSearchResultView(
                        symbolName: entry.item.symbolName, title: music.title,
                        subtitle: music.searchSubtitle,
                        isHighlighted: entry.offset == model.selectedIndex,
                        shortcut: shortcutByID[entry.item.id], showsSearchModifier: model.isSearching
                    ) { model.onSelect(entry.item) }
                    .background(ItemFrameReporter(id: entry.item.id))
                }
            }
        }
        .onGeometryChange(for: Int.self, of: { max(1, Int(($0.size.width + 10) / 330)) }) { model.musicColumnCount = $0 }
    }

    /// Spotlight 文件结果区：输入关键字后才出现，出现与结果更新都带平滑过渡。
    @ViewBuilder
    private var fileResultsSection: some View {
        Group {
            if model.showsFileResults {
                let isFolders = model.resultFilter == .folders
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(model.resultFilter.fileSectionLocalizationKey,
                                  symbol: isFolders ? "folder" : "magnifyingglass",
                                  count: model.visibleFiles.count,
                                  tint: .cyan)
                    // 关键字变化会先清空再补结果；网格常驻才能让行的增删都走同一段过渡。
                    LazyVGrid(columns: Self.fileColumns, spacing: 10) {
                        ForEach(model.visibleFiles) { file in
                            FoilExposeSearchResultView(
                                symbolName: file.symbolName, title: file.name,
                                subtitle: file.url.deletingLastPathComponent().path
                            ) { model.onOpenFile(file.url) }
                            .help(file.url.path)
                            .accessibilityLabel(String(
                                format: NSLocalizedString("Search File Accessibility Format", comment: ""),
                                file.name, file.url.deletingLastPathComponent().path
                            ))
                        }
                    }
                    .animation(.smooth(duration: 0.25), value: model.files)
                    if model.canExpandFileResults {
                        fileActionButton(model.resultFilter.moreFilesLocalizationKey) { model.expandFileResults() }
                    }
                    fileStatusLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.smooth(duration: 0.22), value: model.isFileSearching)
                .animation(.smooth(duration: 0.22), value: model.fileStatus)
                .animation(.smooth(duration: 0.22), value: model.fileSearchNotice)
                .transition(.opacity.combined(with: .offset(y: 18)))
            }
        }
        .animation(.smooth(duration: 0.3), value: model.showsFileResults)
    }

    /// 文件来源的状态行：加载、未启用、失败与空结果各自给出下一步动作；打开失败另起一行说明。
    @ViewBuilder
    private var fileStatusLine: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isFileSearching {
                SearchLoadingStatusView(text: NSLocalizedString(model.resultFilter.searchingFilesLocalizationKey, comment: ""), foreground: .white.opacity(0.62))
            } else if let status = model.fileStatus {
                HStack(spacing: 10) {
                    Text(NSLocalizedString(status.localizationKey, comment: ""))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.62))
                    switch status {
                    case .disabled:
                        fileActionButton("Enable File Search") { model.enableFileSearch() }
                    case .unavailable, .timedOut:
                        fileActionButton("Retry File Search") { model.restartFileSearch() }
                    }
                }
            } else if model.files.isEmpty {
                Text(NSLocalizedString(model.resultFilter.noFilesLocalizationKey, comment: ""))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.62))
            }
            if let notice = model.fileSearchNotice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    /// 覆盖层内的浅色描边按钮：深色材质上保持可读，与搜索控件的键帽风格一致。
    private func fileActionButton(_ localizationKey: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(NSLocalizedString(localizationKey, comment: ""))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.16)))
                .overlay(Capsule().stroke(Color.white.opacity(0.32), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func grid(
        for entries: [(offset: Int, item: FoilExposeItem)],
        shortcutByID: [UUID: String]
    ) -> some View {
        LazyVGrid(columns: Self.gridColumns, spacing: 18) {
            ForEach(entries, id: \.item.id) { entry in
                FoilExposeItemView(
                    item: entry.item,
                    isHighlighted: entry.offset == model.selectedIndex,
                    shortcut: shortcutByID[entry.item.id],
                    showsSearchModifier: model.isSearching
                ) {
                    model.onSelect(entry.item)
                }
                .background(ItemFrameReporter(id: entry.item.id))
                .contextMenu {
                    if entry.item.hasHistoryRecord {
                        Button {
                            model.onTogglePinned(entry.item)
                        } label: {
                            Label(NSLocalizedString(entry.item.historyIsPinned ? "Unfavorite History" : "Favorite History", comment: ""), systemImage: entry.item.historyIsPinned ? "bookmark.slash.fill" : "bookmark.fill")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    if entry.item.canRenameTitle {
                        Button {
                            model.onRenameItem(entry.item)
                        } label: {
                            Label("Change Title", systemImage: "pencil")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    if entry.item.isHistoryEntry {
                        Button(role: .destructive) {
                            model.onClearHistoryItem(entry.item)
                        } label: {
                            Label("Delete History Record", systemImage: "trash")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }

            }
        }
        .onGeometryChange(for: Int.self, of: { max(1, Int(($0.size.width + 18) / 230)) }) { model.columnCount = $0 }
    }

    private var historySectionHeader: some View {
        HStack(spacing: 16) {
            sectionHeader("Expose History Section", symbol: "clock.arrow.circlepath",
                          count: model.historyCount(in: model.historyCategory), tint: .white.opacity(0.7), showsDivider: false)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            // 宽屏时标签贴右；空间不足时只让标签横向滚动，标题保持单行。
            ViewThatFits(in: .horizontal) {
                historyCategoryLabels.fixedSize()
                ScrollView(.horizontal) { historyCategoryLabels }
                    .scrollIndicators(.hidden)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
        }
    }

    private var historyCategoryLabels: some View {
        HStack(spacing: 6) {
            ForEach(model.visibleHistoryCategories) { category in
                let selected = model.historyCategory == category
                let title = NSLocalizedString(category.localizationKey, comment: "")
                let count = model.historyCount(in: category)
                Button {
                    model.historyCategory = category
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: category.symbolName)
                        Text(title)
                        Text(count, format: .number).monospacedDigit()
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(selected ? 0.95 : 0.65))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(.white.opacity(selected ? 0.18 : 0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(title) \(count.formatted())"))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .contextMenu {
                    Button(role: .destructive) {
                        model.onClearHistory(category)
                    } label: {
                        Label(category.clearHistoryTitle, systemImage: "trash")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            Toggle(isOn: $model.pinnedOnly) {
                HStack(spacing: 5) {
                    Label("Favorited History", systemImage: "bookmark.fill")
                        .foregroundStyle(.white)
                    if let favoriteShortcut {
                        Text(favoriteShortcut.displayString)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.button)
            .help(Text("Favorited History"))
        }
    }

    /// 来源标题不依赖卡片透明度，选中和搜索时仍保持清晰的分区。
    private func sectionHeader(_ key: String, symbol: String, count: Int?, tint: Color, showsDivider: Bool = true) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            Text(NSLocalizedString(key, comment: ""))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            if let count {
            Text(count, format: .number)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.white.opacity(0.08), in: Capsule())
            }
            if showsDivider {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Text(Self.headerTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                searchControl
            }
            .frame(height: 32)
            HStack(spacing: 16) {
                Text(NSLocalizedString("Search Foils Hint", comment: ""))
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.62))
            .opacity(model.isPickingScope ? 0 : 1)
            .animation(.easeInOut(duration: 0.15), value: model.isPickingScope)
        }
        .padding(.top, 30)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .zIndex(10)
    }

    /// 搜索框始终显示；/ 用于选择搜索范围。
    private var searchControl: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            if let scope = model.activeScope {
                HStack(spacing: 4) {
                    Image(systemName: scope.symbolName)
                        .font(.system(size: 11))
                    Text(scope.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Button {
                        model.clearActiveScope()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.22)))
                .foregroundStyle(.white)
            }
            TextField(exposeSearchPlaceholder, text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                // 不设置 tint：白色 tint 会把选区高亮一并染白，导致选中文字不可见。
                .frame(width: model.activeScope == nil ? 220 : 160)
                .focused($isSearchFieldFocused)
                .background(
                    SearchFieldFocusProbe(
                        isActive: model.isSearching,
                        focusRequest: model.searchFieldFocusRequest
                    )
                    .frame(width: 0, height: 0)
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.14)))
        .overlay(Capsule().stroke(Color.white.opacity(0.32), lineWidth: 1))
        .overlay(alignment: .top) {
            if model.isPickingScope {
                scopeHintsMenu
                    .offset(y: 40)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var exposeSearchPlaceholder: String {
        if let scope = model.activeScope {
            return String(format: NSLocalizedString("Search In Scope Placeholder", comment: ""), scope.displayName)
        }
        return NSLocalizedString("Search Foils Placeholder", comment: "")
    }

    @ViewBuilder
    private var scopeHintsMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.filteredScopes.enumerated()), id: \.element.id) { index, scope in
                Button {
                    model.selectScope(scope)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: scope.symbolName)
                            .font(.system(size: 13))
                            .frame(width: 20)
                            .foregroundStyle(index == model.highlightedScopeIndex ? .white : .white.opacity(0.6))
                        Text(scope.displayName)
                            .font(.system(size: 13, weight: index == model.highlightedScopeIndex ? .semibold : .regular))
                            .foregroundStyle(index == model.highlightedScopeIndex ? .white : .white.opacity(0.85))
                        Spacer()
                        Text(scope.englishName)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(index == model.highlightedScopeIndex ? Color.accentColor : Color.clear)
                )
            }
            if model.filteredScopes.isEmpty {
                Text(NSLocalizedString("No Matching Scopes", comment: ""))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            Divider().overlay(Color.white.opacity(0.12)).padding(.vertical, 2)
            Text(NSLocalizedString("Scope Hints Tip", comment: ""))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.42))
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(6)
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    /// 覆盖层标题使用应用显示名（中文环境为“浮箔”），与 App 菜单名称保持一致。
    private static let headerTitle: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? "foofoil"
}

/// 顶栏下方的剪贴板入口：只在剪贴板里有可打开内容时出现，类型名与实际打开结果一致；
/// 胶囊按钮造型明确可点击，点击等价于按 ⌘⇧V，在（空白或新建）箔片中打开剪贴板内容。
private struct ClipboardHintButton: View {
    let content: ClipboardOpenableContent
    let action: () -> Void

    @State private var isHovered = false

    @State private var shortcut = KeyboardShortcutStore.shared.shortcut(for: KeyboardShortcutCatalog.openClipboardContent)

    private var title: String {
        String(format: NSLocalizedString("Open Clipboard Item Format", comment: ""), content.localizedName)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let shortcut {
                    Text(shortcut.displayString)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.18)))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.38), lineWidth: 1))
                }
            }
            .foregroundStyle(.white.opacity(isHovered ? 1.0 : 0.88))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(isHovered ? 0.22 : 0.13)))
            .overlay(Capsule().stroke(Color.white.opacity(isHovered ? 0.5 : 0.3), lineWidth: 1))
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
        .onReceive(NotificationCenter.default.publisher(for: .keyboardShortcutsDidChange)) { _ in
            shortcut = KeyboardShortcutStore.shared.shortcut(for: KeyboardShortcutCatalog.openClipboardContent)
        }
    }
}

/// SwiftUI 条件插入的搜索输入框上 FocusState 偶尔无法落到 AppKit 第一响应者（面板尚未成为
/// key window 时尤其明显）；该探针直接在面板里找到输入框并设置第一响应者，作为兜底。
/// 对尚未成为 key 的窗口设置第一响应者同样有效，面板成为 key 后按键即进入输入框。
private struct SearchFieldFocusProbe: NSViewRepresentable {
    let isActive: Bool
    /// 聚焦请求序号：值变化会驱动一次视图更新，面板刚成为 key window 时据此重试聚焦。
    let focusRequest: UInt64

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard isActive else { return }
        // 更新期间不改第一响应者；输入框可能尚未建好，等本次更新结束后短暂重试。
        DispatchQueue.main.async {
            Self.focusSearchField(in: nsView.window, retries: 3)
        }
    }

    private static func focusSearchField(in window: NSWindow?, retries: Int) {
        guard let window, window is FoilExposePanel else { return }
        if window.firstResponder is NSTextView { return }
        if let field = firstEditableTextField(in: window) {
            _ = window.makeFirstResponder(field)
            if window.firstResponder is NSTextView { return }
        }
        guard retries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusSearchField(in: window, retries: retries - 1)
        }
    }

    /// 覆盖层面板中唯一可编辑的输入框就是搜索框，按前序遍历取第一个即可。
    private static func firstEditableTextField(in window: NSWindow) -> NSTextField? {
        guard let contentView = window.contentView else { return nil }
        return firstEditableTextField(in: contentView)
    }

    private static func firstEditableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let found = firstEditableTextField(in: subview) { return found }
        }
        return nil
    }
}

/// 覆盖层中的单个箔片卡片：缩略图（文档型为截断正文）+ 类型图标 + 快捷键角标 + 标题，悬停/按压反馈对齐 HistoryCardView。
/// 键盘高亮与鼠标悬停使用同等的放大反馈，高亮另以更亮的描边区分。
struct FoilExposeItemView: View {
    let item: FoilExposeItem
    var isHighlighted: Bool = false
    /// 动态编号：随滚动实时变化，只有当前可见项才有编号。
    var shortcut: String?
    /// 搜索输入状态：编号直选需要 ⌃，角标同步显示修饰键。
    var showsSearchModifier: Bool = false
    var onSelect: () -> Void

    @State private var isHovered = false
    @StateObject private var thumbnailLoader = FoilExposeThumbnailLoader()

    private var isEmphasized: Bool { isHovered || isHighlighted }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                thumbnail
                HStack(spacing: 6) {
                    if !item.isNewFoil {
                        Image(systemName: item.isHistoryEntry ? "clock.arrow.circlepath" : "macwindow")
                            .foregroundStyle(item.isHistoryEntry ? Color.white.opacity(0.6) : .mint)
                    }
                    if item.isClipboardContent {
                        Image(systemName: "doc.on.clipboard")
                            .help(Text("From Clipboard"))
                            .accessibilityLabel(Text("From Clipboard"))
                    }
                    Text(item.title)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .scaleEffect(isEmphasized ? 1.03 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isEmphasized)
        }
        .buttonStyle(FoilExposeCardButtonStyle())
        .onHover { hovering in
            isHovered = hovering
        }
        .task(id: item.thumbnailPath) {
            await thumbnailLoader.load(path: item.thumbnailPath)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityLabel: String {
        let title = item.controller?.appState.isIncognito == true
            ? "\(NSLocalizedString("Incognito Foil", comment: "")) \(item.title)" : item.title
        let annotatedTitle = item.historyIsPinned ? "\(NSLocalizedString("Favorited History", comment: "")) \(title)" : title
        guard let shortcut else { return annotatedTitle }
        return "\(showsSearchModifier ? "⌃" : "")\(shortcut) \(annotatedTitle)"
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.08))
            .aspectRatio(1, contentMode: .fit)
            // 先由网格列宽确定正方形边界；内容只参与绘制，避免宽图片或正文撑开卡片。
            .overlay {
                GeometryReader { geometry in
                    ZStack {
                        if item.isNewFoil {
                            // 无箔窗口时的占位卡：大号加号提示可新建空白箔。
                            Image(systemName: "plus")
                                .font(.system(size: 44, weight: .light))
                                .foregroundStyle(.white.opacity(0.7))
                        } else if let image = thumbnailLoader.image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                            typeIconBadge
                        } else if let bodyPreview = item.bodyPreview {
                            // 文档型箔片：缩略图位置直接展示截断正文，一眼看出写了什么；行数固定避免盖到左下角类型角标。
                            Text(bodyPreview)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineSpacing(4)
                                .multilineTextAlignment(.leading)
                                .lineLimit(8)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(12)
                            typeIconBadge
                        } else if item.symbolName == AppleMusicReference.symbolName {
                            // Apple Music 历史/搜索条目使用品牌红底白音符，避免看起来与普通音频图标相同。
                            AppleMusicTypeIcon(size: item.contentKind == .camera ? 56 : 34)
                        } else {
                            // 没有缩略图时用大号类型图标占位，仍能看出内容类型；摄像头箔不展示画面，图标更大。
                            Image(systemName: item.symbolName)
                                .font(.system(size: item.contentKind == .camera ? 56 : 34, weight: item.contentKind == .camera ? .light : .regular))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        mediaKindOverlay
                        shortcutBadge
                        if item.controller?.appState.isIncognito == true {
                            VStack {
                                HStack {
                                    Spacer()
                                    Image(nsImage: IncognitoFoilIcon.image)
                                        .renderingMode(.template)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 16, height: 16)
                                        .foregroundStyle(.white)
                                        .frame(width: 26, height: 26)
                                        .background(Circle().fill(Color.black.opacity(0.65)))
                                        .help(Text("Incognito Foil History Hint"))
                                }
                                Spacer()
                            }
                            .padding(7)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                if item.historyIsPinned {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .padding(7)
                        .help(Text("Favorited History"))
                }
            }
            .overlay(strokeOverlay)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 占位卡用虚线边框传达“新增”语义；键盘高亮描边更亮更粗，其余卡片沿用实线描边。
    @ViewBuilder
    private var strokeOverlay: some View {
        if isHighlighted {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.85), lineWidth: 2)
        } else if item.isNewFoil {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(isHovered ? 0.5 : 0.24),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(isHovered ? 0.5 : 0.16), lineWidth: 1)
        }
    }

    /// 缩略图左下角的类型图标：叠加在缩略图上标明内容类型，避免只靠画面猜内容。
    private var typeIconBadge: some View {
        VStack {
            Spacer()
            HStack {
                if item.symbolName == AppleMusicReference.symbolName {
                    AppleMusicTypeIcon(size: 20)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                }
                Spacer()
            }
        }
        .padding(7)
        .accessibilityHidden(true)
    }

    /// 打开的音视频箔片正在播放时，叠加与音频列表当前曲目一致的动态频率柱状图；
    /// 暂停与历史条目不再叠加居中静态图标，类型信息由左下角类型图标承担。
    @ViewBuilder
    private var mediaKindOverlay: some View {
        if let appState = item.controller?.appState,
           item.contentKind == .audio || item.contentKind == .video,
           appState.isMediaPlaying {
            MediaPlaybackBars(isPlaying: true)
                // 覆盖层卡片远大于导航行，柱状图等比放大并加投影保证可读。
                .scaleEffect(1.6)
                .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
        }
    }

    @ViewBuilder
    private var shortcutBadge: some View {
        if let shortcut {
            VStack {
                HStack {
                    Text(showsSearchModifier ? "⌃\(shortcut)" : shortcut)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.55))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                        )
                    Spacer()
                }
                Spacer()
            }
            .padding(7)
        }
    }
}

/// 用户文件与音乐搜索共用紧凑结果行，统一尺寸、文字层级和悬停反馈。
private struct FoilExposeSearchResultView: View {
    let symbolName: String
    let title: String
    let subtitle: String
    var isHighlighted = false
    var shortcut: String? = nil
    var showsSearchModifier = false
    var onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                if symbolName == AppleMusicReference.symbolName {
                    AppleMusicTypeIcon(size: 24)
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.1)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if let shortcut {
                    Text("\(showsSearchModifier ? "⌃" : "")\(shortcut)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(isHovered || isHighlighted ? 0.12 : 0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(subtitle)")
        .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
    }
}

/// 卡片按压反馈：按下轻微缩小，与 HistoryCardView 的手感一致。
private struct FoilExposeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.interactiveSpring(response: 0.12, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
