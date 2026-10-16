import SwiftUI
import QuickLookUI

/// 每个浮箔独立持有预览视图，不使用全局 Quick Look 面板。
struct QuickLookModeView: NSViewRepresentable {
    let url: URL
    /// 文档统一为固定边框时，按代码箔的圆角裁切预览视图，避免 Quick Look 原始视图直角贴到玻璃边框内。
    var shouldHideBorder: Bool = true

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        applyCorner(to: view)
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url {
            view.previewItem = url as NSURL
        }
        applyCorner(to: view)
    }

    private func applyCorner(to view: QLPreviewView) {
        // Quick Look 原生视图不会跟随 SwiftUI 的 cornerRadius；直接设图层圆角，确保目录/Office 文档在固定边框时不是直角。
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.cornerRadius = shouldHideBorder ? 0 : 8
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        // SwiftUI 切换内容时也必须释放预览服务，不能只依赖窗口关闭。
        view.close()
    }
}
