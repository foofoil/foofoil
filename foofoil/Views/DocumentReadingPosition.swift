import AppKit
import WebKit

/// 按正文来源与呈现通道保存位置，避免切换列表文件或 Markdown 预览后套用错误坐标。
nonisolated public struct DocumentReadingPosition: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var page: Int? = nil
}

extension AppState {
    func readingPositionKey(_ surface: String) -> String {
        let source = fileList?.currentID ?? sourceFingerprint ?? textURL?.path ?? imageURL?.path ?? webURL?.absoluteString ?? id.uuidString
        return surface + ":" + source
    }

    func noteReadingPosition(_ position: DocumentReadingPosition, key: String) {
        guard position.x.isFinite, position.y.isFinite, position.x >= 0, position.y >= 0,
              documentReadingPositions[key] != position else { return }
        documentReadingPositions[key] = position
        scheduleDocumentScrollSave()
    }
}

/// 等正文布局完成后恢复，再监听可视区；恢复期间不把临时的顶部坐标覆盖到历史。
@MainActor
final class DocumentScrollTracker {
    private weak var scrollView: NSScrollView?
    private weak var state: AppState?
    private var key: String?
    private var observer: NSObjectProtocol?
    private var restorationGeneration = 0
    private var isRestoring = false

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func bind(_ scroll: NSScrollView, state: AppState?, surface: String, contentChanged: Bool = false) {
        guard let state else { return }
        let key = state.readingPositionKey(surface)
        guard self.scrollView !== scroll || self.key != key || contentChanged else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.scrollView = scroll
        self.state = state
        self.key = key
        isRestoring = true
        restorationGeneration += 1
        let generation = restorationGeneration
        let position = state.documentReadingPositions[key] ?? .init(x: 0, y: 0)
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.record() }
            }
        DispatchQueue.main.async { [weak self, weak scroll] in
            guard let self, let scroll, self.restorationGeneration == generation else { return }
            scroll.layoutSubtreeIfNeeded()
            if position.y > 0, let text = scroll.documentView as? NSTextView { text.sizeToFit() }
            do {
                let clip = scroll.contentView
                let target = NSRect(origin: NSPoint(x: position.x, y: position.y), size: clip.bounds.size)
                clip.scroll(to: clip.constrainBoundsRect(target).origin)
                scroll.reflectScrolledClipView(clip)
            }
            self.isRestoring = false
        }
    }

    private func record() {
        guard !isRestoring, let scrollView, let state, let key else { return }
        let origin = scrollView.contentView.bounds.origin
        state.noteReadingPosition(.init(x: max(0, origin.x), y: max(0, origin.y)), key: key)
    }
}

/// WebKit 通道共用滚动回传；独立脚本世界避免与网页的变量和事件处理冲突。
@MainActor
final class WebDocumentScrollTracker: NSObject, WKScriptMessageHandler {
    private weak var state: AppState?
    private weak var webView: WKWebView?
    private var key = ""
    private var savedPosition: DocumentReadingPosition?
    private var isLoading = true
    private static let handler = "foofoilReadingPosition"

    func install(on webView: WKWebView, state: AppState?, surface: String) {
        self.webView = webView
        updateSource(state: state, surface: surface)
        let controller = webView.configuration.userContentController
        controller.add(WeakHandler(self), contentWorld: .defaultClient, name: Self.handler)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient))
    }

    func updateSource(state: AppState?, surface: String) {
        self.state = state
        let nextKey = state?.readingPositionKey(surface) ?? ""
        if nextKey != key {
            key = nextKey
            savedPosition = state?.documentReadingPositions[key]
        }
    }

    func beginLoading() { isLoading = true }

    func restore() {
        guard let position = savedPosition, let webView else { isLoading = false; return }
        webView.callAsyncJavaScript("window.scrollTo(x, y);", arguments: ["x": position.x, "y": position.y],
            in: nil, in: .defaultClient) { [weak self] _ in self?.isLoading = false }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !isLoading, message.webView === webView, message.frameInfo.isMainFrame,
              let value = message.body as? [String: Double], let x = value["x"], let y = value["y"] else { return }
        let position = DocumentReadingPosition(x: max(0, x), y: max(0, y))
        savedPosition = position
        state?.noteReadingPosition(position, key: key)
    }

    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: WebDocumentScrollTracker?
        init(_ target: WebDocumentScrollTracker) { self.target = target }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(controller, didReceive: message)
        }
    }

    private static let script = """
    (() => {
        let pending = false;
        window.addEventListener('scroll', () => {
            if (pending) return;
            pending = true;
            requestAnimationFrame(() => {
                pending = false;
                window.webkit.messageHandlers.foofoilReadingPosition.postMessage({x: scrollX, y: scrollY});
            });
        }, {passive: true});
    })();
    """
}
