import WebKit

/// 在每个 frame 的独立脚本世界登记令牌；宿主按 WKFrameInfo 查找，跨域 iframe 也不会漏检。
@MainActor
final class WebSearchFrames: NSObject, WKScriptMessageHandler {
    static let handlerName = "foofoilSearchFrame"
    weak var search: FoilContentSearch?
    weak var webView: WKWebView?

    static func install(on configuration: WKWebViewConfiguration, handler: WebSearchFrames) {
        let controller = configuration.userContentController
        controller.add(handler, contentWorld: .defaultClient, name: handlerName)
        controller.addUserScript(WKUserScript(source: """
            (() => {
              const token = String(Math.random()) + String(Date.now());
              window.__foofoilSearchFrameToken = token;
              window.webkit.messageHandlers.foofoilSearchFrame.postMessage(token);
            })();
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient))
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let token = message.body as? String, let webView else { return }
        search?.registerWebFrame(message.frameInfo, token: token, webView: webView)
    }
}

extension WKWebView {
    func evaluateSearchScript(_ script: String, frame: WKFrameInfo? = nil) async throws -> Any? {
        try await evaluateJavaScript(script, in: frame, contentWorld: .defaultClient)
    }
    func evaluateSearchScript(_ script: String, frame: WKFrameInfo? = nil, completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)?) {
        evaluateJavaScript(script, in: frame, in: .defaultClient) { result in
            switch result {
            case .success(let value): completionHandler?(value, nil)
            case .failure(let error): completionHandler?(nil, error)
            }
        }
    }
}
