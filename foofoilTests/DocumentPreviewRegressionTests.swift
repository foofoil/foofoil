import AppKit
import SwiftUI
import Testing
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct DocumentPreviewRegressionTests {
    @Test func docxPreviewAllowsTextSelectionAndCopy() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".docx")
        let source = NSAttributedString(string: "选择中文与 emoji 😀\nSecond paragraph", attributes: [.font: NSFont.systemFont(ofSize: 16)])
        let data = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = NSHostingView(rootView: SelectableDocumentPreview(url: url, shouldHideBorder: false))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        func findText(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap { findText($0) }.first
        }
        for _ in 0..<100 {
            if findText(host) != nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let text = try #require(findText(host))
        #expect(text.isSelectable)
        #expect(!text.isEditable)
        #expect(text.backgroundColor == .white)
        #expect(text.string.contains("选择中文与 emoji 😀"))
        text.setSelectedRange(NSRange(location: 0, length: 4))
        #expect(text.selectedRange().length == 4)
    }

    @Test func commandScrollResizesQuickLookWindowInsteadOfImageScale() throws {
        let state = AppState()
        let url = URL(fileURLWithPath: "/tmp/preview-regression.docx")
        state.imageURL = url
        state.quickLookSourceURL = url
        let controller = FloatingWindowController(appState: state)
        let window = try #require(controller.window as? FloatingWindow)
        defer { window.close() }
        window.setFrame(NSRect(x: 100, y: 100, width: 400, height: 300), display: false)
        let scale = state.imageScale
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        event.flags = .maskCommand
        window.sendEvent(try #require(NSEvent(cgEvent: event)))
        #expect(window.frame.width > 400)
        #expect(window.frame.height > 300)
        #expect(state.imageScale == scale)
    }
}
