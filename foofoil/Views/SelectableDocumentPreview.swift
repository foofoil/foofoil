import SwiftUI
import AppKit

/// Word/富文本使用 TextKit 保留选择与复制；导入失败时仍可回到系统 Quick Look。
struct SelectableDocumentPreview: View {
    let url: URL
    let shouldHideBorder: Bool
    var search: FoilContentSearch? = nil
    @State private var document: NSAttributedString?

    static func supports(_ url: URL) -> Bool {
        ["doc", "docx", "docm", "odt", "rtf", "rtfd"].contains(url.pathExtension.lowercased())
    }

    var body: some View {
        Group {
            if let document {
                DocumentTextPreview(document: document)
            } else {
                if let search {
                    SearchableQuickLookView(url: url, shouldHideBorder: shouldHideBorder, search: search)
                } else { QuickLookModeView(url: url, shouldHideBorder: shouldHideBorder) }
            }
        }
        .task(id: url) {
            document = nil
            // AppKit 文档导入在主线程执行；任务按 URL 隔离，切换文件不会沿用旧文本。
            await Task.yield()
            guard !Task.isCancelled else { return }
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled else { return }
            let type: NSAttributedString.DocumentType
            switch url.pathExtension.lowercased() {
            case "doc": type = .docFormat
            case "docx", "docm": type = .officeOpenXML
            case "odt": type = .openDocument
            case "rtfd":
                document = try? NSAttributedString(url: url, options: [:], documentAttributes: nil)
                return
            default: type = .rtf
            }
            guard let data else { return }
            document = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil)
        }
    }
}

private struct DocumentTextPreview: NSViewRepresentable {
    let document: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        // 富文档保留作者的文字颜色，使用白色纸面，避免深色系统外观下黑字落在深色背景。
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = true
        text.backgroundColor = .white
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 24, height: 24)
        text.textStorage?.setAttributedString(document)
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let text = view.documentView as? NSTextView,
              text.textStorage?.isEqual(to: document) != true else { return }
        text.textStorage?.setAttributedString(document)
    }
}
