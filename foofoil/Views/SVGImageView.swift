import SwiftUI
import WebKit

/// AppKit 的 SVG 解码不完整（use 的填充继承、滤镜等）；交给 WebKit 按 SVG 标准绘制。
/// 作为图片载入而非内联文档，SVG 中的脚本、外部资源和交互不会成为网页内容。
struct SVGImageView: View {
    let url: URL
    let contentMode: ContentMode
    let colorHex: String?
    @State private var data: Data?

    var body: some View {
        Group {
            if let data {
                SVGWebImage(data: data, contentMode: contentMode, colorHex: colorHex)
            } else {
                Color.clear
            }
        }
        // WKWebView 在 SwiftUI 命中里是平台视图节点：命中它等于命中平台视图，父级的拖动、双击与右键菜单
        // 都收不到事件。上层补一块自身不处理事件的透明命中层，把命中交还给 SwiftUI；SVG 画面没有可交互
        // 内容，不需要真的穿透到网页层。
        .overlay { Color.clear.contentShape(Rectangle()) }
        .task(id: url) {
            data = nil
            let loaded = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url)
            }.value
            guard !Task.isCancelled else { return }
            data = loaded
        }
    }
}

struct SVGWebImage: NSViewRepresentable {
    let data: Data
    let contentMode: ContentMode
    let colorHex: String?

    // 图片不接收鼠标事件；SwiftUI 命中由 SVGImageView 的透明命中层兜住，二者一起保留父视图的
    // 拖动、双击、滚动和右键菜单。
    final class ImageWebView: WKWebView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
        var renderedHTML: String?
    }

    static func makeWebView() -> ImageWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = ImageWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func makeNSView(context: Context) -> ImageWebView { Self.makeWebView() }

    func updateNSView(_ view: ImageWebView, context: Context) {
        let html = Self.html(data: data, contentMode: contentMode, colorHex: colorHex)
        guard view.renderedHTML != html else { return }
        view.renderedHTML = html
        view.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleNSView(_ view: ImageWebView, coordinator: ()) {
        view.stopLoading()
    }

    static func html(data: Data, contentMode: ContentMode, colorHex: String?) -> String {
        let source = "data:image/svg+xml;base64," + data.base64EncodedString()
        let fit = contentMode == .fill ? "cover" : "contain"
        // 改色仍使用整张图的 alpha 蒙版，不覆盖 SVG 内部各图层的透明度。
        let validColor = colorHex.flatMap { NSColor(hex: $0) }?.toHex()
        let content: String
        if let validColor {
            content = "<div style=\"background:\(validColor);mask:url('\(source)') center / \(fit) no-repeat\"></div>"
        } else {
            content = "<img src=\"\(source)\" style=\"object-fit:\(fit)\">"
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}img,body>div{display:block;width:100%;height:100%}</style>
        </head><body>\(content)</body></html>
        """
    }
}
