import AppKit
import PDFKit
import SwiftUI
import WebKit

/// 系统预览服务位于另一进程；查找时使用系统生成的 HTML/PDF，保持可定位的本机正文。
struct SearchableQuickLookView: View {
    let url: URL
    var shouldHideBorder = true
    @ObservedObject var search: FoilContentSearch
    @State private var preview: SearchDocumentPreview?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let preview {
                if preview.url.pathExtension.lowercased() == "pdf" {
                    SearchDocumentPDF(url: preview.url)
                } else {
                    SearchDocumentHTML(url: preview.url, directory: preview.directory, search: search, tracksSlides: url.pathExtension.lowercased() == "pptx")
                }
            } else if search.isPresented {
                if failed { ContentUnavailableView("Content Search Failed", systemImage: "doc.text.magnifyingglass") }
                else { ProgressView("Searching Content") }
            } else {
                QuickLookModeView(url: url, shouldHideBorder: shouldHideBorder)
            }
        }
        .task(id: "\(url.absoluteString):\(search.isPresented)") {
            guard search.isPresented, preview == nil else { return }
            failed = false
            do {
                let preview = try await Task.detached(priority: .userInitiated) { try SearchDocumentPreview.make(url: url) }.value
                guard !Task.isCancelled else { return }
                self.preview = preview
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                search.reportFailure()
            }
        }
        .onChange(of: url) { _, _ in preview = nil; failed = false }
    }
}

