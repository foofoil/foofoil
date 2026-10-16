import AppKit
import Combine
import SwiftUI

/// 桌面伴随窗口和全屏覆盖层都使用独立的原生 responder 子树，区分正文与侧栏焦点。
final class NavigatorHostingView: NSHostingView<NavigatorPanelView> {
    let appState: AppState
    private var focusRequest: AnyCancellable?

    init(appState: AppState, isFullScreenOverlay: Bool = false) {
        self.appState = appState
        super.init(rootView: NavigatorPanelView(appState: appState, isFullScreenOverlay: isFullScreenOverlay))
        observeFocusRequests(isFullScreenOverlay: isFullScreenOverlay)
    }

    @MainActor required init(rootView: NavigatorPanelView) {
        appState = rootView.appState
        super.init(rootView: rootView)
        observeFocusRequests(isFullScreenOverlay: rootView.isFullScreenOverlay)
    }

    private func observeFocusRequests(isFullScreenOverlay: Bool) {
        focusRequest = appState.$navigatorFocusRequest.dropFirst().sink { [weak self] _ in
            // AXPress 不一定产生 mouseDown；行激活同样须把后续按键交给可见的侧栏。
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, window.isVisible,
                      self.appState.isFullScreen == isFullScreenOverlay else { return }
                window.makeKey()
                window.makeFirstResponder(self)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    static func enclosing(_ responder: NSResponder?) -> NavigatorHostingView? {
        var current = responder
        var seen = Set<ObjectIdentifier>()
        while let candidate = current, seen.insert(ObjectIdentifier(candidate)).inserted {
            if let host = candidate as? NavigatorHostingView { return host }
            // AppKit 的共享 field editor 可能挂在窗口上，通过委托找回侧栏搜索框。
            if let editor = candidate as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
                current = field
                continue
            }
            if let view = candidate as? NSView { current = view.superview ?? view.nextResponder }
            else { current = candidate.nextResponder }
        }
        return nil
    }
}

struct FullScreenNavigatorHost: NSViewRepresentable {
    let appState: AppState
    func makeNSView(context: Context) -> NavigatorHostingView {
        NavigatorHostingView(appState: appState, isFullScreenOverlay: true)
    }
    func updateNSView(_ nsView: NavigatorHostingView, context: Context) {}
}

extension NSWindow {
    /// 先为侧栏行点击取得键盘焦点，再把原事件交给按钮；搜索框随后仍可取得自己的输入焦点。
    func prepareNavigatorFocus(for event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        let hit = contentView?.hitTest(event.locationInWindow)
        if let host = NavigatorHostingView.enclosing(hit) {
            makeKey()
            makeFirstResponder(host)
        } else if NavigatorHostingView.enclosing(firstResponder) != nil {
            makeFirstResponder(nil)
        }
    }

    func synchronizeNavigatorFocus(_ state: AppState?) {
        guard let state else { return }
        let focused = isKeyWindow && NavigatorHostingView.enclosing(firstResponder)?.appState === state
        if state.isNavigatorFocused != focused { state.isNavigatorFocused = focused }
    }
}
