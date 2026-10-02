import SwiftUI
import QuickLookUI

/// 每个浮箔独立持有预览视图，不使用全局 Quick Look 面板。
struct QuickLookModeView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        // SwiftUI 切换内容时也必须释放预览服务，不能只依赖窗口关闭。
        view.close()
    }
}
