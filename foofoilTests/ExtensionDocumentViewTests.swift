//  ExtensionDocumentViewTests.swift
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
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
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
