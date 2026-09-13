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

    /// 缩放前后，视口顶端可见文字块必须保持在原位置（以顶端行为基准）。
    @Test func keepsTopVisibleBlockAnchoredWhenScaling() async throws {
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
            "document.querySelector('[data-foofoil-zoom-anchor]').getBoundingClientRect().top"
        )) as? Double
        let top = try #require(restoredTop)
        #expect(abs(top - anchorOffset) < 2.0)

        let scrollY = (try? await webView.evaluateJavaScript("window.scrollY")) as? Double ?? 0
        #expect(scrollY > 0)
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
            rootView: ExtensionDocumentView(url: fileURL, sessionID: UUID(), textScale: 1.0)
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

        hosting.rootView = ExtensionDocumentView(url: fileURL, sessionID: UUID(), textScale: 2.0)
        var afterTop = before
        for _ in 0..<300 {
            let fontSize = (try? await webView.evaluateJavaScript("getComputedStyle(document.body).fontSize")) as? String
            if fontSize == "32px" {
                afterTop = (try? await webView.evaluateJavaScript(
                    "document.querySelector('[data-foofoil-zoom-anchor]').getBoundingClientRect().top"
                )) as? Double ?? before
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(abs(afterTop - before) < 3.0, "before=\(before) after=\(afterTop)")
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

    private func tallHTML() -> String {
        let paragraph = String(repeating: "这是一段用于验证缩放锚点的正文，文字较多以便缩放时发生换行重排。", count: 6)
        let paragraphs = (0..<40).map { "<p>第 \($0) 段。\(paragraph)</p>" }.joined()
        return "<html><body>\(paragraphs)</body></html>"
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
