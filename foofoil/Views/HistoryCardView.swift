//
//  HistoryCardView.swift
//  foofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI
import AppKit

// 历史记录卡片视图，使用 DragGesture(minimumDistance: 0) 实现绝对零延迟的鼠标按下/抬起视觉反馈。
// 悬停态由父视图传入：卡片上浮不得带动命中区，否则 tracking area 会跟着移出指针。
struct HistoryCardView: View {
    let config: WindowConfig
    var shortcutText: String? = nil
    var isHovered: Bool = false
    let action: () -> Void

    @State private var isPressed = false
    @State private var cardImage: NSImage? = nil

    var body: some View {
        historyCardContent(for: config)
            .background(
                Color(NSColor.controlBackgroundColor)
                    .opacity(isPressed ? 0.7 : (isHovered ? 1.0 : 0.95))
            )
            .cornerRadius(8)
            .overlay(
                shortcutOverlay
                    .animation(.easeInOut(duration: 0.15), value: shortcutText)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(isPressed ? 0.40 : (isHovered ? 0.30 : 0.25)),
                radius: isPressed ? 1.0 : (isHovered ? 6 : 3),
                x: 0,
                y: isPressed ? 1.0 : (isHovered ? 3.5 : 1.5)
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .offset(y: isPressed ? 0 : (isHovered ? -3 : 0))
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isHovered)
            .animation(.interactiveSpring(response: 0.12, dampingFraction: 0.8), value: isPressed)
            .frame(width: 60, height: 60)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let localLocation = value.location
                        let rect = CGRect(x: 0, y: 0, width: 60, height: 60)
                        if rect.contains(localLocation) {
                            if !isPressed {
                                isPressed = true
                            }
                        } else {
                            if isPressed {
                                isPressed = false
                            }
                        }
                    }
                    .onEnded { value in
                        if isPressed {
                            isPressed = false
                            action()
                        }
                    }
            )
            .onAppear {
                loadImageAsync()
            }
            .onChange(of: config.imagePath) { _ in
                loadImageAsync()
            }
            .onChange(of: config.thumbnailPath) { _ in
                loadImageAsync()
            }
            .onChange(of: config.fileList?.items.count) { _ in
                loadImageAsync()
            }
    }

    private var isSVG: Bool {
        guard let name = config.originalImageName?.lowercased() else { return false }
        return name.hasSuffix(".svg")
    }

    private var historyKind: HistoryContentKind {
        config.contentKind ?? HistoryContentKind.infer(from: config)
    }

    private var isAudioHistory: Bool { historyKind == .audio }
    private var isVideoHistory: Bool { historyKind == .video }

    @ViewBuilder
    private var shortcutOverlay: some View {
        if let shortcutText = shortcutText {
            Text(shortcutText)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black.opacity(0.45))
                        .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    private var audioPlaceholder: some View {
        mediaPlaceholder(systemName: "music.note")
    }

    private var videoPlaceholder: some View {
        mediaPlaceholder(systemName: "play.fill")
    }

    private func mediaPlaceholder(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 60, height: 60)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var fileListCountBadge: some View {
        if let count = config.fileList?.items.count, count >= 2 {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.55), in: Capsule())
                }
            }
            .padding(4)
            .accessibilityLabel(
                String(
                    format: NSLocalizedString(config.fileList?.kind.historyTitleFormatKey ?? "Image List History Format", comment: ""),
                    count
                )
            )
        }
    }

    /// 叠在封面缩略图上的半透明类型标记，避免音频封面被当成普通图片。
    @ViewBuilder
    private var mediaKindOverlay: some View {
        if isAudioHistory || isVideoHistory {
            Image(systemName: isAudioHistory ? "music.note" : "play.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func renderCardImage(for nsImage: NSImage) -> some View {
        let baseImage = Image(nsImage: nsImage).resizable()

        if isSVG, let svgColorHex = config.svgColor, let color = Color(hex: svgColorHex) {
            baseImage
                .renderingMode(.template)
                .foregroundColor(color)
        } else {
            baseImage
        }
    }

    /// 无 imagePath 的扩展音频也可能已有缩略图（cardImage）或应显示音视频占位；
    /// 仅纯文本/笔记走文字卡，避免 DSF 列表显示为空白卡。
    static func shouldShowMediaCard(config: WindowConfig, hasLoadedImage: Bool) -> Bool {
        if config.imagePath != nil { return true }
        if hasLoadedImage { return true }
        let kind = config.contentKind ?? HistoryContentKind.infer(from: config)
        return kind == .audio || kind == .video
    }

    private func loadImageAsync() {
        // 优先使用已生成且单独存储的正方形 HEIC 缩略图，避免加载超大原图
        let path: String
        if let thumbnailPath = config.thumbnailPath, FileManager.default.fileExists(atPath: thumbnailPath) {
            path = thumbnailPath
        } else if !isAudioHistory, !isVideoHistory, let imagePath = config.imagePath, FileManager.default.fileExists(atPath: imagePath) {
            // 音视频原文件不是图片；无封面/首帧时保持空缩略图，由卡片显示类型图标。
            path = imagePath
        } else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            if let nsImage = NSImage(contentsOfFile: path) {
                // 后台预解码，避免渲染时主线程同步等待导致优先级反转
                let _ = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
                DispatchQueue.main.async {
                    self.cardImage = nsImage
                }
            }
        }
    }

    @ViewBuilder
    private func historyCardContent(for config: WindowConfig) -> some View {
        Group {
            if Self.shouldShowMediaCard(config: config, hasLoadedImage: cardImage != nil) {
                if let nsImage = cardImage {
                    ZStack {
                        renderCardImage(for: nsImage)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipped()
                        mediaKindOverlay
                        fileListCountBadge
                    }
                    .frame(width: 60, height: 60)
                    .clipped()
                } else if isAudioHistory {
                    ZStack {
                        audioPlaceholder
                        fileListCountBadge
                    }
                } else if isVideoHistory {
                    ZStack {
                        videoPlaceholder
                        fileListCountBadge
                    }
                } else {
                    Color(NSColor.controlBackgroundColor)
                        .frame(width: 60, height: 60)
                }
            } else if let webURLString = config.webURLString {
                VStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.system(size: 24))
                    Text(config.originalImageName ?? webURLString)
                        .font(.system(size: 7, design: .rounded))
                        .foregroundColor(.primary.opacity(0.85))
                        .lineLimit(3)
                        .padding(.horizontal, 4)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 60, height: 60)
            } else {
                Text(config.text)
                    .font(.system(size: 8, design: .rounded))
                    .foregroundColor(.primary.opacity(0.85))
                    .padding(6)
                    .frame(width: 60, height: 60, alignment: .topLeading)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
            }
        }
        .frame(width: 60, height: 60)
    }
}

