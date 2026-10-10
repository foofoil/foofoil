//
//  MarkdownTextView.swift
//  foofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI
import AppKit

private final class MarkdownCopyButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class MarkdownNSTextView: NSTextView {
    private var codeBlockTrackingArea: NSTrackingArea?
    private var hoveredCodeBlockRange: NSRange?
    private var copyFeedbackReset: DispatchWorkItem?
    private var scrollHighlightReset: DispatchWorkItem?
    private var scrollHighlightRange: NSRange?
    /// 表格单元格的块、列号与自然宽度，用于随容器宽度重新分配列宽。
    private var tableCells: [(block: NSTextTableBlock, column: Int, width: CGFloat)] = []
    private lazy var copyCodeButton: NSButton = {
        let button = MarkdownCopyButton()
        button.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = NSLocalizedString("Copy", comment: "")
        button.setAccessibilityLabel(NSLocalizedString("Copy", comment: ""))
        button.target = self
        button.action = #selector(copyHoveredCodeBlock)
        button.isHidden = true
        return button
    }()

    override func draw(_ dirtyRect: NSRect) {
        drawInlineCodeBackgrounds(in: dirtyRect)
        drawCodeBlockFrames(in: dirtyRect)
        super.draw(tableRedrawRect(intersecting: dirtyRect))
        updateCopyButtonFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { updateTableColumnWidths() }
    }

