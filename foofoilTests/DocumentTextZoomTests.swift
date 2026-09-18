//  DocumentTextZoomTests.swift
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
struct DocumentTextZoomTests {
    @Test func fontPointsClampAndRound() {
        #expect(DocumentTextZoom.fontPoints(for: 1.0) == 16)
        #expect(DocumentTextZoom.fontPoints(for: 1.1) == 18)
        #expect(DocumentTextZoom.fontPoints(for: 0.5) == 8)
        #expect(DocumentTextZoom.fontPoints(for: 0.0) == 1)
    }

    /// 生产文档配置（内容 JS 关闭）下，宿主脚本仍可把正文字号缩放为纯文字缩放。
    @Test func appliesTextOnlyZoomToComputedBodyFont() async throws {
        let webView = try await makeLoadedWebView()
        let initial = try await computedBodyFontSize(webView)
        #expect(initial == "16px")

        _ = try? await webView.evaluateJavaScript(DocumentTextZoom.styleScript(for: 2.0))
        #expect(try await computedBodyFontSize(webView) == "32px")

        _ = try? await webView.evaluateJavaScript(DocumentTextZoom.styleScript(for: 0.5))
        #expect(try await computedBodyFontSize(webView) == "8px")
    }

    /// 缩放前后，视口顶端可见的那行文字必须保持原位（同一行、同一视口位置）。
    /// 放大后每行容纳的字符变少，行中心命中的字符会变，因此断言锚定字符所在行回位、
    /// 且顶边可见文字仍属于锚定段落。
    @Test func keepsTopLineAnchoredWhenScaling() async throws {
        let webView = try await makeLoadedWebView(html: tallHTML())
        _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 800)")
        _ = try? await webView.evaluateJavaScript("document.body.offsetHeight")

        let captured = (try? await webView.evaluateJavaScript(
            DocumentTextZoom.captureAnchorScript
        )) as? Double
        let anchorOffset = try #require(captured)

        _ = try? await webView.evaluateJavaScript(DocumentTextZoom.styleScript(for: 2.0))
        _ = try? await webView.evaluateJavaScript(
            DocumentTextZoom.restoreAnchorScript(offset: anchorOffset)
        )

        let restoredTop = (try? await webView.evaluateJavaScript(
            DocumentTextZoom.anchorTopScript
        )) as? Double
        let top = try #require(restoredTop)
        let scrollY = (try? await webView.evaluateJavaScript("window.scrollY")) as? Double ?? 0
        #expect(abs(top - anchorOffset) < 2.0, "top=\(top) anchorOffset=\(anchorOffset) scrollY=\(scrollY)")