enum HistoryItemHover {
    /// 离开旧项时仅在仍是该项的情况下清空，避免相邻卡片 entered/exited 顺序抖动。
    static func nextID(current: UUID?, itemID: UUID, hovering: Bool) -> UUID? {
        if hovering { return itemID }
        if current == itemID { return nil }
        return current
    }
}

/// SwiftUI `.onHover` 的 tracking area 会随子视图增删（缩略图加载）重建，指针已在内部时不会补发 entered。
/// 用稳定的 AppKit tracking area，并在重建后按当前指针位置同步，避免空白箔底部标题经常不出现。
struct HoverTrackingView: NSViewRepresentable {
    var onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        let view = HoverTrackingNSView()
        view.onHoverChanged = onHoverChanged
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }
}

final class HoverTrackingNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private(set) var isPointerInside = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        syncHoverFromMouseLocation()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            HoverTrackingSync.add(self)
        } else {
            HoverTrackingSync.remove(self)
            updateHoverState(isInside: false)
            return
        }
        syncHoverFromMouseLocation()
    }

    deinit {
        HoverTrackingSync.remove(self)
    }

    override func mouseEntered(with event: NSEvent) {
        syncHoverFromMouseLocation()
    }

    override func mouseExited(with event: NSEvent) {
        syncHoverFromMouseLocation()
    }

    override func mouseMoved(with event: NSEvent) {
        syncHoverFromMouseLocation()
    }

    func updateHoverState(isInside: Bool) {
        guard isPointerInside != isInside else { return }
        isPointerInside = isInside
        onHoverChanged?(isInside)
    }

    func isPointInside(_ pointInView: NSPoint) -> Bool {
        bounds.contains(pointInView)
    }

    func syncHoverFromMouseLocation() {
        guard let window, window.isVisible else {
            updateHoverState(isInside: false)
            return
        }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let pointInView = convert(windowPoint, from: nil)
        updateHoverState(
            isInside: Self.isPointerInsideItem(
                screenPoint: screenPoint,
                windowFrame: window.frame,
                pointInView: pointInView,
                viewBounds: bounds
            )
        )
    }

    static func isPointerInsideItem(
        screenPoint: NSPoint,
        windowFrame: NSRect,
        pointInView: NSPoint,
        viewBounds: NSRect
    ) -> Bool {
        windowFrame.contains(screenPoint) && viewBounds.contains(pointInView)
    }
}

/// 在 AppKit 把事件交给窗口之前按屏幕坐标同步 hover。
/// 箔窗 sendEvent 若拦截边缘 entered/moved，tracking area 会以为指针仍在窗外。
private enum HoverTrackingSync {
    static let views = NSHashTable<HoverTrackingNSView>.weakObjects()
    static var monitor: Any?

    static func add(_ view: HoverTrackingNSView) {
        views.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDragged]
        ) { event in
            for tracked in views.allObjects {
                tracked.syncHoverFromMouseLocation()
            }
            return event
        }
    }

    static func remove(_ view: HoverTrackingNSView) {
        views.remove(view)
        guard views.count == 0, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
