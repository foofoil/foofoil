//
//  ReadOnlyCodeView.swift
//  foofoil
//

import SwiftUI
import AppKit
import WebKit

/// 只读代码预览的 WebKit 视图：只负责展示与滚动，不承载网页导航、缩放或编辑命令。
final class CodePreviewWebView: WKWebView {
    /// 上下键滚动正文，与只读文本的单行步进保持一致。
    func scrollContent(by delta: CGFloat) {
        evaluateJavaScript("window.scrollBy(0, \(delta));", completionHandler: nil)
    }
}

/// 页面所需的排版与外观快照；变化时只更新 CSS，内容未变时不重新高亮。
struct CodePreviewStyle: Equatable {
    var fontFamily: String
    var fontSize: Double
    var lineHeight: Double?
    var paragraphSpacing: Double
    var textColor: String?
    var isDark: Bool
    var showsLineNumbers: Bool

    var payload: [String: Any] {
        [
            "fontFamily": fontFamily,
            "fontSize": fontSize,
            "lineHeight": lineHeight.map { $0 as Any } ?? NSNull(),
            "paragraphSpacing": paragraphSpacing,
            "textColor": textColor.map { $0 as Any } ?? NSNull(),
            "isDark": isDark,
            "showLineNumbers": showsLineNumbers,
        ]
    }
}

/// 应用自带的页面壳与脚本资源；内容与语法资源都只从固定 Bundle 读取，不接触用户文件。
enum CodePreviewResources {
    static let page: String? = loadText(named: "code-preview", extension: "html")
    static let stylesheet: String? = loadText(named: "code-preview", extension: "css")
    static let script: String? = loadText(named: "code-preview", extension: "js")
    /// 约 1 MB 的 Worker 脚本只读取一次，之后按视图经 callAsyncJavaScript 传入页面。
    static let workerSource: String? = loadText(named: "highlight-worker", extension: "js")

    static func makePageHTML(nonce: String) -> String? {
        guard let page, let stylesheet, let script else { return nil }
        return page
            .replacingOccurrences(of: "__FOOFOIL_NONCE__", with: nonce)
            .replacingOccurrences(of: "__FOOFOIL_CSS__", with: stylesheet)
            .replacingOccurrences(of: "__FOOFOIL_SCRIPT__", with: script)
    }

    private static func loadText(named name: String, extension ext: String) -> String? {
        let url = Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "CodePreview")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}

