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

    var body: some View {
        ReadOnlyTextNSView(
            text: text,
            font: font,
            textColor: textColor,
            lineHeightMultiple: lineHeightMultiple,
            paragraphSpacingMultiple: paragraphSpacingMultiple
        )
    }
}

struct ReadOnlyTextNSView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor?
    let lineHeightMultiple: Double?
    let paragraphSpacingMultiple: Double?
    // 与 Markdown 预览一致的文档内边距，保证滚动条贴边且首尾留白随内容滚动。
    private let documentPadding: CGFloat = 24

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
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView {
            if textView.string != text {
                textView.string = text
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
        }
    }
}