    /// 采集表格单元格的自然文本宽度（不含段落样式），文本替换时调用一次。
    func collectTableCells() {
        tableCells.removeAll()
        guard let textStorage, textStorage.length > 0 else { return }
        textStorage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            for case let block as NSTextTableBlock in style.textBlocks {
                let text = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
                text.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: text.length))
                tableCells.append((block, block.startingColumn, text.size().width))
            }
        }
    }

    /// 内容放得下时各列按自然宽度收缩、不折行；放不下时按各列自然宽度比例占满可用宽度。
    func updateTableColumnWidths() {
        guard !tableCells.isEmpty, let textStorage else { return }
        let available = bounds.width - textContainerInset.width * 2
        var columns: [ObjectIdentifier: [Int: CGFloat]] = [:]
        for cell in tableCells {
            let table = ObjectIdentifier(cell.block.table)
            columns[table, default: [:]][cell.column] = max(columns[table]?[cell.column] ?? 0, cell.width)
        }
        for cell in tableCells {
            let widths = columns[ObjectIdentifier(cell.block.table)] ?? [:]
            let total = widths.values.reduce(0, +)
            let width = widths[cell.column] ?? 0
            guard total > 0 else { continue }
            if total <= available {
                cell.block.setContentWidth(width.rounded(.up), type: .absolute)
            } else {
                cell.block.setContentWidth(width / total * 100, type: .percentage)
            }
        }
        layoutManager?.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: textStorage.length),
            actualCharacterRange: nil
        )
    }

    /// TextKit 局部重绘合并边框时会遗漏跨出 dirtyRect 的表格边界；按整张表格计算绘制范围。
    func tableRedrawRect(intersecting dirtyRect: NSRect) -> NSRect {
        guard let textStorage, let layoutManager, let textContainer, textStorage.length > 0 else { return dirtyRect }
        layoutManager.ensureLayout(for: textContainer)
        var tables: [ObjectIdentifier: NSRect] = [:]
        textStorage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            for case let block as NSTextTableBlock in style.textBlocks {
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let frame = layoutManager.boundsRect(for: block, glyphRange: glyphs)
                    .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                guard !frame.isEmpty else { continue }
                let key = ObjectIdentifier(block.table)
                tables[key] = tables[key].map { $0.union(frame) } ?? frame
            }
        }
        return tables.values.filter { $0.intersects(dirtyRect) }.reduce(dirtyRect) { $0.union($1) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let codeBlockTrackingArea {
            removeTrackingArea(codeBlockTrackingArea)
        }
        if copyCodeButton.superview == nil {
            addSubview(copyCodeButton)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        codeBlockTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let hoveredRange = codeBlockRangesAndFrames().first { $0.frame.contains(point) }?.range
        guard hoveredRange != hoveredCodeBlockRange else { return }
        hoveredCodeBlockRange = hoveredRange
        copyCodeButton.isHidden = hoveredRange == nil
        updateCopyButtonFrame()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredCodeBlockRange = nil
        copyCodeButton.isHidden = true
    }

    func resetCodeBlockHover() {
        hoveredCodeBlockRange = nil
        copyCodeButton.isHidden = true
    }

    /// 目录跳转后短暂高亮目标标题；新的跳转会替换上一次的高亮，超时后自动清除。
    func flashScrollHighlight(_ range: NSRange) {
        clearScrollHighlight()
        guard let textStorage, range.length > 0, NSMaxRange(range) <= textStorage.length else { return }
        textStorage.addAttribute(.backgroundColor, value: NSColor.findHighlightColor, range: range)
        scrollHighlightRange = range
        let reset = DispatchWorkItem { [weak self] in self?.clearScrollHighlight() }
        scrollHighlightReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reset)
    }

    private func clearScrollHighlight() {
        scrollHighlightReset?.cancel()
        scrollHighlightReset = nil
        guard let range = scrollHighlightRange else { return }
        scrollHighlightRange = nil
        guard let textStorage, NSMaxRange(range) <= textStorage.length else { return }
        textStorage.removeAttribute(.backgroundColor, range: range)
    }

    @objc private func copyHoveredCodeBlock() {
        guard let hoveredCodeBlockRange,
              let textStorage,
              NSMaxRange(hoveredCodeBlockRange) <= textStorage.length else { return }
        let blockText = (textStorage.string as NSString).substring(with: hoveredCodeBlockRange)
        guard let firstLineBreak = blockText.firstIndex(of: "\n") else { return }
        let code = String(blockText[blockText.index(after: firstLineBreak)...])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        showCopySuccessFeedback()
    }

    private func showCopySuccessFeedback() {
        copyFeedbackReset?.cancel()
        copyCodeButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        copyCodeButton.contentTintColor = .systemGreen

        let reset = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copyCodeButton.image = NSImage(
                systemSymbolName: "doc.on.doc",
                accessibilityDescription: nil
            )
            self.copyCodeButton.contentTintColor = .secondaryLabelColor
        }
        copyFeedbackReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: reset)
    }

    private func updateCopyButtonFrame() {
        guard let hoveredCodeBlockRange,
              let blockFrame = codeBlockFrame(for: hoveredCodeBlockRange) else { return }
        copyCodeButton.frame = NSRect(
            x: blockFrame.maxX - 32,
            y: blockFrame.minY + 5,
            width: 24,
            height: 24
        )
    }

    /// 按实际字形绘制行内代码背景，使文字垂直居中并保留紧凑的左右内边距。
    private func drawInlineCodeBackgrounds(in dirtyRect: NSRect) {
        guard let textStorage,
              let layoutManager,
              let textContainer,
              textStorage.length > 0 else { return }

        let origin = textContainerOrigin
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.markdownInlineCodeBackground, in: fullRange) { value, characterRange, _ in
            guard let backgroundColor = value as? NSColor, characterRange.length > 0 else { return }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return }

            let font = (textStorage.attribute(.font, at: characterRange.location, effectiveRange: nil) as? NSFont)
                ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let backgroundHeight = ceil(font.ascender - font.descender + 4)

            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
                let fragmentGlyphRange = NSIntersectionRange(glyphRange, lineGlyphRange)
                guard fragmentGlyphRange.length > 0 else { return }
                let glyphRect = layoutManager.boundingRect(
                    forGlyphRange: fragmentGlyphRange,
                    in: textContainer
                )
                let backgroundRect = NSRect(
                    x: origin.x + glyphRect.minX - 3,
                    // 行片段包含行距与段距，背景应跟随字形基线而非整行中心。
                    y: origin.y + lineRect.minY
                        + layoutManager.location(forGlyphAt: fragmentGlyphRange.location).y
                        - font.ascender - 2,
                    width: glyphRect.width + 6,
                    height: backgroundHeight
                )
                guard backgroundRect.intersects(dirtyRect) else { return }

                backgroundColor.setFill()
                NSBezierPath(
                    roundedRect: backgroundRect,
                    xRadius: 4,
                    yRadius: 4
                ).fill()
            }
        }
    }

    /// NSTextView 原生绘制圆角描边，绕过 HTML 导入器不支持 border-radius 的限制。
    private func drawCodeBlockFrames(in dirtyRect: NSRect) {
        for (_, frame) in codeBlockRangesAndFrames() {
            guard frame.intersects(dirtyRect) else { continue }

            NSGraphicsContext.saveGraphicsState()
            NSColor.separatorColor.setStroke()
            let path = NSBezierPath(roundedRect: frame, xRadius: 9, yRadius: 9)
            path.lineWidth = 1
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func codeBlockRangesAndFrames() -> [(range: NSRange, frame: NSRect)] {
        guard let textStorage, textStorage.length > 0 else { return [] }
        var result: [(range: NSRange, frame: NSRect)] = []
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.enumerateAttribute(.markdownCodeBlockLanguage, in: fullRange) { value, range, _ in
            guard value is String, let frame = self.codeBlockFrame(for: range) else { return }
            result.append((range, frame))
        }
        return result
    }

    private func codeBlockFrame(for characterRange: NSRange) -> NSRect? {
        guard let layoutManager, characterRange.length > 0 else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }

        var minimumY = CGFloat.greatestFiniteMagnitude
        var maximumY = -CGFloat.greatestFiniteMagnitude
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
            minimumY = min(minimumY, rect.minY)
            maximumY = max(maximumY, rect.maxY)
        }
        guard minimumY.isFinite, maximumY.isFinite else { return nil }

        let origin = textContainerOrigin
        return NSRect(
            x: origin.x + 0.5,
            y: origin.y + minimumY - 6.5,
            width: max(0, bounds.width - origin.x * 2 - 1),
            height: maximumY - minimumY + 14
        )
    }
}