        // 顶边可见文字属于锚定段落（同一行文字仍在视口顶端）。
        let topInAnchor = try await topEdgeHitsAnchorBlock(webView)
        #expect(topInAnchor)
    }

    /// 通过真实 `ExtensionDocumentView` 驱动缩放，验证顶端可见行保持原位。
    @Test func documentViewKeepsTopLineAcrossScaleChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-text-zoom-view-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("chapter.html")
        try Data(tallHTML().utf8).write(to: fileURL)

        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(
            rootView: ExtensionDocumentView(
                url: fileURL,
                sessionID: UUID(),
                textScale: 1.0,
                documentBackgroundHex: nil,
                initialScrollFile: nil,
                initialScrollFraction: nil,
                onScroll: { _, _ in }
            )
        )
        window.contentView = hosting
        hosting.frame = window.contentView?.bounds ?? .zero
        defer { window.orderOut(nil) }

        let webView = try await waitForWebView(in: hosting)
        for _ in 0..<300 {
            let paragraphCount = (try? await webView.evaluateJavaScript(
                "document.querySelectorAll('p').length"
            )) as? Int ?? 0
            if paragraphCount > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 800)")
        let before = try #require(
            (try? await webView.evaluateJavaScript(DocumentTextZoom.captureAnchorScript)) as? Double
        )

        hosting.rootView = ExtensionDocumentView(
            url: fileURL,
            sessionID: UUID(),
            textScale: 2.0,
            documentBackgroundHex: nil,
            initialScrollFile: nil,
            initialScrollFraction: nil,
            onScroll: { _, _ in }
        )
        // 缩放 → 锚点回位是多步异步脚本；轮询直到顶行回到原位（或超时），不能在字号变化瞬间读数。
        var afterTop = before
        for _ in 0..<300 {
            afterTop = (try? await webView.evaluateJavaScript(
                DocumentTextZoom.anchorTopScript
            )) as? Double ?? before
            if abs(afterTop - before) < 3.0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(abs(afterTop - before) < 3.0, "before=\(before) after=\(afterTop)")
    }

    /// 通过真实视图驱动阅读位置链路：加载后按保存比例定位，并把 (文件, 比例) 回传宿主。
    @Test func documentViewRestoresAndReportsScrollPosition() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-doc-scroll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("chapter.html")
        try Data(tallHTML().utf8).write(to: fileURL)

        let reports = ScrollReportCollector()
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(
            rootView: ExtensionDocumentView(
                url: fileURL,
                sessionID: UUID(),
                textScale: 1.0,
                documentBackgroundHex: nil,
                initialScrollFile: "chapter.html",
                initialScrollFraction: 0.5,
                onScroll: { file, fraction in
                    reports.record(file: file, fraction: fraction)
                }
            )
        )
        window.contentView = hosting
        hosting.frame = window.contentView?.bounds ?? .zero
        defer { window.orderOut(nil) }

        let webView = try await waitForWebView(in: hosting)
        var scrollY = 0.0
        for _ in 0..<300 {
            scrollY = (try? await webView.evaluateJavaScript("window.scrollY")) as? Double ?? 0
            if scrollY > 100 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(scrollY > 100, "scrollY=\(scrollY)")
        // 回传经异步 script message 到达；轮询等待，不能在恢复定位后立即断言。
        var fraction = 0.0
        for _ in 0..<300 {
            fraction = reports.fraction
            if reports.file == "chapter.html", fraction > 0.2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(reports.file == "chapter.html", "file=\(reports.file ?? "nil")")
        #expect(fraction > 0.2, "fraction=\(fraction)")
    }

    /// 箔片宽度变化引起重排后，视口顶端那一行文字应保持原位。
    @Test func keepsTopLineAnchoredWhenWidthChanges() async throws {
        let webView = try await makeLoadedWebView(html: tallHTML())
        _ = try? await webView.evaluateJavaScript(DocumentScrollPersistence.hooksInstallScript)
        _ = try? await webView.evaluateJavaScript("window.scrollTo(0, 800)")
        // 滚动事件捕获锚点（前导节流立即执行）。
        try await Task.sleep(for: .milliseconds(150))
        let before = try #require(
            (try? await webView.evaluateJavaScript("window.__foofoilReaderAnchorTop()")) as? Double
        )

        webView.setFrameSize(NSSize(width: 640, height: 300))
        // resize 监听去抖 60ms 后回位；轮询等待生效。
        var after = before
        for _ in 0..<150 {
            after = (try? await webView.evaluateJavaScript(
                "window.__foofoilReaderAnchorTop()"
            )) as? Double ?? before
            if abs(after - before) < 2.0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(abs(after - before) < 2.0, "before=\(before) after=\(after)")
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

    private func computedBodyFontSize(_ webView: WKWebView) async throws -> String {
        try await webView.evaluateJavaScript("getComputedStyle(document.body).fontSize") as? String ?? ""
    }

    /// 视口顶边命中的文字是否位于锚定标记所在块内。
    private func topEdgeHitsAnchorBlock(_ webView: WKWebView) async throws -> Bool {
        let script = """
        (function(){
          var r = document.caretRangeFromPoint(Math.max(12, Math.floor(window.innerWidth / 2)), 8);
          if (!r || !r.startContainer) { return false; }
          var node = r.startContainer.parentElement;
          var anchor = document.querySelector('[data-foofoil-zoom-anchor]');
          return anchor != null && node != null && (node === anchor || anchor.contains(node));
        })();
        """
        return try await webView.evaluateJavaScript(script) as? Bool ?? false
    }

    private func tallHTML() -> String {
        // 与生产章节页一致的 CSP（script-src 'none'）：宿主注入的滚动监听与缩放脚本必须不受影响。
        let csp = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; "
            + "font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; "
            + "media-src 'none'; base-uri 'none'; form-action 'none'"
        let paragraph = String(repeating: "这是一段用于验证缩放锚点的正文，文字较多以便缩放时发生换行重排。", count: 6)
        let paragraphs = (0..<40).map { "<p>第 \($0) 段。\(paragraph)</p>" }.joined()
        return "<html><head><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\"></head>"
            + "<body>\(paragraphs)</body></html>"
    }

    private func makeLoadedWebView(html: String? = nil) async throws -> WKWebView {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-text-zoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("chapter.html")
        let content = html ?? "<html><body><p>正文</p><img src='data:image/png;base64,iVBORw0KGgo=' alt=''></body></html>"
        try Data(content.utf8).write(to: fileURL)

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            configuration: ExtensionDocumentWebViewFactory.makeConfiguration()
        )
        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        let waiter = ZoomNavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL)
        await waiter.waitForFinish()
        return webView
    }
}

@MainActor
private final class ZoomNavigationWaiter: NSObject, WKNavigationDelegate {
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

/// 线程安全收集文档视图回传的滚动位置，供测试断言。
private final class ScrollReportCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFile: String?
    private var storedFraction = 0.0

    var file: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedFile
    }

    var fraction: Double {
        lock.lock()
        defer { lock.unlock() }
        return storedFraction
    }

    func record(file: String, fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        storedFile = file
        storedFraction = fraction
    }
}
