//  AppState+DocumentStyling.swift
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

    /// 无排版文档内容：纯文本/笔记、Markdown，以及电子书等扩展文档。
    /// 它们由宿主排版，可单独选择文字颜色与字体；PDF 自带版式，CSV 是表格，网页有站点自己的排版。
    public var supportsDocumentTextStyling: Bool {
        if isPDFDocument || isCSVDocument { return false }
        if webURL != nil { return false }
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

    /// 无排版文档的文字颜色（十六进制）；未选择或不是文档内容时为 nil，文字跟随系统外观。
    var documentTextColorHex: String? {
        supportsDocumentTextStyling ? textColorHex : nil
    }

    /// 无排版文档的文字颜色。
    var documentTextColor: NSColor? {
        documentTextColorHex.flatMap(NSColor.init(hex:))
    }

    /// 无排版文档使用的字体名（PostScript）；非该类型内容为 nil。
    var documentStylingFontName: String? {
        supportsDocumentTextStyling ? documentFontName : nil
    }

    /// 文本通道（AppKit）使用的字体；未自选或不是文档内容时回退通道默认字体。
    func documentFont(size: CGFloat) -> NSFont {
        DocumentFontCatalog.font(named: documentStylingFontName, size: size)
    }

    /// 文档内容注入网页（扩展文档）时使用的字体；未自选字体时返回 nil，不覆盖文档自身排版。
    var documentFontFamily: String? {
        DocumentFontCatalog.cssFontFamily(named: documentStylingFontName)
    }

    /// 行间距倍数；为空表示沿用通道默认行高。
    var documentLineHeightMultiple: Double? {
        supportsDocumentTextStyling ? documentLineSpacing : nil
    }

    /// 段落间距倍数（相对字号）；为空表示沿用通道默认段距。
    var documentParagraphSpacingMultiple: Double? {
        supportsDocumentTextStyling ? documentParagraphSpacing : nil
    }

    /// 系统明暗切换后，把与目标主题明显不符的自选颜色换成同色相的深浅版本：
    /// 背景色要配合当前主题（深色主题配深色背景），文字颜色相反（深色主题配浅色文字），
    /// 让内容始终可读；中间色与已相符的颜色保持不变。
    func adaptDocumentColorsToAppearanceChange(toDarkAppearance isDark: Bool) {
        if let adapted = mirroredHex(contentBackgroundHex, forDarkAppearance: isDark) {
            backgroundColorHex = adapted
        }
        if let adapted = mirroredHex(documentTextColorHex, forDarkAppearance: !isDark) {
            textColorHex = adapted
        }
    }

    /// 颜色与目标主题明显不符时返回镜像色的十六进制值，否则返回 nil（不写回，避免多余的历史落盘）。
    private func mirroredHex(_ currentHex: String?, forDarkAppearance isDark: Bool) -> String? {
        guard let hex = currentHex,
              let color = NSColor(hex: hex),
              let adapted = DocumentColorAdapter.adaptedColor(color, forDarkAppearance: isDark),
              let adaptedHex = adapted.toHex(),
              adaptedHex != hex else { return nil }
        return adaptedHex
    }
}
