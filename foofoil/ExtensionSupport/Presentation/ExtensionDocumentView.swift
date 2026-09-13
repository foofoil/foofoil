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
    let textScale: Double

    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var securityFailed = false

    var body: some View {
        ZStack {
            ExtensionDocumentWebView(
                url: url,
                textScale: textScale,
                isLoading: $isLoading,
                loadFailed: $loadFailed,
                securityFailed: $securityFailed
            )
            .opacity(loadFailed || securityFailed ? 0 : 1)

            if securityFailed {
                ContentUnavailableView(
                    NSLocalizedString("Document Security Setup Failed", comment: ""),
                    systemImage: "lock.slash"
                )
            } else if loadFailed {
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
            securityFailed = false
        }
    }
}

/// 文档 WKWebView 的生产配置：禁用脚本、非持久化站点数据。
enum ExtensionDocumentWebViewFactory {
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }
}

/// 纯文字缩放的固定宿主脚本：只改根字号与正文字号，不触碰图片与增量布局。
enum DocumentTextZoom {
    static let basePoints = 16.0
    static let anchorAttribute = "data-foofoil-zoom-anchor"

    static func fontPoints(for scale: Double) -> Int {
        max(1, Int((basePoints * scale).rounded()))
    }

    static func styleScript(for scale: Double) -> String {
        let points = fontPoints(for: scale)
        return "(function(){"
            + "var id='foofoil-text-zoom';"
            + "var el=document.getElementById(id);"
            + "if(!el){el=document.createElement('style');el.id=id;"
            + "(document.head||document.documentElement).appendChild(el);}"
            + "el.textContent='html{font-size:\(points)px !important;} body{font-size:1em !important;}';"
            + "})();"
    }

    /// 记录当前视口顶端可见的文字块及其相对视口偏移，缩放后据此回位。
    static let captureAnchorScript = """
    (function(){
      var nodes = document.body
        ? document.body.querySelectorAll('p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,td,th,figure,img,section')
        : [];
      var anchor = null;
      var offset = 0;
      for (var i = 0; i < nodes.length; i++) {
        var rect = nodes[i].getBoundingClientRect();
        if (rect.height > 0 && rect.bottom > 4) {
          anchor = nodes[i];
          offset = rect.top;
          break;
        }
      }
      if (!anchor) { return null; }
      var previous = document.querySelectorAll('[data-foofoil-zoom-anchor]');
      for (var j = 0; j < previous.length; j++) {
        previous[j].removeAttribute('data-foofoil-zoom-anchor');
      }
      anchor.setAttribute('data-foofoil-zoom-anchor', '1');
      return offset;
    })();
    """

    static func restoreAnchorScript(offset: Double) -> String {
        """
        (function(){
          var el = document.querySelector('[data-foofoil-zoom-anchor]');
          if (!el) { return; }
          var delta = el.getBoundingClientRect().top - (\(offset));
          if (Math.abs(delta) > 0.5) { window.scrollBy(0, delta); }
        })();
        """
    }
}

/// 进程级内容规则表：加载前安装默认拒绝网络，编译失败不得降级为无规则加载。
@MainActor
enum DocumentContentRuleList {
    private static var cached: WKContentRuleList?
    private static var compilationTask: Task<WKContentRuleList?, Never>?

    static func shared() async -> WKContentRuleList? {
        if let cached { return cached }
        if let compilationTask { return await compilationTask.value }
        let task = Task { await compile() }
        compilationTask = task
        let list = await task.value
        cached = list
        compilationTask = nil
        return list
    }

    private static func compile() async -> WKContentRuleList? {
        // 只阻断明确的网络 scheme；file:/data: 由单文件读权限与 CSP 约束，避免误伤主文档。
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": "^https?://"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^wss?://"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^ftp://"], "action": ["type": "block"]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let encoded = String(data: data, encoding: .utf8),
              let store = WKContentRuleListStore.default() else { return nil }
        return try? await store.compileContentRuleList(
            forIdentifier: "app.foofoil.document-network-deny",
            encodedContentRuleList: encoded
        )
    }
}

private struct ExtensionDocumentWebView: NSViewRepresentable {
    let url: URL
    let textScale: Double
    @Binding var isLoading: Bool
    @Binding var loadFailed: Bool
    @Binding var securityFailed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = ExtensionDocumentWebViewFactory.makeConfiguration()
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
        context.coordinator.applyTextScale(textScale)
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
        private var hasInstalledRuleList = false
        private var loadGeneration: UInt64 = 0
        private var appliedTextScale: Double = .nan
        private var textScaleGeneration: UInt64 = 0

        init(_ parent: ExtensionDocumentWebView) {
            self.parent = parent
        }

        func invalidate() {
            loadedURL = nil
            targetIdentity = nil
            loadGeneration &+= 1
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
            parent.securityFailed = false
            loadGeneration &+= 1
            let generation = loadGeneration
            if hasInstalledRuleList {
                // 读权限只授予该 HTML 文件本身：文档资源全部内联。
                webView?.loadFileURL(url, allowingReadAccessTo: fileURL)
                return
            }
            Task { @MainActor in
                guard let rules = await DocumentContentRuleList.shared() else {
                    guard self.loadGeneration == generation else { return }
                    self.parent.isLoading = false
                    self.parent.securityFailed = true
                    return
                }
                guard self.loadGeneration == generation, self.loadedURL == url else { return }
                self.webView?.configuration.userContentController.add(rules)
                self.hasInstalledRuleList = true
                self.webView?.loadFileURL(url, allowingReadAccessTo: fileURL)
            }
        }

        private func markFailed() {
            guard !hasReportedFailure else { return }
            hasReportedFailure = true
            parent.isLoading = false
            parent.loadFailed = true
        }

        /// 纯文字缩放：以视口顶端可见文字块为锚点，改字号后回位，避免内容跳走。
        func applyTextScale(_ scale: Double, force: Bool = false) {
            guard force || scale != appliedTextScale else { return }
            appliedTextScale = scale
            textScaleGeneration &+= 1
            let generation = textScaleGeneration
            guard let webView else { return }
            Task { @MainActor [weak self] in
                guard let self, self.textScaleGeneration == generation else { return }
                var anchorOffset: Double?
                if !force {
                    anchorOffset = (try? await webView.evaluateJavaScript(
                        DocumentTextZoom.captureAnchorScript
                    )) as? Double
                }
                guard self.textScaleGeneration == generation else { return }
                _ = try? await webView.evaluateJavaScript(DocumentTextZoom.styleScript(for: scale))
                if let anchorOffset {
                    _ = try? await webView.evaluateJavaScript(
                        DocumentTextZoom.restoreAnchorScript(offset: anchorOffset)
                    )
                }
            }
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
            applyTextScale(parent.textScale, force: true)
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
