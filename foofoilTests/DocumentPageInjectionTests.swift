//  DocumentPageInjectionTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/18.
//

import AppKit
import Foundation
import WebKit
import Testing
@testable import foofoil

@MainActor
@Suite(.serialized)
struct DocumentPageInjectionTests {
    /// 注入的背景色要盖过页面自有背景（含样式表与内联样式），清除后页面恢复原样。
    @Test func injectionOverridesPageBackgroundAndRestoresOnClear() async throws {
        let (webView, window, directory) = try await loadPage(
            """
            <html><head><style>
            html { background-color: rgb(255, 255, 255); }
            body { background-color: rgb(0, 128, 0); background-image: url('none.png'); }
            </style></head>
            <body style="color: rgb(1, 2, 3)">text</body></html>
            """
        )
        defer {
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: directory)
        }

        #expect(try await backgroundColor(of: "document.documentElement", in: webView) == "rgb(255, 255, 255)")
        #expect(try await backgroundColor(of: "document.body", in: webView) == "rgb(0, 128, 0)")

        _ = try await webView.evaluateJavaScript(
            DocumentPageInjection.script(DocumentPageInjection.Overrides(backgroundColorHex: "#123456"))
        )
        #expect(try await backgroundColor(of: "document.documentElement", in: webView) == "rgb(18, 52, 86)")
        #expect(try await backgroundColor(of: "document.body", in: webView) == "rgb(18, 52, 86)")
        #expect(try await style(of: "document.body", in: webView, property: "background-image") == "none")

