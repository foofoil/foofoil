//
//  CSVTableView.swift
//  foofoil
//
//  Created by tolg on 2026/7/11.
//

import SwiftUI
import WebKit

/// 轻量 CSV 解析器，支持双引号、转义双引号与引号内换行。
public enum CSVParser {
    public static func parse(_ content: String) -> [[String]] {
        let content = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
        guard !content.isEmpty else { return [] }

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isInsideQuotes = false
        var index = content.startIndex

        while index < content.endIndex {
            let character = content[index]

            if character == "\"" {
                let nextIndex = content.index(after: index)
                if isInsideQuotes, nextIndex < content.endIndex, content[nextIndex] == "\"" {
                    field.append("\"")
                    index = nextIndex
                } else {
                    isInsideQuotes.toggle()
                }
            } else if character == ",", !isInsideQuotes {
                row.append(field)
                field = ""
            } else if character.isNewline, !isInsideQuotes {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }

            index = content.index(after: index)
        }

        if !row.isEmpty || !field.isEmpty || content.last == "," {
            row.append(field)
            rows.append(row)
        }

        return rows
    }
}

/// CSV 的基础只读表格视图：首行作为表头，支持横向和纵向滚动。
public struct CSVTableView: View {
    private let rows: [[String]]
    private let columnCount: Int
    private let cellWidth: CGFloat
    private let fontSize: CGFloat

    private var appState: AppState?

    public init(content: String, fontSize: Double = AppState.defaultTextFontSize, appState: AppState? = nil) {
        self.appState = appState
        let parsedRows = CSVParser.parse(content)
        self.rows = parsedRows
        self.columnCount = parsedRows.map(\.count).max() ?? 0
        self.fontSize = CGFloat(fontSize)
        // 列宽与字号按比例缩放，保证放大后单元格内容仍有足够空间。
        self.cellWidth = max(90, 140 * CGFloat(fontSize / AppState.defaultTextFontSize))
    }

    public var body: some View {
        CSVWebTable(rows: rows, columnCount: columnCount, cellWidth: cellWidth, fontSize: fontSize, appState: appState)
    }
}

private struct CSVWebTable: NSViewRepresentable {
    let rows: [[String]]
    let columnCount: Int
    let cellWidth: CGFloat
    let fontSize: CGFloat
    var appState: AppState?
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: ExtensionDocumentWebViewFactory.makeConfiguration())
        view.navigationDelegate = context.coordinator
        context.coordinator.scrollTracker.install(on: view, state: appState, surface: "csv")
        view.setValue(false, forKey: "drawsBackground")
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let body = rows.enumerated().map { rowIndex, row in
            "<tr>" + (0..<columnCount).map { col in
                let tag = rowIndex == 0 ? "th" : "td"
                return "<\(tag)>\(escape(col < row.count ? row[col] : ""))</\(tag)>"
            }.joined() + "</tr>"
        }.joined()
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root{color-scheme:\(colorScheme == .dark ? "dark" : "light");}body{margin:12px;background:transparent;color:CanvasText;font: \(fontSize)px -apple-system;}
        table{border-collapse:collapse;table-layout:fixed;}td,th{box-sizing:content-box;min-width:\(cellWidth)px;max-width:\(cellWidth)px;width:\(cellWidth)px;min-height:30px;padding:5px 8px;border:0.5px solid color-mix(in srgb,CanvasText 16%,transparent);text-align:left;white-space:pre-wrap;overflow-wrap:anywhere;}th{font-weight:600;background:color-mix(in srgb,CanvasText 12%,transparent);}
        </style></head><body><table>\(body)</table></body></html>
        """
        guard context.coordinator.html != html else { return }
        context.coordinator.scrollTracker.updateSource(state: appState, surface: "csv")
        context.coordinator.scrollTracker.beginLoading()
        context.coordinator.html = html
        view.loadHTMLString(html, baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var html = ""
        let scrollTracker = WebDocumentScrollTracker()
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { scrollTracker.restore() }
    }
}
