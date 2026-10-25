import AppKit
import SwiftUI
import Testing
@testable import foofoil

struct MarkdownLinkTests {
    @MainActor @Test func relativeLinksImportAndUseHostHandler() throws {
        let base = URL(fileURLWithPath: "/tmp/markdown-links", isDirectory: true)
        let html = AppState.cmarkToHTML("[Local](chapter.md) [Web](https://example.com)")
        let attributed = try NSAttributedString(data: Data(html.utf8), options: [
            .documentType: NSAttributedString.DocumentType.html, .baseURL: base
        ], documentAttributes: nil)
        let link = try #require(attributed.attribute(.link, at: 0, effectiveRange: nil) as? URL)
        #expect(link == base.appendingPathComponent("chapter.md"))
        var opened: URL?
        let view = MarkdownTextView(attributedText: attributed, calculatedHeight: .constant(0), onOpenLink: { opened = $0 })
        let handled = view.makeCoordinator().textView(NSTextView(), clickedOnLink: link, at: 0)
        #expect(handled)
        #expect(opened == link)
    }

    @Test func acceptsExistingLocalFilesAndWebsites() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(AppState.markdownLinkTarget(file) == file)
        #expect(AppState.markdownLinkTarget(FileManager.default.temporaryDirectory) == nil)
        #expect(AppState.markdownLinkTarget(URL(string: "https://example.com/a?q=1#part")!) != nil)
        #expect(AppState.markdownLinkTarget(URL(fileURLWithPath: "/missing/" + UUID().uuidString)) == nil)
        #expect(AppState.markdownLinkTarget(URL(string: "mailto:a@example.com")!) == nil)
        #expect(AppState.markdownLinkTarget(URL(string: "foofoil-markdown:///relative.md")!) == nil)
    }
}
