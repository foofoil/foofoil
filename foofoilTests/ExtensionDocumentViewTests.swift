//  ExtensionDocumentViewTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/13.
//

import Foundation
import SwiftUI
import WebKit
import Testing
@testable import foofoil

@MainActor
@Suite(.serialized)
struct ExtensionDocumentViewTests {
    @Test func acceptsHTMLUnderTemporaryDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-document-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("chapter.html")
        try Data("<html></html>".utf8).write(to: fileURL)

        #expect(ExtensionDocumentURLPolicy.fileURL(for: fileURL) == fileURL)
        #expect(
            ExtensionDocumentURLPolicy.fileURL(for: URL(string: fileURL.absoluteString + "#note-1")!) == fileURL
        )
    }

    @Test func rejectsUnsupportedDocumentURLs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-document-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let textURL = directory.appendingPathComponent("chapter.txt")
        try Data("text".utf8).write(to: textURL)
        #expect(ExtensionDocumentURLPolicy.fileURL(for: textURL) == nil)

        let missingURL = directory.appendingPathComponent("missing.html")
        #expect(ExtensionDocumentURLPolicy.fileURL(for: missingURL) == nil)

        let outsideURL = URL(fileURLWithPath: "/tmp/foofoil-outside-\(UUID().uuidString).html")
        #expect(ExtensionDocumentURLPolicy.fileURL(for: outsideURL) == nil)

        #expect(ExtensionDocumentURLPolicy.fileURL(for: URL(string: "https://example.com/a.html")!) == nil)
        #expect(ExtensionDocumentURLPolicy.fileURL(for: URL(string: "file://example.com/a.html")!) == nil)

        let target = directory.appendingPathComponent("real.html")
        try Data("<html></html>".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.html")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(ExtensionDocumentURLPolicy.fileURL(for: link) == nil)
    }

    /// 结论：macOS 的 `loadFileURL` 会处理 fragment 并按锚点滚动，无需 JS。
    @Test func loadFileURLScrollsToFragmentAnchor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-document-anchor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("chapter.html")
        let html = """
        <html><body style="margin:0">
        <div style="height:2000px">top</div>
        <h1 id="target">target</h1>
        <div style="height:2000px">bottom</div>
        </body></html>
        """
        try Data(html.utf8).write(to: fileURL)

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        defer { window.orderOut(nil) }

        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
        components?.fragment = "target"
        let target = try #require(components?.url)
        webView.loadFileURL(target, allowingReadAccessTo: fileURL)
        await waiter.waitForFinish()
        try await Task.sleep(nanoseconds: 300_000_000)

        let scrollY = (try? await webView.evaluateJavaScript("window.scrollY")) as? Double ?? -1
        #expect(
            webView.url?.fragment == "target",
            "fragment=\(webView.url?.fragment ?? "nil") url=\(webView.url?.absoluteString ?? "nil")"
        )
        #expect(scrollY > 100, "scrollY=\(scrollY)")
    }

    /// 扩展文档（电子书等）的正文背景由宿主注入，清除后恢复页面自有背景。
    @Test func documentViewAppliesAndClearsHostBackgroundColor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-document-background-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("chapter.html")
        // 与电子书章节页同构：正文容器的背景由 id 选择器给出，宿主必须压过它。
        let html = """
        <html><head><style>
        html, body { margin: 0; background: rgb(255, 255, 255); }
        #foofoil-reader { max-width: 44em; margin: 0 auto; background: rgb(0, 128, 0); }
        </style></head>
        <body id="foofoil-reader"><p>正文</p></body></html>
        """
        try Data(html.utf8).write(to: fileURL)

        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(rootView: makeDocumentView(url: fileURL, backgroundHex: "#123456"))
        window.contentView = hosting
        hosting.frame = window.contentView?.bounds ?? .zero
        defer { window.orderOut(nil) }

        let webView = try await waitForWebView(in: hosting)
        let injected = await bodyBackground(of: webView, until: "rgb(18, 52, 86)")
        #expect(injected == "rgb(18, 52, 86)", "正文背景未被宿主背景色覆盖：\(injected ?? "nil")")

        hosting.rootView = makeDocumentView(url: fileURL, backgroundHex: nil)
        let restored = await bodyBackground(of: webView, until: "rgb(0, 128, 0)")
        #expect(restored == "rgb(0, 128, 0)", "清除背景色后未恢复页面自有背景：\(restored ?? "nil")")
    }

    private func makeDocumentView(url: URL, backgroundHex: String?) -> ExtensionDocumentView {
        ExtensionDocumentView(
            url: url,
            sessionID: UUID(),
            textScale: 1.0,
            documentBackgroundHex: backgroundHex,
            documentTextColorHex: nil,
            documentFontFamily: nil,
            documentLineHeightMultiple: nil,
            documentParagraphSpacingMultiple: nil,
            initialScrollFile: nil,
            initialScrollFraction: nil,
            onScroll: { _, _ in }
        )
    }

    private func waitForWebView(in view: NSView) async throws -> WKWebView {
        for _ in 0..<300 {
            if let webView = Self.firstWebView(in: view) { return webView }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    private static func firstWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for subview in view.subviews {
            if let found = firstWebView(in: subview) { return found }
        }
        return nil
    }

    /// 注入发生在加载完成后的异步收尾里，轮询到目标值或超时；返回最后一次读数。
    private func bodyBackground(of webView: WKWebView, until expected: String) async -> String? {
        var latest: String?
        for _ in 0..<300 {
            latest = (try? await webView.evaluateJavaScript(
                "getComputedStyle(document.body).backgroundColor"
            )) as? String
            if latest == expected { return latest }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return latest
    }
}

@MainActor
final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForFinish() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume()
        continuation = nil
    }
}
