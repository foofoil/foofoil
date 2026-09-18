//  DocumentBackgroundInjectionTests.swift
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
struct DocumentBackgroundInjectionTests {
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

        _ = try await webView.evaluateJavaScript(DocumentBackgroundInjection.script(hex: "#123456"))
        #expect(try await backgroundColor(of: "document.documentElement", in: webView) == "rgb(18, 52, 86)")
        #expect(try await backgroundColor(of: "document.body", in: webView) == "rgb(18, 52, 86)")
        #expect(try await style(of: "document.body", in: webView, property: "background-image") == "none")

        _ = try await webView.evaluateJavaScript(DocumentBackgroundInjection.script(hex: nil))
        #expect(try await backgroundColor(of: "document.documentElement", in: webView) == "rgb(255, 255, 255)")
        #expect(try await backgroundColor(of: "document.body", in: webView) == "rgb(0, 128, 0)")
        // 宿主只还原自己动过的属性，页面原有的内联样式不受影响。
        #expect(try await style(of: "document.body", in: webView, property: "color") == "rgb(1, 2, 3)")
        #expect(try await style(of: "document.body", in: webView, property: "background-image").contains("none.png"))
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
            DocumentBackgroundInjection.script(hex: "green; } html { background-color: red")
        )
        #expect(try await backgroundColor(of: "document.body", in: webView) == "rgb(0, 128, 0)")
        #expect(try await backgroundColor(of: "document.documentElement", in: webView) != "rgb(255, 0, 0)")
    }

    /// 页面外观跟随自选背景的明暗，使页面自身文字配色与背景保持对比。
    @Test func appearanceFollowsChosenBackgroundLuminance() {
        #expect(DocumentBackgroundInjection.appearance(hex: nil) == nil)
        #expect(DocumentBackgroundInjection.appearance(hex: "not-a-color") == nil)
        #expect(DocumentBackgroundInjection.appearance(hex: "#FFFFFF")?.name == .aqua)
        #expect(DocumentBackgroundInjection.appearance(hex: "#F5EFE0")?.name == .aqua)
        #expect(DocumentBackgroundInjection.appearance(hex: "#000000")?.name == .darkAqua)
        #expect(DocumentBackgroundInjection.appearance(hex: "#1C1C1E")?.name == .darkAqua)
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