/// 只清理本次生成的临时目录，不修改源文件和 Quick Look 的系统缓存。
nonisolated final class SearchDocumentPreview: @unchecked Sendable {
    let url: URL
    let directory: URL
    init(url: URL, directory: URL) { self.url = url; self.directory = directory }
    deinit { try? FileManager.default.removeItem(at: directory) }

    static func make(url: URL) throws -> SearchDocumentPreview {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foofoil-search-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            // 系统生成器保留 Office/iWork 的文字、表格和版式，不依赖第三方解析器。
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            process.arguments = ["-p", "-o", directory.path, url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
            process.waitUntilExit()
            timeout.cancel()
            let files = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
            if let pdf = files.first(where: { $0.lastPathComponent == "Preview.pdf" }) {
                return SearchDocumentPreview(url: pdf, directory: directory)
            }
            if let html = files.first(where: { $0.lastPathComponent == "Preview.html" }) {
                let document = try XMLDocument(contentsOf: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
                // 多工作表预览原本依赖脚本切换 iframe。展开为同一正文，保证未选中的表也可搜索。
                let anchors = try document.nodes(forXPath: "//a[@href]").compactMap { $0 as? XMLElement }
                var sources: [URL] = []
                for anchor in anchors {
                    guard let href = anchor.attribute(forName: "href")?.stringValue,
                          href.lowercased().hasSuffix(".html"),
                          !href.contains(":") else { continue }
                    let source = html.deletingLastPathComponent().appendingPathComponent(href).standardizedFileURL
                    guard source.path.hasPrefix(directory.path + "/"), !sources.contains(source), FileManager.default.fileExists(atPath: source.path) else { continue }
                    sources.append(source)
                }
                if sources.count > 1 {
                    let body = sources.enumerated().map { index, source in
                        "<section><iframe title='\(index + 1)' src='\(source.lastPathComponent)' style='width:100%;height:85vh;border:0'></iframe></section>"
                    }.joined()
                    let combined = html.deletingLastPathComponent().appendingPathComponent("Search.html")
                    try "<!doctype html><html><head><meta charset='utf-8'></head><body style='margin:0'>\(body)</body></html>".write(to: combined, atomically: true, encoding: .utf8)
                    return SearchDocumentPreview(url: combined, directory: directory)
                }
                return SearchDocumentPreview(url: html, directory: directory)
            }
            // 少数系统生成器只产图片。OOXML 仍可从文档结构取出正文供查找。
            let text = try OfficeSearchText.html(url: url)
            let target = directory.appendingPathComponent("Search.html")
            try text.write(to: target, atomically: true, encoding: .utf8)
            return SearchDocumentPreview(url: target, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

/// 仅用于系统不能生成可搜索预览的 OOXML；按文稿顺序展示正文，不把 XML 元数据当作内容。
nonisolated enum OfficeSearchText {
    /// 系统 PowerPoint HTML 的每个 .slide 对应一张幻灯片，保留退出搜索后的页码。
    static let slideIndexScript = "Array.from(document.querySelectorAll('div.slide')).forEach((slide, index) => slide.setAttribute('data-foofoil-slide', String(index)))"

    static func html(url: URL) throws -> String {
        let archive = try PPTXArchive(url: url)
        let paths: [String]
        let localName: String
        if archive.contains("ppt/presentation.xml") {
            let document = try PPTXDocument.parseXML(archive.data(for: "ppt/presentation.xml"))
            let relationships = try PPTXDocument.parseXML(archive.data(for: "ppt/_rels/presentation.xml.rels"))
            var targets: [String: String] = [:]
            for case let node as XMLElement in try relationships.nodes(forXPath: "/*/*") {
                if let id = node.attribute(forName: "Id")?.stringValue, let target = node.attribute(forName: "Target")?.stringValue,
                   node.attribute(forName: "TargetMode")?.stringValue != "External" {
                    targets[id] = try PPTXDocument.slidePath(target)
                }
            }
            paths = try document.nodes(forXPath: "/*/*[local-name()='sldIdLst']/*").compactMap { node in
                guard let element = node as? XMLElement,
                      let id = element.attributes?.first(where: { $0.localName == "id" && $0.uri != nil })?.stringValue else { return nil }
                return targets[id]
            }
            localName = "t"
        } else if archive.contains("word/document.xml") {
            paths = ["word/document.xml"]; localName = "t"
        } else {
            throw CocoaError(.fileReadUnknown)
        }
        var body = ""
        var bytes = 0
        for (index, path) in paths.enumerated() {
            let data = try archive.data(for: path, maxBytes: 16 << 20)
            bytes += data.count
            guard bytes <= 64 << 20 else { throw CocoaError(.fileReadTooLarge) }
            let document = try PPTXDocument.parseXML(data)
            let paragraphs = try document.nodes(forXPath: "//*[local-name()='p']")
            let text = try paragraphs.map { paragraph in
                try paragraph.nodes(forXPath: ".//*[local-name()='\(localName)']").compactMap(\.stringValue).joined()
            }.map { "<p>\(escape($0))</p>" }.joined()
            body += "<section data-foofoil-slide='\(index)' style='padding:24px;border-bottom:1px solid #aaa'>\(text)</section>"
        }
        guard !body.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return "<!doctype html><html><head><meta charset='utf-8'><style>:root{color-scheme:light dark}body{margin:0;font:16px -apple-system;line-height:1.6;background:Canvas;color:CanvasText}</style></head><body>\(body)</body></html>"
    }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

private struct SearchDocumentHTML: NSViewRepresentable {
    let url: URL
    let directory: URL
    let search: FoilContentSearch
    let tracksSlides: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = ExtensionDocumentWebViewFactory.makeConfiguration()
        WebSearchFrames.install(on: configuration, handler: context.coordinator.frames)
        let view = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.frames.webView = view
        context.coordinator.frames.search = search
        search.resetWebFrames(webView: view)
        context.coordinator.view = view
        context.coordinator.tracksSlides = tracksSlides
        view.navigationDelegate = context.coordinator
        Task { @MainActor in
            guard let rules = await DocumentContentRuleList.shared() else { search.reportFailure(); return }
            view.configuration.userContentController.add(rules)
            view.loadFileURL(url.resolvingSymlinksInPath(), allowingReadAccessTo: directory.resolvingSymlinksInPath())
        }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: WebSearchFrames.handlerName, contentWorld: .defaultClient)
        view.stopLoading()
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var view: WKWebView?
        let frames = WebSearchFrames()
        var tracksSlides = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if tracksSlides { webView.evaluateSearchScript(OfficeSearchText.slideIndexScript, completionHandler: nil) }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { frames.search?.reportFailure() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { frames.search?.reportFailure() }
    }
}

private struct SearchDocumentPDF: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {}
}