        _ = try await webView.evaluateJavaScript(DocumentPageInjection.script(DocumentPageInjection.Overrides()))
        #expect(try await backgroundColor(of: "document.documentElement", in: webView) == "rgb(255, 255, 255)")
        #expect(try await backgroundColor(of: "document.body", in: webView) == "rgb(0, 128, 0)")
        // 宿主只还原自己动过的属性，页面原有的内联样式不受影响。
        #expect(try await style(of: "document.body", in: webView, property: "color") == "rgb(1, 2, 3)")
        #expect(try await style(of: "document.body", in: webView, property: "background-image").contains("none.png"))
    }

    /// 文字颜色与字体同样注入 html/body，且与背景的清除互不牵连。
    @Test func injectionAppliesTextColorAndFontFamily() async throws {
        let (webView, window, directory) = try await loadPage(
            """
            <html><head><style>
            body { background-color: rgb(0, 128, 0); color: rgb(1, 2, 3); font-family: Georgia, serif; }
            </style></head><body id="foofoil-reader">text</body></html>
            """
        )
        defer {
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: directory)
        }

        _ = try await webView.evaluateJavaScript(
            DocumentPageInjection.script(
                DocumentPageInjection.Overrides(
                    backgroundColorHex: "#123456",
                    textColorHex: "#F5EFE0",
                    fontFamily: "Menlo, monospace"
                )
            )
        )
        #expect(try await style(of: "document.body", in: webView, property: "color") == "rgb(245, 239, 224)")
        #expect(try await style(of: "document.body", in: webView, property: "font-family").contains("Menlo"))
        #expect(try await backgroundColor(of: "document.body", in: webView) == "rgb(18, 52, 86)")

        // 只撤销背景：文字颜色与字体保持不变。
        _ = try await webView.evaluateJavaScript(
            DocumentPageInjection.script(
                DocumentPageInjection.Overrides(textColorHex: "#F5EFE0", fontFamily: "Menlo, monospace")
            )
        )
        #expect(try await backgroundColor(of: "document.body", in: webView) == "rgb(0, 128, 0)")
        #expect(try await style(of: "document.body", in: webView, property: "color") == "rgb(245, 239, 224)")

        // 全部清除：页面恢复自己的颜色与字体。
        _ = try await webView.evaluateJavaScript(DocumentPageInjection.script(DocumentPageInjection.Overrides()))
        #expect(try await style(of: "document.body", in: webView, property: "color") == "rgb(1, 2, 3)")
        #expect(try await style(of: "document.body", in: webView, property: "font-family").contains("Georgia"))
    }

    /// 行间距与段落间距经自定义属性注入：文档自己用 !important 定的排版也能被宿主覆盖。
    @Test func injectionAppliesSpacingThroughCustomProperties() async throws {
        let (webView, window, directory) = try await loadPage(
            """
            <html><head><style>
            #reader { line-height: var(--foofoil-document-line-height, 1.9); font-size: 16px; }
            #reader p { margin-bottom: var(--foofoil-document-paragraph-spacing, 0.25em) !important; }
            </style></head><body id="reader"><p>段落</p></body></html>
            """
        )
        defer {
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: directory)
        }

        #expect(try await lineHeightMultiple(of: "document.body", in: webView) == 1.9)
        #expect(try await style(of: "document.querySelector('p')", in: webView, property: "margin-bottom") == "4px")

        _ = try await webView.evaluateJavaScript(
            DocumentPageInjection.script(
                DocumentPageInjection.Overrides(lineHeightMultiple: 1.5, paragraphSpacingMultiple: 1.25)
            )
        )
        #expect(try await lineHeightMultiple(of: "document.body", in: webView) == 1.5)
        #expect(try await style(of: "document.querySelector('p')", in: webView, property: "margin-bottom") == "20px")

        // 清除后回到文档自己的排版。
        _ = try await webView.evaluateJavaScript(DocumentPageInjection.script(DocumentPageInjection.Overrides()))
        #expect(try await lineHeightMultiple(of: "document.body", in: webView) == 1.9)
        #expect(try await style(of: "document.querySelector('p')", in: webView, property: "margin-bottom") == "4px")
    }

    /// 行高倍数：WebKit 对纯数字行高可能回成倍数、也可能回成像素，两种都换算成倍数。
    private func lineHeightMultiple(of element: String, in webView: WKWebView) async throws -> Double {
        let raw = try await style(of: element, in: webView, property: "line-height")
        if raw.hasSuffix("px") {
            let fontSize = try await style(of: element, in: webView, property: "font-size")
            guard let lineHeight = Double(raw.dropLast(2)), let size = Double(fontSize.dropLast(2)), size > 0 else {
                return -1
            }
            return lineHeight / size
        }
        return Double(raw) ?? -1
    }

    /// 非法颜色不写入页面，避免把任意字符串当作 CSS 值注入。
    @Test func invalidHexLeavesPageBackgroundUntouched() async throws {
        let (webView, window, directory) = try await loadPage(
            """
            <html><head><style>body { background-color: rgb(0, 128, 0); }</style></head><body>text</body></html>
            """
        )
        defer {
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: directory)
        }

        _ = try await webView.evaluateJavaScript(
            DocumentPageInjection.script(
                DocumentPageInjection.Overrides(backgroundColorHex: "green; } html { background-color: red")
            )
        )
        #expect(try await backgroundColor(of: "document.body", in: webView) == "rgb(0, 128, 0)")
        #expect(try await backgroundColor(of: "document.documentElement", in: webView) != "rgb(255, 0, 0)")
    }

    /// 页面外观跟随自选背景的明暗，使页面自身文字配色与背景保持对比。
    @Test func appearanceFollowsChosenBackgroundLuminance() {
        #expect(DocumentPageInjection.appearance(hex: nil) == nil)
        #expect(DocumentPageInjection.appearance(hex: "not-a-color") == nil)
        #expect(DocumentPageInjection.appearance(hex: "#FFFFFF")?.name == .aqua)
        #expect(DocumentPageInjection.appearance(hex: "#F5EFE0")?.name == .aqua)
        #expect(DocumentPageInjection.appearance(hex: "#000000")?.name == .darkAqua)
        #expect(DocumentPageInjection.appearance(hex: "#1C1C1E")?.name == .darkAqua)
    }

    private func loadPage(_ html: String) async throws -> (webView: WKWebView, window: NSWindow, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-document-background-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("page.html")
        try Data(html.utf8).write(to: fileURL)

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        webView.setValue(false, forKey: "drawsBackground")
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = webView

        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL)
        await waiter.waitForFinish()
        return (webView, window, directory)
    }

    private func backgroundColor(of element: String, in webView: WKWebView) async throws -> String {
        try await style(of: element, in: webView, property: "background-color")
    }

    private func style(of element: String, in webView: WKWebView, property: String) async throws -> String {
        let value = try await webView.evaluateJavaScript(
            "getComputedStyle(\(element)).getPropertyValue('\(property)')"
        )
        return try #require(value as? String)
    }
}
