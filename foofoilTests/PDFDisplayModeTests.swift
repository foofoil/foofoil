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
}