struct MarkdownTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    @Binding var calculatedHeight: CGFloat
    var scrollRequest: MarkdownScrollRequest?
    /// 滚动时回传两个字符位置：可视区顶部，以及再往上 `headingSettleDistance` 处的位置。
    /// 目录向下切换需要后者也越过标题，避免标题刚滚过顶部就频繁切换。
    var onVisibleLocationChange: (_ location: Int, _ settledLocation: Int) -> Void = { _, _ in }
    /// 向下滚动时，标题需要再滚过顶部这么多点才切换为当前节。
    static let headingSettleDistance: CGFloat = 40
    private let documentPadding: CGFloat = 24

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let contentSize = scrollView.contentSize

        let textView = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height))
        textView.minSize = NSSize(width: 0.0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        // 文档留白随内容滚动；窗口缩放热区由外层布局单独预留。
        textView.textContainerInset = NSSize(width: documentPadding, height: documentPadding)

        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.documentView = textView
        context.coordinator.observeScroll(of: scrollView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let textView = nsView.documentView as? MarkdownNSTextView {
            // 目录滚动等无关刷新不应重建文本存储；只有渲染结果变化（新对象）时才替换。
            if context.coordinator.appliedText !== attributedText {
                context.coordinator.appliedText = attributedText
                // 颜色语义化已在 AppState 渲染阶段完成，这里直接替换文本存储，避免每次更新全量复制与枚举。
                textView.layoutManager?.replaceTextStorage(NSTextStorage(attributedString: attributedText))
                textView.collectTableCells()
                textView.updateTableColumnWidths()
                textView.resetCodeBlockHover()
                // 替换后同步一次目录位置；放到下一轮主循环，避免在视图更新中修改外部状态。
                DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                    coordinator?.reportVisibleLocation(nsView)
                }
            }
            context.coordinator.updateHeight(nsView)

            if let scrollRequest, scrollRequest.id != context.coordinator.handledScrollRequestID {
                context.coordinator.handledScrollRequestID = scrollRequest.id
                scrollToTop(ofCharacterAt: scrollRequest.location, in: nsView, textView: textView)
            }
        }
    }

    /// 把标题滚动到可视区顶部并高亮整段标题；位置由布局管理器计算，与 documentPadding 的内边距保持一致。
    private func scrollToTop(ofCharacterAt location: Int, in scrollView: NSScrollView, textView: MarkdownNSTextView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let length = textView.textStorage?.length,
              location < length else { return }
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: location, length: 1),
            actualCharacterRange: nil
        )
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        // 标题略低于顶边（4 点），保证目录的顶部探测点仍落在该标题内，不会误判为上一节。
        let y = max(0, rect.minY + textView.textContainerOrigin.y - 4)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        var headingRange = NSRange(location: location, length: 0)
        if textView.textStorage?.attribute(.markdownHeadingLevel, at: location, effectiveRange: &headingRange) != nil {
            textView.flashScrollHighlight(headingRange)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: MarkdownTextView
        /// 已执行过的目录滚动请求；updateNSView 每次刷新都会调用，避免重复滚动。
        var handledScrollRequestID: UInt64 = 0
        /// 当前已写入文本存储的富文本；与 AppState 的渲染结果做身份比较。
        var appliedText: NSAttributedString?
        private var scrollObserver: NSObjectProtocol?

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        func observeScroll(of scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                // 目录跳转会在视图更新中触发滚动；异步回传，避免在视图更新期间修改 AppState。
                DispatchQueue.main.async { [weak self, weak scrollView] in
                    guard let self, let scrollView else { return }
                    self.reportVisibleLocation(scrollView)
                }
            }
        }

        /// 取可视区顶部附近的字符位置（略低于边缘，避免顶边恰好落在上一节末尾），并附带更靠上的“已越过”位置。
        func reportVisibleLocation(_ scrollView: NSScrollView) {
            guard let textView = scrollView.documentView as? NSTextView else { return }
            let x = textView.textContainerOrigin.x + 1
            let top = scrollView.contentView.bounds.minY + 8
            let settledTop = max(0, top - MarkdownTextView.headingSettleDistance)
            parent.onVisibleLocationChange(
                textView.characterIndexForInsertion(at: NSPoint(x: x, y: top)),
                textView.characterIndexForInsertion(at: NSPoint(x: x, y: settledTop))
            )
        }

        func updateHeight(_ scrollView: NSScrollView) {
            guard let textView = scrollView.documentView as? NSTextView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let neededHeight = usedRect.height + textView.textContainerInset.height * 2

            DispatchQueue.main.async {
                if self.parent.calculatedHeight != neededHeight {
                    self.parent.calculatedHeight = neededHeight
                }
            }
        }
    }
}
