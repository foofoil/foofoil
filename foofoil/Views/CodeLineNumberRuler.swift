//
//  CodeLineNumberRuler.swift
//  foofoil
//

import AppKit

/// 只读代码文件的原生行号栏：只在逻辑行起点绘制编号，软换行的续行不重复编号。
/// 通过 TextKit 2 的布局片段定位，不访问 layoutManager，避免文本视图切换到兼容模式。
final class CodeLineNumberRulerView: NSRulerView {
    private static let horizontalPadding: CGFloat = 8

    /// 逻辑行起点的 UTF-16 偏移，已排序；为空表示索引尚未就绪，此时只显示文本。
    private var lineStarts: [Int] = []

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Self.horizontalPadding * 2
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 与 NSTextView 的换行规则一致：\r\n、\r、\n 各算一次换行，末尾换行之后的空行同样编号。
    nonisolated static func lineStarts(in text: String) -> [Int] {
        var starts = [0]
        var previous: UInt16 = 0
        var index = 0
        for unit in text.utf16 {
            if previous == 13 && unit != 10 {
                starts.append(index)
            }
            if unit == 10 {
                starts.append(index + 1)
            }
            previous = unit
            index += 1
        }
        if previous == 13 {
            starts.append(index)
        }
        return starts
    }

    func setLineStarts(_ starts: [Int]) {
        lineStarts = starts
        refresh()
    }

    /// 字体或索引变化后重新计算栏宽并重绘。
    func refresh() {
        let digits = max(String(max(lineStarts.count, 1)).count, 2)
        let sample = "9" as NSString
        let width = sample.size(withAttributes: numberAttributes()).width
        let thickness = ceil(width * CGFloat(digits)) + Self.horizontalPadding * 2
        if ruleThickness != thickness {
            ruleThickness = thickness
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard !lineStarts.isEmpty,
              let textView = clientView as? NSTextView,
              let textLayoutManager = textView.textLayoutManager,
              let contentManager = textLayoutManager.textContentManager else { return }

        let attributes = numberAttributes()
        let visibleRect = scrollView?.documentVisibleRect ?? textView.visibleRect
        let origin = textLayoutManager.documentRange.location
        let startLocation = textLayoutManager.textViewportLayoutController.viewportRange?.location ?? origin
        let containerOrigin = textView.textContainerOrigin

        textLayoutManager.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let documentY = frame.minY + containerOrigin.y
            if documentY > visibleRect.maxY { return false }
            if documentY + frame.height < visibleRect.minY { return true }

            let offset = contentManager.offset(from: origin, to: fragment.rangeInElement.location)
            guard self.isLineStart(offset) else { return true }
            let number = self.lineNumber(forOffset: offset) as NSString
            let size = number.size(withAttributes: attributes)
            let y = self.convert(NSPoint(x: 0, y: documentY), from: textView).y
            let x = self.ruleThickness - Self.horizontalPadding - size.width
            number.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            return true
        }
    }

    private func numberAttributes() -> [NSAttributedString.Key: Any] {
        let font = (clientView as? NSTextView)?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
    }

    private func isLineStart(_ offset: Int) -> Bool {
        var low = 0
        var high = lineStarts.count - 1
        while low <= high {
            let middle = (low + high) >> 1
            if lineStarts[middle] == offset { return true }
            if lineStarts[middle] < offset {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return false
    }

    /// 行号即该偏移在索引中的位置加一；偏移必须是逻辑行起点。
    private func lineNumber(forOffset offset: Int) -> String {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) >> 1
            if lineStarts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return String(low + 1)
    }
}
