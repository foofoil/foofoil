//  ExtensionDocumentNetworkTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/13.
//

import Foundation
import Network
import WebKit
import Testing
@testable import foofoil

@MainActor
@Suite(.serialized)
struct ExtensionDocumentNetworkTests {
    @Test func ruleListCompiles() async {
        #expect(await DocumentContentRuleList.shared() != nil)
    }

    /// 真实 WKWebView + 本地 HTTP 计数：安装生产规则后，加载与交互期间远程请求数必须为零。
    @Test func uncleanHTMLMakesNoRemoteRequestsWithRules() async throws {
        let server = try LocalHTTPServer()
        defer { server.stop() }
        let fixture = try makeFixture(html: uncleanHTML(port: server.port))
        defer { fixture.cleanup() }

        let rules = try #require(await DocumentContentRuleList.shared())
        fixture.webView.configuration.userContentController.add(rules)
        let waiter = NetworkNavigationWaiter()
        fixture.webView.navigationDelegate = waiter
        fixture.webView.loadFileURL(fixture.fileURL, allowingReadAccessTo: fixture.fileURL)
        await waiter.waitForFinish()
        try await Task.sleep(for: .seconds(1))

        #expect(server.requestCount() == 0)
    }

    /// 阳性对照：同一页面不装规则时必须真的打到服务，证明零请求来自规则阻断而非服务不可达。
    @Test func uncleanHTMLReachesServerWithoutRules() async throws {
        let server = try LocalHTTPServer()
        defer { server.stop() }
        let fixture = try makeFixture(html: uncleanHTML(port: server.port))
        defer { fixture.cleanup() }

        let waiter = NetworkNavigationWaiter()
        fixture.webView.navigationDelegate = waiter
        fixture.webView.loadFileURL(fixture.fileURL, allowingReadAccessTo: fixture.fileURL)
        await waiter.waitForFinish()
        for _ in 0..<300 where server.requestCount() == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.requestCount() > 0)
    }

    // MARK: - Helpers

    private struct Fixture {
        let webView: WKWebView
        let window: NSWindow
        let fileURL: URL
        let directory: URL

        func cleanup() {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            window.orderOut(nil)
            window.contentView = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func uncleanHTML(port: UInt16) -> String {
        let base = "http://127.0.0.1:\(port)"
        return """
        <html><head>
        <link rel="stylesheet" href="\(base)/a.css">
        <script src="\(base)/a.js"></script>
        <style>@import url("\(base)/import.css");</style>
        <meta http-equiv="refresh" content="0; url=\(base)/refresh">
        </head><body>
        <p>正文</p>
        <img src="\(base)/a.png" alt="">
        <img srcset="\(base)/b.png 1x" src="\(base)/c.png" alt="">
        <iframe src="\(base)/frame.html"></iframe>
        <form action="\(base)/submit"><input type="submit"></form>
        </body></html>
        """
    }

    /// 写入临时 HTML 并以生产配置（JS 关闭、非持久化）挂到离屏窗口。
    private func makeFixture(html: String) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-document-network-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("chapter.html")
        try Data(html.utf8).write(to: fileURL)

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
        return Fixture(webView: webView, window: window, fileURL: fileURL, directory: directory)
    }
}

@MainActor
private final class NetworkNavigationWaiter: NSObject, WKNavigationDelegate {
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
