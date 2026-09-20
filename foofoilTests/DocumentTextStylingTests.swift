//  DocumentTextStylingTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/18.
//

import AppKit
import CoreText
import SwiftUI
import Testing
@testable import foofoil

/// 无排版文档（纯文本/笔记、Markdown）的文字颜色与字体选择。
@MainActor
@Suite(.serialized)
struct DocumentTextStylingTests {
    /// Markdown 预览把自选的文字颜色与字体写进渲染结果（标题与正文一起跟随）。
    @Test func markdownPreviewUsesCustomTextColorAndFont() async throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        // 先设样式再打开预览：打开预览时才渲染一次，渲染结果必定是自选样式。
        state.originalImageName = "notes.md"
        state.text = "# 标题\n\n正文段落"
        state.textColorHex = "#123456"
        state.documentFontName = "Menlo-Regular"
        state.isMarkdownPreview = true

        let rendered = await waitForRenderedMarkdown(state)
        try #require(rendered.length > 0, "Markdown 未完成渲染")

        let custom = try #require(NSColor(hex: "#123456"))
        let body = try attributes(of: rendered, at: "正文段落")
        #expect(isClose(body.color, custom), "正文未使用自选文字颜色：\(body.color)")
        #expect(body.font.isFixedPitch, "正文未使用自选等宽字体：\(body.font.fontName)")

        let heading = try attributes(of: rendered, at: "标题")
        #expect(isClose(heading.color, custom), "标题未跟随自选文字颜色：\(heading.color)")
    }

    /// 未自选时 Markdown 预览保持原有主题配色与系统字体。
    @Test func markdownPreviewKeepsThemeDefaultsWithoutCustomStyling() async throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        state.originalImageName = "notes.md"
        state.text = "# 标题\n\n正文段落"
        state.isMarkdownPreview = true

        let rendered = await waitForRenderedMarkdown(state)
        try #require(rendered.length > 0, "Markdown 未完成渲染")

        let custom = try #require(NSColor(hex: "#123456"))
        let body = try attributes(of: rendered, at: "正文段落")
        #expect(!isClose(body.color, custom), "未自选颜色却出现了自选色：\(body.color)")
        #expect(!body.font.isFixedPitch, "未自选字体却用了等宽字体：\(body.font.fontName)")
    }

    /// 面板选中的字体名要真的落到渲染与注入上。
    @Test func catalogResolvesChosenFont() throws {
        let size: CGFloat = 16
        let chosen = DocumentFontCatalog.font(named: "Menlo-Regular", size: size)
        #expect(chosen.pointSize == size)
        #expect(chosen.isFixedPitch, "选中的等宽字体未生效：\(chosen.fontName)")

        // 未选择或名字无效时回退到通道默认（圆体系统字体）。
        let fallback = DocumentFontCatalog.font(named: nil, size: size)
        #expect(fallback.familyName == DocumentFontCatalog.defaultFont(size: size).familyName)
        let invalid = DocumentFontCatalog.font(named: "不存在的字体名", size: size)
        #expect(invalid.familyName == fallback.familyName)

        #expect(DocumentFontCatalog.cssFontFamily(named: "Menlo-Regular")?.contains("Menlo") == true)
        #expect(DocumentFontCatalog.cssFontFamily(named: nil) == nil)
    }

    /// 字体目录给出系统字族，并能按「覆盖汉字」筛出中文字体。
    @Test func catalogEnumeratesFamiliesAndFiltersChinese() async throws {
        let catalog = await DocumentFontCatalog.load()
        #expect(catalog.families.count > 20, "字族列表过少：\(catalog.families.count)")
        #expect(catalog.families.contains { $0.members.isEmpty } == false, "存在没有字型的字族")
        #expect(catalog.families.allSatisfy { !$0.displayName.isEmpty }, "存在空的字体显示名")

        let chinese = catalog.families(chineseOnly: true)
        #expect(!chinese.isEmpty, "没有筛出中文字体")
        #expect(chinese.count < catalog.families.count, "中文字体筛选没有生效")
        // 系统语言含中文时，带中文本地化的中文字体显示中文名，而不是英文字族名。
        let prefersChinese = Locale.preferredLanguages.contains { $0.hasPrefix("zh") }
        for family in chinese.prefix(5) {
            let font = try #require(NSFont(name: family.members[0].postScriptName, size: 12))
            var characters: [UniChar] = Array("汉字".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            #expect(CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count))
            #expect(glyphs.allSatisfy { $0 != 0 }, "\(family.name) 不含汉字字形")

            if prefersChinese, family.displayName != family.name {
                let hasHan = family.displayName.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                #expect(hasHan, "\(family.name) 的显示名不是中文：\(family.displayName)")
            }
        }
    }

    /// 视图层接线：预览已经开着的箔上改文字颜色，屏幕上的预览会按新颜色重渲染。
    @Test func markdownPreviewRerendersWhenTextColorChanges() async throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        state.originalImageName = "notes.md"
        state.text = "正文段落"
        state.textColorHex = "#123456"
        state.isMarkdownPreview = true

        // 真实视图负责把「颜色变了」转成重渲染；关掉视图这条链路就不存在。
        let hosting = NSHostingView(rootView: TextEditorModeView(appState: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        hosting.layoutSubtreeIfNeeded()
        #expect(await waitForRenderedColor(state, "#123456"), "预览未按自选颜色渲染")

        state.textColorHex = "#00AA00"
        #expect(await waitForRenderedColor(state, "#00AA00"), "改色后预览未重渲染")
    }

    /// 轮询渲染结果的正文颜色；既跑 runloop 让 SwiftUI 派发 onChange，也等待后台渲染任务。
    private func waitForRenderedColor(_ state: AppState, _ hex: String) async -> Bool {
        guard let expected = NSColor(hex: hex) else { return false }
        for _ in 0..<300 {
            if state.renderedMarkdown.length > 0,
               let color = state.renderedMarkdown.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
               isClose(color, expected) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// 等待后台 Markdown 渲染完成；超时返回当前（可能为空的）结果，由断言给出失败信息。
    private func waitForRenderedMarkdown(_ state: AppState) async -> NSAttributedString {
        var attempts = 0
        while state.renderedMarkdown.length == 0 && attempts < 300 {
            try? await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        return state.renderedMarkdown
    }

    /// 取某段文字的首个字符属性：渲染结果里该段文字使用的颜色与字体。
    private func attributes(of rendered: NSAttributedString, at needle: String) throws -> (color: NSColor, font: NSFont) {
        let range = (rendered.string as NSString).range(of: needle)
        try #require(range.location != NSNotFound, "渲染结果缺少文本「\(needle)」")
        let color = try #require(
            rendered.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor,
            "「\(needle)」缺少文字颜色"
        )
        let font = try #require(
            rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont,
            "「\(needle)」缺少字体"
        )
        return (color, font)
    }

    /// 按 8 位 sRGB 分量比较颜色，容忍 HTML 导入与颜色空间转换产生的 ±2 误差。
    private func isClose(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let a = lhs.usingColorSpace(.sRGB), let b = rhs.usingColorSpace(.sRGB) else { return false }
        func byte(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
        return abs(byte(a.redComponent) - byte(b.redComponent)) <= 2
            && abs(byte(a.greenComponent) - byte(b.greenComponent)) <= 2
            && abs(byte(a.blueComponent) - byte(b.blueComponent)) <= 2
    }
}
