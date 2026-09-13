//  ExtensionDocumentView.swift
//  foofoil
//
//  Created by tolg on 2026/9/13.
//

import SwiftUI
import WebKit

/// 扩展 `document` presentation 的宿主策略：只接受进程临时目录下的普通 HTML 文件，
/// 不授权原 EPUB 或整个临时目录。
enum ExtensionDocumentURLPolicy {
    static func fileURL(for url: URL) -> URL? {
        guard url.isFileURL, url.host?.isEmpty ?? true else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.query = nil
        guard let fileURL = components?.url else { return nil }
        let path = fileURL.path
        let lowercased = path.lowercased()
        guard lowercased.hasSuffix(".html") || lowercased.hasSuffix(".htm") else { return nil }
        guard path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return nil }
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        return fileURL
    }

    static func fileIdentity(_ url: URL) -> String? {
        fileURL(for: url)?.standardizedFileURL.path
    }
}

/// 文档呈现：只读加载自包含 HTML，禁止脚本、持久化站点数据与新窗口。
struct ExtensionDocumentView: View {
    let url: URL
    let sessionID: UUID

    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            ExtensionDocumentWebView(url: url, isLoading: $isLoading, loadFailed: $loadFailed)
                .opacity(loadFailed ? 0 : 1)

            if loadFailed {
                ContentUnavailableView(
                    NSLocalizedString("Document Load Failed", comment: ""),
                    systemImage: "doc.text"
                )
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: url) {
            isLoading = true
            loadFailed = false
        }
    }
}

private struct ExtensionDocumentWebView: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var loadFailed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.load(url: url)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(url: url)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: ExtensionDocumentWebView
        weak var webView: WKWebView?
        private var loadedURL: URL?
        private var targetIdentity: String?
        private var hasReportedFailure = false

        init(_ parent: ExtensionDocumentWebView) {
            self.parent = parent
        }

        func invalidate() {
            loadedURL = nil
            targetIdentity = nil
        }

        func load(url: URL) {
            guard let fileURL = ExtensionDocumentURLPolicy.fileURL(for: url) else {
                loadedURL = url
                targetIdentity = nil
                markFailed()
                return
            }
            guard loadedURL != url else { return }
            loadedURL = url
            targetIdentity = ExtensionDocumentURLPolicy.fileIdentity(fileURL)
            hasReportedFailure = false
            parent.isLoading = true
            parent.loadFailed = false
            // 读权限只授予该 HTML 文件本身：文档资源全部内联。
            webView?.loadFileURL(url, allowingReadAccessTo: fileURL)
        }

        private func markFailed() {
            guard !hasReportedFailure else { return }
            hasReportedFailure = true
            parent.isLoading = false
            parent.loadFailed = true
        }

        private func isCurrent(_ url: URL?) -> Bool {
            guard let url, let targetIdentity else { return false }
            return ExtensionDocumentURLPolicy.fileIdentity(
                ExtensionDocumentURLPolicy.fileURL(for: url) ?? url
            ) == targetIdentity
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let target = navigationAction.request.url,
                  navigationAction.targetFrame?.isMainFrame == true else {
                return .cancel
            }
            if navigationAction.navigationType == .other,
               ExtensionDocumentURLPolicy.fileIdentity(target) == targetIdentity {
                return .allow
            }
            guard target.fragment != nil,
                  ExtensionDocumentURLPolicy.fileIdentity(target) == targetIdentity else {
                return .cancel
            }
            return .allow
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse
        ) async -> WKNavigationResponsePolicy {
            navigationResponse.isForMainFrame ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard isCurrent(webView.url) else { return }
            parent.isLoading = false
            parent.loadFailed = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard isCurrent(webView.url) else { return }
            markFailed()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            markFailed()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            markFailed()
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}
