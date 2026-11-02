import Testing
import PDFKit
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

}
