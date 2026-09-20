//
//  DocumentStylePanelController.swift
//  foofoil
//
//  Created by tolg on 2026/9/20.
//

import AppKit
import SwiftUI

/// 文档样式面板：背景颜色、文字颜色、字体、行间距、段落间距都在一个窗口里，
/// 直接写在当前箔的 AppState 上（随后照常进历史）。面板属于打开它的那扇箔：
/// 箔窗关闭或 ⌘K 重置时一并收起，避免样式落到其他窗口。
@MainActor
final class DocumentStylePanelController: NSWindowController {
    static let shared = DocumentStylePanelController()

    /// 面板当前服务的箔；`NSWindowController` 已有 `owner`，这里另起名字。
    private(set) weak var attachedState: AppState?

    private convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = NSLocalizedString("Document Style", comment: "")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        self.init(window: panel)
    }

    /// 打开面板并绑定到指定箔；已打开时直接改绑，不新建窗口。
    func show(for appState: AppState) {
        attachedState = appState
        if let window {
            window.contentView = NSHostingView(rootView: DocumentStyleView(appState: appState))
            if !window.isVisible {
                window.center()
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// 收起属于该箔的面板；面板不属于它时不动（可能正被另一扇箔使用）。
    func dismiss(ownedBy appState: AppState) {
        guard attachedState === appState else { return }
        attachedState = nil
        window?.contentView = nil
        close()
    }
}
