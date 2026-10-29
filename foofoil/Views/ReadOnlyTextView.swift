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

struct ReadOnlyTextNSView: NSViewRepresentable, Equatable {
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

        // TextKit 2 按段落绘制布局片段，超长单行软换行后会在滚动时重绘大量屏外文字。
        // 纯文本使用 TextKit 1 的可见行绘制；代码行号栏仍依赖 TextKit 2 的片段定位。
        let textView = NSTextView(usingTextLayoutManager: codeLineNumbersVisible != nil)
        textView.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height)
        textView.minSize = NSSize(width: 0.0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        // 文档主题已提供亮暗配色，禁止 TextKit 再映射一次而把浅色文字反转成黑色。
        textView.usesAdaptiveColorMappingForDarkAppearance = false
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
        context.coordinator.update(nsView, configuration: self)
    }

    final class Coordinator {
        weak var ruler: CodeLineNumberRulerView?
        private var indexedText: String?
        private var indexGeneration = 0
        private var appliedConfiguration: ReadOnlyTextNSView?

        func update(_ scrollView: NSScrollView, configuration: ReadOnlyTextNSView) {
            // 缓存 Swift 字符串及样式；悬停等无关刷新不能桥接、比较或遍历原生全文。
            guard appliedConfiguration != configuration,
                  let textView = scrollView.documentView as? NSTextView else { return }
            let textChanged = appliedConfiguration?.text != configuration.text
            let spacingChanged = appliedConfiguration?.lineHeightMultiple != configuration.lineHeightMultiple
                || appliedConfiguration?.paragraphSpacingMultiple != configuration.paragraphSpacingMultiple
                || appliedConfiguration?.font.pointSize != configuration.font.pointSize
            if textChanged {
                textView.string = configuration.text
            }
            if let visible = configuration.codeLineNumbersVisible {
                scrollView.rulersVisible = visible
                updateLineNumbers(for: configuration.text)
            }
            if textView.font?.fontName != configuration.font.fontName
                || textView.font?.pointSize != configuration.font.pointSize {
                textView.font = configuration.font
            }
            let resolvedTextColor = configuration.textColor ?? .labelColor
            if textChanged || textView.textColor?.isEqual(resolvedTextColor) != true {
                textView.textColor = resolvedTextColor
            }
            // 新正文需要补齐段落属性；只改颜色或行号时不扫描全文。
            if textChanged || spacingChanged {
                DocumentTextSpacing.apply(
                    to: textView,
                    lineHeightMultiple: configuration.lineHeightMultiple,
                    paragraphSpacingMultiple: configuration.paragraphSpacingMultiple,
                    fontSize: configuration.font.pointSize
                )
            }
            ruler?.refresh()
            appliedConfiguration = configuration
        }

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
