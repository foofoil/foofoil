//  DocumentTextZoomTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/13.
//

import Foundation
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

    private func computedBodyFontSize(_ webView: WKWebView) async throws -> String {
        try await webView.evaluateJavaScript("getComputedStyle(document.body).fontSize") as? String ?? ""
    }

    private func makeLoadedWebView() async throws -> WKWebView {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-text-zoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("chapter.html")
        try Data("<html><body><p>正文</p><img src='data:image/png;base64,iVBORw0KGgo=' alt=''></body></html>".utf8)
            .write(to: fileURL)

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
