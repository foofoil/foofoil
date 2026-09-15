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

/// 覆盖层主体：深色半透明背景 + 顶部标题提示 + 自适应网格缩略图；点击背景关闭。
struct FoilExposeView: View {
    @ObservedObject var model: FoilExposeModel
    let screen: NSScreen

    private static let gridColumns = [
        GridItem(.adaptive(minimum: 232, maximum: 300), spacing: 18)
    ]

    var body: some View {
        let items = model.items(for: screen)
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Rectangle().fill(Color.black.opacity(0.42))

            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 26) {
                        header
                        if items.isEmpty {
                            Text("No Foils on This Screen")
                                .font(.system(size: 15))
                                .foregroundStyle(.white.opacity(0.6))
                                .padding(.top, 120)
                        } else {
                            LazyVGrid(columns: Self.gridColumns, spacing: 18) {
                                ForEach(items) { item in
                                    FoilExposeItemView(item: item) {
                                        model.onSelect(item)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 44)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 1240)
                    .frame(maxWidth: .infinity)
                    // 条目少时整组内容纵向居中；条目多时自然恢复滚动。
                    .frame(minHeight: geo.size.height)
                }
            }
        }
        // 卡片按钮在自己的命中区内优先生效；落在空白处的点击交给背景关闭覆盖层。
        .onTapGesture { model.onDismiss() }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(Self.headerTitle)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
            Text("Show All Foils Hint")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(.top, 30)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// 覆盖层标题使用应用显示名（中文环境为“浮箔”），与 App 菜单名称保持一致。
    private static let headerTitle: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? "foofoil"
}

/// 覆盖层中的单个箔片卡片：缩略图 + 快捷键角标 + 标题，悬停/按压反馈对齐 HistoryCardView。
struct FoilExposeItemView: View {
    let item: FoilExposeItem
    var onSelect: () -> Void

    @State private var isHovered = false
    @StateObject private var thumbnailLoader = FoilExposeThumbnailLoader()

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
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isHovered)
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
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        guard let shortcut = item.shortcut else { return item.title }
        return "\(shortcut) \(item.title)"
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
            } else {
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

    /// 占位卡用虚线边框传达“新增”语义，其余卡片沿用实线描边。
    @ViewBuilder
    private var strokeOverlay: some View {
        if item.isNewFoil {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(isHovered ? 0.5 : 0.24),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(isHovered ? 0.5 : 0.16), lineWidth: 1)
        }
    }

    /// 叠在已加载缩略图上的半透明类型标记，与 HistoryCardView 的音视频标记一致。
    @ViewBuilder
    private var mediaKindOverlay: some View {
        if thumbnailLoader.image != nil, item.contentKind == .audio || item.contentKind == .video {
            Image(systemName: item.contentKind == .audio ? "music.note" : "play.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
    }

    @ViewBuilder
    private var shortcutBadge: some View {
        if let shortcut = item.shortcut {
            VStack {
                HStack {
                    Text(shortcut)
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
