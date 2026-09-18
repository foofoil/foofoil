//  AppState+ContentBackground.swift
//  foofoil
//
//  Created by tolg on 2026/9/18.
//

import AppKit

extension AppState {
    /// 文档箔：内容是一份可读文档，可为其选择内容背景色
    /// （纯文本/笔记、Markdown、CSV、PDF、网页，以及电子书等扩展文档）。
    /// 图片、视频、音频以自身画面为内容，窗口只作画框，不提供背景色设置。
    public var supportsContentBackgroundColor: Bool {
        // PDF 复用图片内容通道，但内容是一页页纸张，仍按文档处理。
        if isPDFDocument { return true }
        if webURL != nil { return true }
        if extensionSession != nil { return isExtensionDocument }
        return imageURL == nil
    }

    /// 文档内容背景色（十六进制）；非文档箔为 nil，避免把整窗外观当成背景作用对象。
    var contentBackgroundHex: String? {
        supportsContentBackgroundColor ? backgroundColorHex : nil
    }

    /// 文档内容背景色；为空时内容沿用窗口毛玻璃外观。
    var contentBackgroundColor: NSColor? {
        contentBackgroundHex.flatMap(NSColor.init(hex:))
    }

    /// 系统明暗切换后，把与目标主题明显不符的自选背景色换成同色相的深浅版本，
    /// 让内容文字（跟随系统外观）始终落在可读的背景上；中间色与已相符的颜色保持不变。
    func adaptContentBackgroundColor(toDarkAppearance isDark: Bool) {
        guard let hex = contentBackgroundHex,
              let color = NSColor(hex: hex),
              let adapted = DocumentBackgroundColorAdapter.adaptedColor(color, forDarkAppearance: isDark),
              let adaptedHex = adapted.toHex(),
              adaptedHex != hex else { return }
        backgroundColorHex = adaptedHex
    }
}
