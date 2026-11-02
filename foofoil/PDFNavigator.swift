import AppKit
import PDFKit
import SwiftUI
import FoofoilExtensionKit

/// 与当前 PDFView 共用文档和跳转目标，页码选择与正文滚动始终使用同一份状态。
@MainActor final class PDFNavigator {
    static let pagesID = "builtin.pdf-pages"
    static let outlineID = "builtin.pdf-outline"
    weak var view: PDFView?
    let url: URL
    private var destinations: [String: PDFDestination] = [:]
    private var outlineItems: [NavigatorItem] = []

    init(view: PDFView, url: URL) {
        self.view = view
        self.url = url
        func append(_ parent: PDFOutline, parentID: String?) {
            for index in 0..<parent.numberOfChildren {
                guard let child = parent.child(at: index) else { continue }
                let id = (parentID ?? "pdf-outline") + ".\(index)"
                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                destinations[id] = destination
                outlineItems.append(.init(id: id, parentID: parentID, title: child.label ?? "", symbolName: "text.alignleft"))
                append(child, parentID: id)
            }
        }
        if let root = view.document?.outlineRoot { append(root, parentID: nil) }
    }

    var contributions: [NavigatorContribution] {
        guard let document = view?.document else { return [] }
        let current = view?.currentPage.map { document.index(for: $0) }
        // 同页多个目录目标按文档顺序取最后一个；没有更早目标时不选中目录。
        let currentOutline = current.flatMap { currentPage in
            outlineItems.compactMap { item -> (String, Int)? in
                guard let page = destinations[item.id]?.page else { return nil }
                let index = document.index(for: page)
                guard index != NSNotFound, index <= currentPage else { return nil }
                return (item.id, index)
            }.enumerated().max { lhs, rhs in
                lhs.element.1 == rhs.element.1 ? lhs.offset < rhs.offset : lhs.element.1 < rhs.element.1
            }?.element.0
        }
        let pages = (0..<document.pageCount).map { index in
            NavigatorItem(id: "pdf-page-\(index)", title: document.page(at: index)?.label ?? "\(index + 1)",
                          symbolName: "doc", isCurrent: current == index)
        }
        return [
            .init(id: Self.outlineID, titleLocalizationKey: "PDF Table of Contents", style: .outline,
                  items: outlineItems, selectedItemIDs: currentOutline.map { [$0] } ?? [], allowedActions: [.activate]),
            .init(id: Self.pagesID, titleLocalizationKey: "PDF Page Thumbnails", style: .flat,
                  items: pages, selectedItemIDs: current.map { ["pdf-page-\($0)"] } ?? [], allowedActions: [.activate])
        ]
    }

    func activate(_ action: NavigatorAction) -> Bool {
        guard [Self.pagesID, Self.outlineID].contains(action.contributionID) else { return false }
        guard action.kind == .activate, let id = action.itemIDs.first else { return true }
        if action.contributionID == Self.pagesID,
           let index = Int(id.replacingOccurrences(of: "pdf-page-", with: "")), let page = view?.document?.page(at: index) {
            view?.go(to: page)
        } else if let destination = destinations[id] { view?.go(to: destination) }
        return true
    }

    func page(for id: String) -> PDFPage? {
        guard let index = Int(id.replacingOccurrences(of: "pdf-page-", with: "")) else { return nil }
        return view?.document?.page(at: index)
    }
}

struct PDFNavigatorThumbnail: View {
    let page: PDFPage
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Color.secondary.opacity(0.1) }
        }
        .frame(width: 64, height: 84)
        .task(id: ObjectIdentifier(page)) {
            image = page.thumbnail(of: NSSize(width: 128, height: 168), for: .cropBox)
        }
    }
}
