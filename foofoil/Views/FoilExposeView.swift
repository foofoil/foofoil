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

/// 覆盖层缩略图的异步解码：512 像素足够卡片显示，带缓存与并发限制，复用历史 HEIC/原路径文件。
@MainActor
final class FoilExposeThumbnailLoader: ObservableObject {
    private static let decodeLimiter = FoilExposeDecodeLimiter(limit: 2)
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // 512 px RGBA 缩略图约 1 MB；覆盖层一次性展示的条目有限，双重限制兜底防无界增长。
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
                    kCGImageSourceThumbnailMaxPixelSize: 512,
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

/// 覆盖层主体：深色半透明背景 + 标题/搜索控件 + 自适应网格缩略图；点击背景关闭。
/// 只在当前活跃显示器上展示，包含全部打开的箔片；历史记录另起一行在后（半透明区分）。
/// 编号随滚动实时重排，保证可见项都有编号。
struct FoilExposeView: View {
    @ObservedObject var model: FoilExposeModel

    private static let gridColumns = [
        GridItem(.adaptive(minimum: 232, maximum: 300), spacing: 18)
    ]

    /// 当前可见条目的下标（显示顺序）；编号与编号直选都据此实时计算。
    @State private var visibleIndices: [Int] = []
    @State private var repositionAfterPageScroll = false
    @State private var scrollPosition = ScrollPosition()
    @State private var contentOffsetY: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
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
                            // 条目少时网格在剩余空间纵向居中；条目多时自然恢复滚动。
                            .frame(minHeight: scrollAreaHeight)
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
                    .onChange(of: model.selectedIndex) { _, newIndex in
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
                    .onChange(of: model.searchText) { _, _ in
                        // 关键字变化后结果集重排，回到顶部；可见编号由外框回调自然重算。
                        repositionAfterPageScroll = false
                        scrollPosition.scrollTo(edge: .top)
                    }
                }
            }
        }
        // 卡片按钮在自己的命中区内优先生效；落在空白处的点击先退出搜索输入，否则关闭覆盖层。
        .onTapGesture {
            if model.isSearching {
                model.endSearch()
            } else {
                model.onDismiss()
            }
        }
        .onChange(of: model.isSearching) { _, searching in
            // 条件插入的输入框需要显式取焦点；AppKit 第一响应者由聚焦探针兜底。
            isSearchFieldFocused = searching
        }
        .onChange(of: model.searchFieldFocusRequest) { _, _ in
            guard model.isSearching else { return }
            isSearchFieldFocused = true
        }
        .ignoresSafeArea()
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
        // 实际列数从卡片外框推导：同一行的卡片 y 相同，数一数即可，不依赖布局估算公式。
        if !frames.isEmpty {
            let rows = Dictionary(grouping: frames.values) { $0.minY.rounded() }
            if let columns = rows.values.map(\.count).max(), columns > 0 {
                model.columnCount = columns
            }
        }
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
        if entries.isEmpty {
            Text(model.searchQuery.isEmpty
                 ? NSLocalizedString("No Foils on This Screen", comment: "")
                 : NSLocalizedString("No Search Results", comment: ""))
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 120)
        } else {
            let openEntries = entries.filter { !$0.item.isHistoryEntry }
            let historyEntries = entries.filter { $0.item.isHistoryEntry }
            VStack(spacing: 18) {
                if !openEntries.isEmpty {
                    grid(for: openEntries, shortcutByID: shortcutByID)
                }
                if !historyEntries.isEmpty {
                    // 历史记录另起一行，并降低透明度与打开的箔片区分；高亮项保持完整亮度。
                    grid(for: historyEntries, shortcutByID: shortcutByID, dimsHistory: true)
                }
            }
        }
    }

    private func grid(
        for entries: [(offset: Int, item: FoilExposeItem)],
        shortcutByID: [UUID: String],
        dimsHistory: Bool = false
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
                .opacity(dimsHistory && entry.offset != model.selectedIndex ? 0.72 : 1)
            }
        }
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
                Text(model.isSearching
                     ? NSLocalizedString("Search Foils Hint", comment: "")
                     : NSLocalizedString("Show All Foils Hint", comment: ""))
                Text("Tip: Command-Shift-V opens clipboard content")
            }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.62))
        }
        .padding(.top, 30)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// 标题后的搜索入口：默认是“/ 搜索”键帽提示，按 / 或点击后变成输入框；
    /// 退出输入后保留结果，提示位置显示 “xxx”的搜索结果 与清除按钮。
    @ViewBuilder
    private var searchControl: some View {
        if model.isSearching {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                TextField(NSLocalizedString("Search Foils Placeholder", comment: ""), text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    // 不设置 tint：白色 tint 会把选区高亮一并染白，导致选中文字不可见。
                    .frame(width: 200)
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
            .environment(\.colorScheme, .dark)
        } else if model.searchQuery.isEmpty {
            Button {
                model.beginSearch()
            } label: {
                HStack(spacing: 7) {
                    Text("/")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 20)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.16)))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.35), lineWidth: 1))
                    Text(NSLocalizedString("Search Foils", comment: ""))
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Search Foils", comment: ""))
            .accessibilityLabel(NSLocalizedString("Search Foils Placeholder", comment: ""))
        } else {
            HStack(spacing: 8) {
                Text(String(format: NSLocalizedString("Search Foils Results Format", comment: ""), model.searchQuery))
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Button {
                    model.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Clear", comment: ""))
                .accessibilityLabel(NSLocalizedString("Clear", comment: ""))
            }
        }
    }

    /// 覆盖层标题使用应用显示名（中文环境为“浮箔”），与 App 菜单名称保持一致。
    private static let headerTitle: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? "foofoil"
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

/// 覆盖层中的单个箔片卡片：缩略图 + 类型图标 + 快捷键角标 + 标题，悬停/按压反馈对齐 HistoryCardView。
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
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        guard let shortcut else { return item.title }
        return "\(showsSearchModifier ? "⌃" : "")\(shortcut) \(item.title)"
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.08))
            if item.isNewFoil {
                // 无箔窗口时的占位卡：大号加号提示可新建空白箔。
                Image(systemName: "plus")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.white.opacity(0.7))
            } else if let image = thumbnailLoader.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                typeIconBadge
            } else {
                // 没有缩略图时用大号类型图标占位，仍能看出内容类型。
                Image(systemName: item.symbolName)
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.55))
            }
            mediaKindOverlay
            shortcutBadge
        }
        // 正方形卡片：高度随列宽而定，超出部分裁掉。
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                Image(systemName: item.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
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

/// 卡片按压反馈：按下轻微缩小，与 HistoryCardView 的手感一致。
private struct FoilExposeCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.interactiveSpring(response: 0.12, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
