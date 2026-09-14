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
/// 阅读位置（章节内滚动比例）由宿主采集与恢复：页面脚本始终禁用，
/// 滚动上报依赖宿主注入的监听与 script message 通道。
struct ExtensionDocumentView: View {
    let url: URL
    let sessionID: UUID
    let textScale: Double
    let initialScrollFile: String?
    let initialScrollFraction: Double?
    let onScroll: (_ file: String, _ fraction: Double) -> Void

    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var securityFailed = false

    var body: some View {
        ZStack {
            ExtensionDocumentWebView(
                url: url,
                textScale: textScale,
                initialScrollFile: initialScrollFile,
                initialScrollFraction: initialScrollFraction,
                onScroll: onScroll,
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

    /// 记录视口顶端可见的那一行文字，缩放后据此回位，避免内容跳走。
    /// 锚定对象是"顶边命中的字符"（caretRangeFromPoint 自上而下探测），
    /// 在其所在块内按字符偏移标记；块顶锚定在块上半截已滚出视口时会因行高变化跳行，
    /// 字符锚定保证缩放前后顶部是同一行文字。
    static let captureAnchorScript = """
    (function(){
      function textOffsetIn(block, node, offset) {
        var walker = block.ownerDocument.createTreeWalker(block, NodeFilter.SHOW_TEXT, null);
        var total = 0;
        var current;
        while ((current = walker.nextNode())) {
          if (current === node) { return total + offset; }
          total += current.textContent.length;
        }
        return -1;
      }
      function mark(block, charOffset, top) {
        var previous = document.querySelectorAll('[data-foofoil-zoom-anchor]');
        for (var i = 0; i < previous.length; i++) { previous[i].removeAttribute('data-foofoil-zoom-anchor'); }
        block.setAttribute('data-foofoil-zoom-anchor', String(charOffset));
        return top;
      }
      var x = Math.max(12, Math.floor(window.innerWidth / 2));
      for (var y = 2; y < 96; y += 6) {
        var range = document.caretRangeFromPoint(x, y);
        if (!range || !range.startContainer || range.startContainer.nodeType !== 3) { continue; }
        var block = range.startContainer.parentElement;
        while (block && block !== document.body) {
          var display = block.ownerDocument.defaultView.getComputedStyle(block).display;
          if (display !== 'inline') { break; }
          block = block.parentElement;
        }
        if (!block || block === document.body) { continue; }
        var charOffset = textOffsetIn(block, range.startContainer, range.startOffset);
        if (charOffset < 0) { continue; }
        range.setEnd(range.startContainer, Math.min(range.startOffset + 1, range.startContainer.textContent.length));
        var rects = range.getClientRects();
        var top = rects.length > 0 ? rects[0].top : block.getBoundingClientRect().top;
        return mark(block, charOffset, top);
      }
      var nodes = document.body
        ? document.body.querySelectorAll('p,h1,h2,h3,h4,h5,h6,li,blockquote,pre,td,th,figure,img,section')
        : [];
      for (var i = 0; i < nodes.length; i++) {
        var rect = nodes[i].getBoundingClientRect();
        if (rect.height > 0 && rect.bottom > 4) { return mark(nodes[i], 0, rect.top); }
      }
      return null;
    })();
    """

    /// 量取标记字符当前所在行的视口 top；无标记时返回 null。
    static let anchorTopScript = "(\(anchorTopFunction))()"

    private static let anchorTopFunction = """
    function() {
      var block = document.querySelector('[data-foofoil-zoom-anchor]');
      if (!block) { return null; }
      var target = parseInt(block.getAttribute('data-foofoil-zoom-anchor'), 10);
      if (isNaN(target) || target < 0) { return block.getBoundingClientRect().top; }
      var walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT, null);
      var total = 0, node = null, local = 0, current;
      while ((current = walker.nextNode())) {
        var length = current.textContent.length;
        if (total + length >= target) { node = current; local = target - total; break; }
        total += length;
      }
      var range = document.createRange();
      try {
        if (node && node.nodeType === 3 && node.textContent.length > 0) {
          var start = Math.max(0, Math.min(local, node.textContent.length - 1));
          range.setStart(node, start);
          range.setEnd(node, start + 1);
        } else {
          range.selectNodeContents(block);
        }
        var rects = range.getClientRects();
        if (rects.length > 0) { return rects[0].top; }
      } catch (e) {}
      return block.getBoundingClientRect().top;
    }
    """

    static func restoreAnchorScript(offset: Double) -> String {
        """
        (function(){
          var measure = \(anchorTopFunction);
          var top = measure();
          if (top === null) { return; }
          var delta = top - (\(offset));
          if (Math.abs(delta) > 0.5) { window.scrollBy(0, delta); }
        })();
        """
    }
}

/// 阅读位置采集：宿主注入的滚动监听经 script message 回传 (章节文件名, 视口位置)。
/// 页面自身脚本仍被禁用；这里的注入代码由宿主发起，不受页面 CSP 约束。
enum DocumentScrollPersistence {
    static let messageHandlerName = "foofoilDocumentScroll"

    /// 按 (文件名, scrollY, 最大滚动距离) 上报；file 用 location.pathname 推导。
    static let positionScript = """
    JSON.stringify({file: location.pathname.split('/').pop(), y: window.scrollY, max: document.documentElement.scrollHeight - window.innerHeight});
    """

    /// 滚动上报监听：前导 + 尾随节流 250ms，重复安装无害。
    static let reporterInstallScript = """
    (function(){
      if (window.__foofoilScrollReporter) { return; }
      window.__foofoilScrollReporter = true;
      var timer = null;
      var pending = false;
      function send() {
        var handlers = window.webkit && window.webkit.messageHandlers;
        if (!handlers || !handlers.foofoilDocumentScroll) { return; }
        handlers.foofoilDocumentScroll.postMessage({
          file: location.pathname.split('/').pop(),
          y: window.scrollY,
          max: document.documentElement.scrollHeight - window.innerHeight
        });
      }
      window.addEventListener('scroll', function() {
        if (timer != null) { pending = true; return; }
        send();
        timer = setTimeout(function() {
          timer = null;
          if (pending) { pending = false; send(); }
        }, 250);
      }, { passive: true });
    })();
    """
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
    let initialScrollFile: String?
    let initialScrollFraction: Double?
    let onScroll: (_ file: String, _ fraction: Double) -> Void
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
        // Coordinator 由 contentController 持有；销毁时必须移除，避免泄漏。
        webView.configuration.userContentController.add(
            context.coordinator, name: DocumentScrollPersistence.messageHandlerName
        )
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
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: DocumentScrollPersistence.messageHandlerName
        )
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: ExtensionDocumentWebView
        weak var webView: WKWebView?
        private var loadedURL: URL?
        private var targetIdentity: String?
        private var hasReportedFailure = false
        private var hasInstalledRuleList = false
        private var loadGeneration: UInt64 = 0
        private var appliedTextScale: Double = .nan
        private var textScaleGeneration: UInt64 = 0
        /// 本次加载待恢复的保存位置；只在 URL 变化时从 parent 捕获一次。
        private var pendingScrollFile: String?
        private var pendingScrollFraction: Double?

        init(_ parent: ExtensionDocumentWebView) {
            self.parent = parent
        }

        func invalidate() {
            loadedURL = nil
            targetIdentity = nil
            pendingScrollFile = nil
            pendingScrollFraction = nil
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
            pendingScrollFile = parent.initialScrollFile
            pendingScrollFraction = parent.initialScrollFraction
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
            Task { @MainActor [weak self] in
                await self?.performTextScale(scale, force: force, generation: generation)
            }
        }

        /// 加载完成后的按序收尾：文字缩放 → 恢复阅读位置 → 安装滚动上报。
        func loadDidFinish() {
            let scale = parent.textScale
            appliedTextScale = scale
            textScaleGeneration &+= 1
            let generation = textScaleGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performTextScale(scale, force: true, generation: generation)
                await self.restoreSavedScrollPosition()
                _ = try? await self.webView?.evaluateJavaScript(
                    DocumentScrollPersistence.reporterInstallScript
                )
            }
        }

        @MainActor
        private func performTextScale(_ scale: Double, force: Bool, generation: UInt64) async {
            guard textScaleGeneration == generation, let webView else { return }
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

        /// 恢复保存的阅读位置：仅当保存的章节与当前文件一致且 URL 未带锚点（锚点定位由 WebKit 完成）。
        @MainActor
        private func restoreSavedScrollPosition() async {
            let savedFile = pendingScrollFile
            let savedFraction = pendingScrollFraction
            pendingScrollFile = nil
            pendingScrollFraction = nil
            guard let webView,
                  savedFile == currentFileName(),
                  webView.url?.fragment == nil,
                  let savedFraction else {
                await reportCurrentScrollPosition()
                return
            }
            _ = try? await webView.evaluateJavaScript(
                "window.scrollTo(0, \(savedFraction) * (document.documentElement.scrollHeight - window.innerHeight));"
            )
            await reportCurrentScrollPosition()
        }

        /// 主动上报一次当前位置；换章或恢复后由此把成对的 (文件, 比例) 写回宿主。
        @MainActor
        private func reportCurrentScrollPosition() async {
            guard let webView,
                  let raw = try? await webView.evaluateJavaScript(
                      DocumentScrollPersistence.positionScript
                  ) as? String,
                  let data = raw.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            deliverScrollPosition(value)
        }

        @MainActor
        private func deliverScrollPosition(_ value: [String: Any]) {
            guard let file = value["file"] as? String, file == currentFileName(),
                  let y = (value["y"] as? NSNumber)?.doubleValue,
                  let maxScroll = (value["max"] as? NSNumber)?.doubleValue,
                  maxScroll.isFinite, maxScroll > 0 else { return }
            let fraction = min(max(y / maxScroll, 0), 1)
            parent.onScroll(file, fraction.isFinite ? fraction : 0)
        }

        private func currentFileName() -> String? {
            guard let url = webView?.url ?? loadedURL else { return nil }
            return ExtensionDocumentURLPolicy.fileURL(for: url)?.lastPathComponent
        }

        private func isCurrent(_ url: URL?) -> Bool {
            guard let url, let targetIdentity else { return false }
            return ExtensionDocumentURLPolicy.fileIdentity(
                ExtensionDocumentURLPolicy.fileURL(for: url) ?? url
            ) == targetIdentity
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == DocumentScrollPersistence.messageHandlerName,
                  let body = message.body as? [String: Any] else { return }
            Task { @MainActor [weak self] in
                self?.deliverScrollPosition(body)
            }
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
            loadDidFinish()
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
