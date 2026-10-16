//
//  ReadOnlyTextView.swift
//  foofoil
//
//  Created by tolg on 2026/7/13.
//

import SwiftUI
import AppKit

struct ReadOnlyTextView: View {
    let text: String
    let font: NSFont
    let textColor: NSColor?
    let lineHeightMultiple: Double?
    let paragraphSpacingMultiple: Double?
    /// 已识别语言的代码文件才传入：nil 表示普通文本，不创建行号栏；布尔值表示行号是否可见。
    var codeLineNumbersVisible: Bool? = nil

    var body: some View {
        ReadOnlyTextNSView(
            text: text,
            font: font,
            textColor: textColor,
            lineHeightMultiple: lineHeightMultiple,
            paragraphSpacingMultiple: paragraphSpacingMultiple,
            codeLineNumbersVisible: codeLineNumbersVisible
        )
    }
}

struct ReadOnlyTextNSView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor?
    let lineHeightMultiple: Double?
    let paragraphSpacingMultiple: Double?
    let codeLineNumbersVisible: Bool?
    // 与 Markdown 预览一致的文档内边距，保证滚动条贴边且首尾留白随内容滚动。
    private let documentPadding: CGFloat = 24

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let contentSize = scrollView.contentSize

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height))
        textView.minSize = NSSize(width: 0.0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = false // 只读
        textView.isSelectable = true // 可选择

        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        // 字体、文字颜色、行距/段距由箔的文档样式决定；未自选颜色时跟随系统外观
        textView.font = font
        textView.textColor = textColor ?? .labelColor
        DocumentTextSpacing.apply(
            to: textView,
            lineHeightMultiple: lineHeightMultiple,
            paragraphSpacingMultiple: paragraphSpacingMultiple,
            fontSize: font.pointSize
        )

        // 留白属于可滚动文档，让滚动条贴近窗口边缘，首尾留白随内容一起滚动。
        textView.textContainerInset = NSSize(width: documentPadding, height: documentPadding)

        scrollView.documentView = textView
        if codeLineNumbersVisible != nil {
            let ruler = CodeLineNumberRulerView(scrollView: scrollView, textView: textView)
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            context.coordinator.ruler = ruler
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView {
            if textView.string != text {
                textView.string = text
            }
            if let codeLineNumbersVisible {
                nsView.rulersVisible = codeLineNumbersVisible
                context.coordinator.updateLineNumbers(for: text)
            }
            // 仅在字体或颜色变化时重设，避免每次更新都重置输入属性（影响输入法与撤销）
            if textView.font?.fontName != font.fontName || textView.font?.pointSize != font.pointSize {
                textView.font = font
            }
            let resolvedTextColor = textColor ?? .labelColor
            if textView.textColor?.isEqual(resolvedTextColor) != true {
                textView.textColor = resolvedTextColor
            }
            DocumentTextSpacing.apply(
                to: textView,
                lineHeightMultiple: lineHeightMultiple,
                paragraphSpacingMultiple: paragraphSpacingMultiple,
                fontSize: font.pointSize
            )
            context.coordinator.ruler?.refresh()
        }
    }

    final class Coordinator {
        weak var ruler: CodeLineNumberRulerView?
        private var indexedText: String?
        private var indexGeneration = 0

        /// 行起点索引在后台计算；结果未就绪前行号栏为空，文本照常显示。
        func updateLineNumbers(for text: String) {
            guard ruler != nil, indexedText != text else { return }
            indexedText = text
            indexGeneration += 1
            let generation = indexGeneration
            Task { @MainActor [weak self] in
                let starts = await Task.detached(priority: .utility) {
                    CodeLineNumberRulerView.lineStarts(in: text)
                }.value
                guard let self, generation == self.indexGeneration else { return }
                self.ruler?.setLineStarts(starts)
            }
        }
    }
}
