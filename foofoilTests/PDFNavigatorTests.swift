import Testing
import AppKit
import PDFKit
import FoofoilExtensionKit
@testable import foofoil

@MainActor struct PDFNavigatorTests {
    @Test func outlineAndPageSelectionShareThePDFView() throws {
        let document = PDFDocument()
        for _ in 0..<3 {
            document.insert(try #require(PDFPage(image: NSImage(size: NSSize(width: 300, height: 400), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill(); return true
            })), at: document.pageCount)
        }
        let root = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "Chapter"
        chapter.destination = PDFDestination(page: try #require(document.page(at: 2)), at: .zero)
        root.insertChild(chapter, at: 0)
        document.outlineRoot = root
        let view = PDFView()
        view.document = document
        let navigator = PDFNavigator(view: view, url: URL(fileURLWithPath: "/test.pdf"))
        #expect(navigator.contributions.count == 2)
        #expect(navigator.contributions[0].items.first?.title == "Chapter")
        #expect(navigator.contributions[1].items.count == 3)
        #expect(navigator.activate(.init(contributionID: PDFNavigator.outlineID, kind: .activate, itemIDs: ["pdf-outline.0"])))
        #expect(view.currentPage === document.page(at: 2))
        #expect(navigator.activate(.init(contributionID: PDFNavigator.pagesID, kind: .activate, itemIDs: ["pdf-page-1"])))
        #expect(view.currentPage === document.page(at: 1))
        #expect(navigator.contributions[1].selectedItemIDs == ["pdf-page-1"])
    }
}