struct ReadOnlyCodeView: NSViewRepresentable {
    let text: String
    let languageID: String
    let style: CodePreviewStyle
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure)
    }

    func makeNSView(context: Context) -> CodePreviewWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ webView: CodePreviewWebView, context: Context) {
        context.coordinator.onFailure = onFailure
        context.coordinator.update(text: text, languageID: languageID, style: style)
    }

    static func dismantleNSView(_ webView: CodePreviewWebView, coordinator: Coordinator) {
        coordinator.dispose()
    }

    /// WKUserContentController 长期持有消息处理器；通过弱引用转发，避免它与 Coordinator 互相持有。
    final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: Coordinator?

        init(target: Coordinator) {
            self.target = target
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(userContentController, didReceive: message)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        static let messageHandlerName = "foofoilCode"
        /// WebKit 冷启动与页面加载的时限；冷启动不计入源码展示时限。
        private static let startupTimeout: Duration = .seconds(5)
        /// 页面就绪后展示源码的时限；超过即回退原生视图。
        private static let displayTimeout: Duration = .seconds(2)

        var onFailure: () -> Void
        private weak var webView: CodePreviewWebView?
        private var isPageReady = false
        private var isDisposed = false
        private var hasReportedFailure = false
        private var revision = 0
        private var desired: (text: String, languageID: String, style: CodePreviewStyle)?
        private var sentText: String?
        private var sentLanguageID: String?
        private var sentStyle: CodePreviewStyle?
        private var watchdog: Task<Void, Never>?

        init(onFailure: @escaping () -> Void) {
            self.onFailure = onFailure
        }

        func makeWebView() -> CodePreviewWebView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.userContentController.add(WeakMessageHandler(target: self), name: Self.messageHandlerName)

            let webView = CodePreviewWebView(frame: .zero, configuration: configuration)
            webView.setValue(false, forKey: "drawsBackground")
            webView.underPageBackgroundColor = .clear
            webView.allowsMagnification = false
            webView.navigationDelegate = self
            self.webView = webView

            guard let html = CodePreviewResources.makePageHTML(nonce: Self.makeNonce()) else {
                reportFailure()
                return webView
            }
            webView.loadHTMLString(html, baseURL: nil)
            armWatchdog(Self.startupTimeout)
            return webView
        }

        func update(text: String, languageID: String, style: CodePreviewStyle) {
            guard !isDisposed else { return }
            desired = (text, languageID, style)
            if isPageReady {
                synchronize()
            }
        }

        func dispose() {
            guard !isDisposed else { return }
            isDisposed = true
            cancelWatchdog()
            desired = nil
            if let webView {
                webView.evaluateJavaScript("window.foofoilCode && window.foofoilCode.dispose();", completionHandler: nil)
                webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
                webView.navigationDelegate = nil
                webView.stopLoading()
            }
            webView = nil
        }

        private func synchronize() {
            guard let desired, isPageReady, !isDisposed else { return }
            if desired.text != sentText || desired.languageID != sentLanguageID {
                revision += 1
                sentText = desired.text
                sentLanguageID = desired.languageID
                sentStyle = desired.style
                armWatchdog(Self.displayTimeout)
                callPage(
                    "window.foofoilCode.setContent(payload);",
                    arguments: [
                        "payload": [
                            "revision": revision,
                            "source": desired.text,
                            "language": desired.languageID,
                            "style": desired.style.payload,
                        ] as [String: Any],
                    ]
                )
            } else if desired.style != sentStyle {
                sentStyle = desired.style
                callPage("window.foofoilCode.setStyle(style);", arguments: ["style": desired.style.payload])
            }
        }

        private func callPage(_ body: String, arguments: [String: Any]) {
            webView?.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { [weak self] result in
                if case .failure = result {
                    self?.reportFailure()
                }
            }
        }

        private func handlePageReady() {
            isPageReady = true
            armWatchdog(Self.displayTimeout)
            guard let workerSource = CodePreviewResources.workerSource else {
                reportFailure()
                return
            }
            callPage("window.foofoilCode.setWorkerSource(source);", arguments: ["source": workerSource])
            synchronize()
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !isDisposed,
                  message.webView === webView,
                  message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            if type == "ready" {
                handlePageReady()
                return
            }
            guard let messageRevision = body["revision"] as? Int, messageRevision == revision else { return }
            switch type {
            case "plain":
                cancelWatchdog()
            case "highlighted":
                cancelWatchdog()
            case "failed":
                reportFailure()
            default:
                break
            }
        }

        // MARK: - WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // 只允许加载应用自带的页面壳（about:blank）；链接、下载与新窗口一律取消。
            let isInitialDocument = navigationAction.targetFrame?.isMainFrame == true
                && navigationAction.navigationType == .other
                && navigationAction.request.url?.absoluteString == "about:blank"
            decisionHandler(isInitialDocument ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportFailure()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportFailure()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            reportFailure()
        }

        // MARK: - Failure

        private func armWatchdog(_ timeout: Duration) {
            watchdog?.cancel()
            watchdog = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.reportFailure()
            }
        }

        private func cancelWatchdog() {
            watchdog?.cancel()
            watchdog = nil
        }

        /// 只报告一次；异步回调以避免在 SwiftUI 视图更新期间修改状态。
        private func reportFailure() {
            guard !isDisposed, !hasReportedFailure else { return }
            hasReportedFailure = true
            cancelWatchdog()
            Task { @MainActor [weak self] in
                self?.onFailure()
            }
        }

        private static func makeNonce() -> String {
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
    }
}
