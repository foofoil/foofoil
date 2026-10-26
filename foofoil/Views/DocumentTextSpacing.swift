//
//  DocumentTextSpacing.swift
//  foofoil
//
//  Created by tolg on 2026/7/10.
//

import SwiftUI
import AppKit

/// 箔自选的行距/段距 → 原生段落样式；只读文本通道共用。
enum DocumentTextSpacing {
    /// 把行距/段距落到 NSTextView：默认段落样式让新输入跟随，文本存储让已有内容跟随，
    /// 布局管理器据此计算行高，自动高度也跟着对。未自选时为 0，即 NSTextView 的默认排版。
    static func apply(
        to textView: NSTextView,
        lineHeightMultiple: Double?,
        paragraphSpacingMultiple: Double?,
        fontSize: CGFloat
    ) {
        let targetLineHeightMultiple = lineHeightMultiple ?? 0
        // 段距是相对字号的倍数，原生以点为单位。
        let targetParagraphSpacing = paragraphSpacingMultiple.map { $0 * fontSize } ?? 0

        // 只在数值变化时重设，避免每次更新都重置输入属性（影响输入法与撤销）。
        if let current = textView.defaultParagraphStyle {
            if current.lineHeightMultiple != targetLineHeightMultiple || current.paragraphSpacing != targetParagraphSpacing {
                let style = (current.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                style.lineHeightMultiple = targetLineHeightMultiple
                style.paragraphSpacing = targetParagraphSpacing
                textView.defaultParagraphStyle = style
            }
        } else if targetLineHeightMultiple != 0 || targetParagraphSpacing != 0 {
            let style = NSMutableParagraphStyle()
            style.lineHeightMultiple = targetLineHeightMultiple
            style.paragraphSpacing = targetParagraphSpacing
            textView.defaultParagraphStyle = style
        }

        // 已有文本不会因为默认段落样式而改变，需要显式覆盖；取消自选时同样靠这里归零。
        guard let textStorage = textView.textStorage, textStorage.length > 0 else { return }
        var updates: [(range: NSRange, style: NSMutableParagraphStyle)] = []
        textStorage.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: textStorage.length)
        ) { value, range, _ in
            let current = (value as? NSParagraphStyle) ?? NSParagraphStyle.default
            guard current.lineHeightMultiple != targetLineHeightMultiple
                || current.paragraphSpacing != targetParagraphSpacing else { return }
            let style = (current.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.lineHeightMultiple = targetLineHeightMultiple
            style.paragraphSpacing = targetParagraphSpacing
            updates.append((range, style))
        }
        for update in updates {
            textStorage.addAttribute(.paragraphStyle, value: update.style, range: update.range)
        }
    }
}

