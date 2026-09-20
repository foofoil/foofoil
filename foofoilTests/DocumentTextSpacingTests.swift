//  DocumentTextSpacingTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/20.
//

import AppKit
import SwiftUI
import Testing
@testable import foofoil

/// 无排版文档（纯文本/笔记、Markdown）的行距与段距。
@MainActor
@Suite(.serialized)
struct DocumentTextSpacingTests {
    /// Markdown 预览把自选字体与行距/段距写进渲染结果。
    @Test func markdownPreviewUsesCustomFontAndSpacing() async throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        state.originalImageName = "notes.md"
        state.text = "正文段落\n\n第二段"
        state.documentFontName = "Menlo-Regular"
        state.documentLineSpacing = 2.0
        state.documentParagraphSpacing = 1.0
        state.isMarkdownPreview = true

        let rendered = await waitForRenderedMarkdown(state)
        let range = try range(of: "正文段落", in: rendered)

        let font = try #require(
            rendered.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont,
            "正文缺少字体"
        )
        #expect(font.isFixedPitch, "正文未使用自选等宽字体：\(font.fontName)")

        let style = try #require(paragraphStyle(of: rendered, at: range.location), "正文缺少段落样式")
        #expect(abs(style.lineHeightMultiple - 2.0) < 0.001, "正文行距未跟随自选值：\(style.lineHeightMultiple)")
        #expect(
            abs(style.paragraphSpacing - state.textFontSize) < 0.001,
            "正文段距未按字号倍数生效：\(style.paragraphSpacing)"
        )
    }

    /// 未自选时 Markdown 预览保持通道默认的行高与段距。
    @Test func markdownPreviewKeepsDefaultSpacingWithoutCustomValues() async throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        state.originalImageName = "notes.md"
        state.text = "正文段落\n\n第二段"
        state.isMarkdownPreview = true

        let rendered = await waitForRenderedMarkdown(state)
        let range = try range(of: "正文段落", in: rendered)

        let style = try #require(paragraphStyle(of: rendered, at: range.location), "正文缺少段落样式")
        #expect(style.lineHeightMultiple != 2.0, "未自选却出现自选行距：\(style.lineHeightMultiple)")
        #expect(
            style.paragraphSpacing != state.textFontSize,
            "未自选却出现自选段距：\(style.paragraphSpacing)"
        )
        // 通道默认：正文行高 1.42 倍，段距取 p 的默认下边距 0.8em。
        #expect(abs(style.lineHeightMultiple - 1.42) < 0.001, "正文默认行高变了：\(style.lineHeightMultiple)")
        #expect(
            abs(style.paragraphSpacing - state.textFontSize * 0.8) < 0.05,
            "正文默认段距变了：\(style.paragraphSpacing)"
        )
    }

    /// 编辑通道：宿主视图把自选行距/段距落到 NSTextView 的默认段落样式上，取消后又回到默认。
    @Test func editableTextViewAppliesCustomSpacing() async throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        state.text = "正文段落"

        let hosting = NSHostingView(rootView: TextEditorModeView(appState: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        hosting.layoutSubtreeIfNeeded()
        let textView = try #require(firstTextView(in: hosting), "编辑器未生成 NSTextView")

        // 未自选时不写入任何行距/段距，保持 NSTextView 自身默认。
        #expect((textView.defaultParagraphStyle?.lineHeightMultiple ?? 0) == 0)
        #expect((textView.defaultParagraphStyle?.paragraphSpacing ?? 0) == 0)

        state.documentLineSpacing = 1.8
        state.documentParagraphSpacing = 1.5
        let styled = try #require(
            await waitForDefaultParagraphStyle(textView, lineHeightMultiple: 1.8),
            "改行距后编辑器未更新段落样式"
        )
        #expect(abs(styled.lineHeightMultiple - 1.8) < 0.001, "行距未生效：\(styled.lineHeightMultiple)")
        #expect(
            abs(styled.paragraphSpacing - state.textFontSize * 1.5) < 0.001,
            "段距未按字号倍数生效：\(styled.paragraphSpacing)"
        )
        // 已有文本也要跟随，否则只有新输入的行距会变。
        let stored = try #require(
            textView.textStorage?.attribute(
                .paragraphStyle,
                at: max(0, (textView.textStorage?.length ?? 1) - 1),
                effectiveRange: nil
            ) as? NSParagraphStyle,
            "已有文本未带上段落样式"
        )
        #expect(abs(stored.lineHeightMultiple - 1.8) < 0.001, "已有文本的行距未生效：\(stored.lineHeightMultiple)")

        state.documentLineSpacing = nil
        state.documentParagraphSpacing = nil
        let restored = try #require(
            await waitForDefaultParagraphStyle(textView, lineHeightMultiple: 0),
            "取消自选后编辑器未回到默认行距"
        )
        #expect(restored.paragraphSpacing == 0, "取消自选后仍残留段距：\(restored.paragraphSpacing)")
    }

    /// 视图层接线：预览已经开着的箔上改行距/段距，屏幕上的预览会按新值重渲染。
    @Test func markdownPreviewRerendersWhenSpacingChanges() async throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        state.originalImageName = "notes.md"
        state.text = "正文段落"
        state.isMarkdownPreview = true

        // 真实视图负责把「行距变了」转成重渲染；关掉视图这条链路就不存在。
        let hosting = NSHostingView(rootView: TextEditorModeView(appState: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        hosting.layoutSubtreeIfNeeded()
        #expect(await waitForRenderedMarkdown(state).length > 0, "预览未完成首次渲染")

        state.documentLineSpacing = 1.7
        state.documentParagraphSpacing = 0.5
        let style = try #require(
            await waitForRenderedParagraphStyle(state, lineHeightMultiple: 1.7),
            "改行距后预览未重渲染"
        )
        #expect(
            abs(style.paragraphSpacing - state.textFontSize * 0.5) < 0.001,
            "改段距后预览未重渲染：\(style.paragraphSpacing)"
        )
    }

    /// 自选字体与行距只作用于正文，代码块保持自己的等宽字体与紧凑行高。
    @Test func markdownPreviewKeepsCodeBlockLayoutWithCustomStyling() async throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        state.originalImageName = "notes.md"
        state.text = "正文段落\n\n```\nlet value = 1\n```"
        state.documentFontName = "Songti SC"
        state.documentLineSpacing = 2.0
        state.isMarkdownPreview = true

        let rendered = await waitForRenderedMarkdown(state)

        let bodyRange = try range(of: "正文段落", in: rendered)
        let bodyFont = try #require(rendered.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont)
        #expect(bodyFont.familyName?.contains("Songti") == true, "正文未使用自选字体：\(bodyFont.fontName)")

        let codeRange = try range(of: "let value = 1", in: rendered)
        let codeFont = try #require(rendered.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        #expect(codeFont.isFixedPitch, "代码块被换成了正文的自选字体：\(codeFont.fontName)")

        let codeStyle = try #require(paragraphStyle(of: rendered, at: codeRange.location), "代码块缺少段落样式")
        #expect(codeStyle.lineHeightMultiple != 2.0, "代码块被套上了自选行距：\(codeStyle.lineHeightMultiple)")
        #expect(codeStyle.paragraphSpacing == 0, "代码块被套上了自选段距：\(codeStyle.paragraphSpacing)")
    }

    /// 只读通道（自选样式的纯文本文档）：行距/段距同样落到 NSTextView 的默认段落样式上。
    @Test func readOnlyTextViewAppliesCustomSpacing() async throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        state.originalImageName = "notes.txt"
        state.textURL = URL(fileURLWithPath: "/tmp/notes.txt")
        state.text = "正文段落"
        state.documentLineSpacing = 1.8
        state.documentParagraphSpacing = 1.5

        let hosting = NSHostingView(rootView: TextEditorModeView(appState: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        hosting.layoutSubtreeIfNeeded()
        let textView = try #require(firstTextView(in: hosting), "只读通道未生成 NSTextView")
        #expect(!textView.isEditable, "未走到只读通道")

        let style = try #require(
            await waitForDefaultParagraphStyle(textView, lineHeightMultiple: 1.8),
            "只读通道未按自选行距更新段落样式"
        )
        #expect(abs(style.paragraphSpacing - state.textFontSize * 1.5) < 0.001, "段距未生效：\(style.paragraphSpacing)")
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

    /// 轮询渲染结果里正文段落的行距；既跑 runloop 让 SwiftUI 派发 onChange，也等待后台渲染任务。
    private func waitForRenderedParagraphStyle(
        _ state: AppState,
        lineHeightMultiple: Double
    ) async -> NSParagraphStyle? {
        for _ in 0..<300 {
            let rendered = state.renderedMarkdown
            let location = (rendered.string as NSString).range(of: "正文段落").location
            if location != NSNotFound,
               let style = paragraphStyle(of: rendered, at: location),
               abs(style.lineHeightMultiple - lineHeightMultiple) < 0.001 {
                return style
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// 轮询宿主视图里的默认段落样式；既跑 runloop 让 SwiftUI 派发 onChange，也等编辑器自己更新。
    private func waitForDefaultParagraphStyle(
        _ textView: NSTextView,
        lineHeightMultiple: Double
    ) async -> NSParagraphStyle? {
        for _ in 0..<200 {
            if let style = textView.defaultParagraphStyle,
               abs(style.lineHeightMultiple - lineHeightMultiple) < 0.001 {
                return style
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            try? await Task.sleep(for: .milliseconds(5))
        }
        return textView.defaultParagraphStyle
    }

    /// 渲染结果里某段文字所在段落的样式。
    private func paragraphStyle(of rendered: NSAttributedString, at location: Int) -> NSParagraphStyle? {
        rendered.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
    }

    /// 渲染结果里某段文字的字符范围。
    private func range(of needle: String, in rendered: NSAttributedString) throws -> NSRange {
        let range = (rendered.string as NSString).range(of: needle)
        try #require(range.location != NSNotFound, "渲染结果缺少文本「\(needle)」")
        return range
    }

    /// 视图层级里第一个 NSTextView。
    private func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }
}
