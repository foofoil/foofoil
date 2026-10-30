import AppKit
import PDFKit
import Testing
@testable import foofoil

@MainActor @Suite(.sharedApplicationState, .serialized)
struct PDFOpeningDefaultsTests {
    private func makePDF() throws -> URL {
        let image = NSImage(size: NSSize(width: 300, height: 400), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let document = PDFDocument()
        document.insert(try #require(PDFPage(image: image)), at: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        #expect(document.write(to: url))
        return url
    }

    @Test func openingPDFEnablesBordersAndHistoryPreservesUserChoice() throws {
        let url = try makePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.showBorder = false
        state.openFile(url: url)
        #expect(state.isPDFDocument)
        #expect(state.showBorder)
        state.showBorder = false
        let restored = AppState(config: state.toConfig(), isIncognito: true)
        defer { restored.resetContent() }
        #expect(!restored.showBorder)
        state.openFile(url: url)
        #expect(state.showBorder)
    }

    @Test func ordinaryImagesStillOpenWithoutBorders() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        try #require(image.tiffRepresentation).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = AppState(isIncognito: true)
        defer { state.resetContent() }
        state.showBorder = true
        state.openFile(url: url)
        #expect(!state.showBorder)
    }
}
