import SwiftUI
import QuickLookUI

/// Icon Composer 的远程预览会吞掉鼠标事件；静态图标由宿主直接承接拖窗。
final class FoilQuickLookPreviewView: QLPreviewView {
    var dragsWindow = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return dragsWindow ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        if dragsWindow { window?.performDrag(with: event) }
        else { super.mouseDown(with: event) }
    }
}

/// 每个浮箔独立持有预览视图，不使用全局 Quick Look 面板。
struct QuickLookModeView: NSViewRepresentable {
    let url: URL
    /// 文档统一为固定边框时，按代码箔的圆角裁切预览视图，避免 Quick Look 原始视图直角贴到玻璃边框内。
    var shouldHideBorder: Bool = true

    func makeNSView(context: Context) -> QLPreviewView {
        let view = FoilQuickLookPreviewView(frame: .zero, style: .normal)!
        view.dragsWindow = url.pathExtension.lowercased() == "icon"
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        applyCorner(to: view)
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        (view as? FoilQuickLookPreviewView)?.dragsWindow = url.pathExtension.lowercased() == "icon"
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
