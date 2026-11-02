import Testing
import PDFKit
import FoofoilExtensionKit
@testable import foofoil

@MainActor
struct PDFDisplayModeTests {
    @Test func borderSwitchesBetweenContinuousAndSinglePage() {
        let view = PDFView()
        PDFModeView.applyDisplayMode(to: view, showBorder: true)
        #expect(view.displayMode == .singlePageContinuous)
        #expect(view.displayDirection == .vertical)
        #expect(view.displaysPageBreaks)
        PDFModeView.applyDisplayMode(to: view, showBorder: false)
        #expect(view.displayMode == .singlePage)
        #expect(!view.displaysPageBreaks)
    }

    @Test func fixedPDFScaleSurvivesViewResizing() {
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        view.document = document
        PDFModeView.applyScale(to: view, scale: 1.25, autoFit: false)
        view.frame.size = NSSize(width: 700, height: 300)
        view.layoutSubtreeIfNeeded()
        #expect(!view.autoScales)
        #expect(abs(view.scaleFactor - 1.25) < 0.0001)
    }

    @Test func nativeZoomSurvivesNavigationRefresh() throws {
        let state = AppState(isIncognito: true)
        state.showBorder = true
        let coordinator = PDFModeView.Coordinator(appState: state)
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        document.insert(PDFPage(), at: 1)
        view.document = document
        coordinator.pdfView = view
        view.autoScales = false
        view.scaleFactor = 1.5
        #expect(abs(state.imageScale - 1.5) < 0.0001)
        view.go(to: try #require(document.page(at: 1)))
        PDFModeView.applyScale(to: view, scale: CGFloat(state.imageScale), autoFit: false)
        #expect(abs(view.scaleFactor - 1.5) < 0.0001)
    }

    @Test func pageSizeUsesDisplayBoxAndRotation() {
        let page = PDFPage()
        page.setBounds(NSRect(x: 0, y: 0, width: 600, height: 800), for: .mediaBox)
        page.setBounds(NSRect(x: 0, y: 0, width: 400, height: 700), for: .cropBox)
        #expect(PDFModeView.displayedPageSize(page, box: .cropBox) == NSSize(width: 400, height: 700))
        page.rotation = 90
        #expect(PDFModeView.displayedPageSize(page, box: .cropBox) == NSSize(width: 700, height: 400))
    }

    @Test func outlineSelectionTracksCurrentPageAndNestedDestinations() throws {
        let document = PDFDocument()
        let pages = (0..<4).map { _ in PDFPage() }
        for (index, page) in pages.enumerated() { document.insert(page, at: index) }
        let root = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "Chapter"
        chapter.destination = PDFDestination(page: pages[0], at: .zero)
        let section = PDFOutline()
        section.label = "Section"
        section.destination = PDFDestination(page: pages[2], at: .zero)
        chapter.insertChild(section, at: 0)
        root.insertChild(chapter, at: 0)
        document.outlineRoot = root
        let view = PDFView()
        view.document = document
        let navigator = PDFNavigator(view: view, url: URL(fileURLWithPath: "/test.pdf"))
        view.go(to: pages[1])
        #expect(navigator.contributions.first?.selectedItemIDs == ["pdf-outline.0"])
        view.go(to: pages[3])
        #expect(navigator.contributions.first?.selectedItemIDs == ["pdf-outline.0.0"])
    }
}
