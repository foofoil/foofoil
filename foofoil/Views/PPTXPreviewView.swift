import SwiftUI
import QuickLookUI

/// 系统预览只接受父视图分配的画布；其内部文档固有尺寸不参与 SwiftUI 全屏布局。
struct PPTXPreviewView: NSViewRepresentable {
    let url: URL

    final class Canvas: NSView {
        let preview = QLPreviewView(frame: .zero, style: .normal)!

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            preview.shouldCloseWithWindow = false
            preview.autostarts = false
            preview.autoresizingMask = [.width, .height]
            addSubview(preview)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        override func layout() {
            super.layout()
            preview.frame = bounds
        }
    }

    func makeNSView(context: Context) -> Canvas {
        let canvas = Canvas(frame: .zero)
        canvas.preview.previewItem = url as NSURL
        return canvas
    }

    func updateNSView(_ canvas: Canvas, context: Context) {
        if canvas.preview.previewItem?.previewItemURL != url {
            canvas.preview.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ canvas: Canvas, coordinator: ()) {
        canvas.preview.close()
    }
}
