import AppKit
import WebKit

nonisolated struct MarkdownMermaidBlock {
    let htmlRange: NSRange
    let source: String

    // 只匹配 cmark 生成的代码块标签。源码里的 HTML 在这个阶段已经转义。
    private static let pattern = try! NSRegularExpression(
        pattern: #"<pre><code class="language-(?i:mermaid)">([^<]*)</code></pre>"#
    )

    static func blocks(in html: String) -> [Self] {
        let text = html as NSString
        return pattern.matches(in: html, range: NSRange(location: 0, length: text.length)).map { match in
            let source = text.substring(with: match.range(at: 1))
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
            return Self(htmlRange: match.range, source: source)
        }
    }
}

@MainActor
final class MarkdownMermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MarkdownMermaidRenderer()

    private let world = WKContentWorld.world(name: "Foofoil Mermaid")
    private let images = NSCache<NSString, NSImage>()
    private var webView: WKWebView?
    private var loading: CheckedContinuation<Bool, Never>?
    private var pending: Task<NSImage?, Never>?

    private override init() {
        super.init()
        images.totalCostLimit = 24 * 1024 * 1024
        images.countLimit = 32
    }

    func render(_ source: String, isDark: Bool) async -> NSImage? {
        guard !Task.isCancelled, source.utf8.count <= 50_000 else { return nil }
        let key = ((isDark ? "dark:" : "light:") + source) as NSString
        if let image = images.object(forKey: key) { return image }

        // render 与截图共用一个页面，串行使用，避免多窗口的图表互相覆盖。
        let previous = pending
        let work = Task { [weak self] in
            _ = await previous?.value
            guard !Task.isCancelled, let self else { return nil as NSImage? }
            if let image = self.images.object(forKey: key) { return image }
            guard let image = await self.renderImage(source, isDark: isDark) else { return nil }
            let pixels = image.representations.first
            let cost = (pixels?.pixelsWide ?? 0) * (pixels?.pixelsHigh ?? 0) * 4
            self.images.setObject(image, forKey: key, cost: cost)
            return image
        }
        pending = work
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func renderImage(_ source: String, isDark: Bool) async -> NSImage? {
        guard let view = await preparedWebView(), !Task.isCancelled else { return nil }
        view.setFrameSize(NSSize(width: 1024, height: 768))
        do {
            let result = try await view.callAsyncJavaScript(
                Self.renderScript,
                arguments: ["source": source, "theme": isDark ? "dark" : "default"],
                in: nil, contentWorld: world
            )
            guard !Task.isCancelled, let size = result as? [Double], size.count == 2,
                  (1...1600).contains(size[0]), (1...1600).contains(size[1]) else { return nil }
            let bounds = CGRect(x: 0, y: 0, width: size[0], height: size[1])
            view.setFrameSize(bounds.size)
            let snapshot = WKSnapshotConfiguration()
            snapshot.rect = bounds
            snapshot.afterScreenUpdates = true
            return try await view.takeSnapshot(configuration: snapshot)
        } catch {
            return nil
        }
    }

    private func preparedWebView() async -> WKWebView? {
        if let webView { return webView }
        guard let url = Bundle.main.url(forResource: "mermaid-12.3.0.min", withExtension: "js") else { return nil }
        let script = await Task.detached(priority: .userInitiated) {
            try? String(contentsOf: url, encoding: .utf8)
        }.value
        guard let script, !Task.isCancelled else { return nil }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world)
        )

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = self
        let loaded = await withCheckedContinuation { continuation in
            loading = continuation
            // 页面只接收本地脚本和通过参数传入的图表源码，阻止外部资源、子帧和网络请求。
            view.loadHTMLString("""
                <!doctype html><html><head><meta charset="utf-8">
                <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; base-uri 'none'; form-action 'none'">
                <style>html,body{margin:0;overflow:hidden;background:transparent}svg{display:block}</style>
                </head><body></body></html>
                """, baseURL: nil)
        }
        guard loaded else { return nil }
        webView = view
        return view
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url?.absoluteString == "about:blank" && loading != nil ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        self.webView = nil
        finishLoading(false)
    }

    private func finishLoading(_ loaded: Bool) {
        let continuation = loading
        loading = nil
        continuation?.resume(returning: loaded)
    }

    private static let renderScript = """
        const api = globalThis.mermaid;
        document.body.replaceChildren();
        try {
            api.initialize({
                startOnLoad: false,
                securityLevel: 'strict',
                suppressErrorRendering: true,
                theme
            });
            const {svg} = await api.render('foofoilDiagram', source);
            document.body.innerHTML = svg;
            const image = document.body.firstElementChild;
            if (!(image instanceof SVGSVGElement)) return null;
            const box = image.viewBox.baseVal;
            const intrinsic = image.getBoundingClientRect();
            const width = box.width || intrinsic.width;
            const height = box.height || intrinsic.height;
            if (!(width > 0 && height > 0)) return null;
            const scale = Math.min(1, 1600 / width, 1600 / height);
            const w = Math.ceil(width * scale);
            const h = Math.ceil(height * scale);
            image.style.setProperty('width', w + 'px', 'important');
            image.style.setProperty('height', h + 'px', 'important');
            image.style.setProperty('max-width', 'none', 'important');
            return [w, h];
        } catch {
            document.body.replaceChildren();
            return null;
        }
        """
}

@MainActor
final class MarkdownMermaidAttachmentCell: NSTextAttachmentCell {
    nonisolated override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFragment: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        // 附件可以把排版行撑高，不能沿用排版器拟定的行高。
        let size = cellSize()
        guard size.width > 0 else { return .zero }
        let available = max(1, lineFragment.width - 2 * textContainer.lineFragmentPadding)
        let scale = min(1, available / size.width)
        let baseline = cellBaselineOffset()
        return NSRect(x: baseline.x * scale, y: baseline.y * scale,
                      width: size.width * scale, height: size.height * scale)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        image?.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
    }
}
