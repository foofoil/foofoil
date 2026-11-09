import AppKit
import Testing
@testable import foofoil

struct MarkdownRawHTMLTests {
    @MainActor @Test func imageOnlyParagraphUsesCompactLineHeight() throws {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.42
        style.paragraphSpacing = 12
        let text = NSMutableAttributedString(string: "Title\n", attributes: [.paragraphStyle: style])
        text.append(NSAttributedString(attachment: NSTextAttachment()))
        text.append(NSAttributedString(string: "\ninline ", attributes: [.paragraphStyle: style]))
        text.append(NSAttributedString(attachment: NSTextAttachment()))
        text.append(NSAttributedString(string: " text", attributes: [.paragraphStyle: style]))
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 6, length: 1))
        AppState.compactMarkdownImageParagraphs(text)
        let imageStyle = try #require(text.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle)
        let inlineStyle = try #require(text.attribute(.paragraphStyle, at: 8, effectiveRange: nil) as? NSParagraphStyle)
        #expect(imageStyle.lineHeightMultiple == 1)
        #expect(imageStyle.paragraphSpacing == 12)
        #expect(inlineStyle.lineHeightMultiple == 1.42)
    }

    @Test func localImageAndStaticTagsRender() {
        let html = AppState.cmarkToHTML("<img src=\"docs/images/logo.png\" width=\"128\" alt=\"Logo\">\n\nA <b>bold</b> word")
        #expect(html.contains("<img src=\"docs/images/logo.png\" alt=\"Logo\" width=\"128\">"))
        #expect(html.contains("<b>bold</b>"))
        #expect(AppState.agentMarkdownHTML(html, placeholder: "[unavailable]").contains("[unavailable]"))
    }

    @Test func rejectsUnsafeHTMLAndPreservesCode() {
        for raw in ["<img src=\"../secret.png\">", "<img src=\"https://example.com/a.png\">",
                    "<img src=\"a.png\" onerror=\"alert(1)\">", "<img src=\"%2e%2e/a.png\">",
                    "<script>alert(1)</script>", "<img src=\"a.png\" width=\"9999\">"] {
            #expect(!AppState.cmarkToHTML(raw).contains("<img"))
            #expect(!AppState.cmarkToHTML(raw).contains("<script>"))
        }
        let code = AppState.cmarkToHTML("`<img src=\"a.png\">`")
        #expect(!code.contains("<img"))
        #expect(code.contains("&lt;img"))
        #expect(!AppState.cmarkToHTML("[bad](javascript:alert)").contains("javascript:"))
    }

    @MainActor @Test func localImageImportsAsAttachment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("logo.png"))
        for (attributes, expected) in [("width=\"4\"", NSSize(width: 4, height: 2)),
                                       ("height=\"6\"", NSSize(width: 12, height: 6)),
                                       ("width=\"3\" height=\"5\"", NSSize(width: 3, height: 5))] {
            let html = AppState.cmarkToHTML("<img src=\"logo.png\" \(attributes) alt=\"Logo\">")
            let (_, sizes) = AppState.markdownImageSizeMarkers(html)
            let size = try #require(sizes.first)
            let attachment = NSTextAttachment(fileWrapper: FileWrapper(regularFileWithContents: try Data(contentsOf: directory.appendingPathComponent("logo.png"))))
            let attributed = NSMutableAttributedString(string: size.marker)
            attributed.append(NSAttributedString(attachment: attachment))
            AppState.applyMarkdownImageSizes(sizes, to: attributed)
            var actual: NSSize?
            attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                actual = (value as? NSTextAttachment)?.attachmentCell?.cellSize()
            }
            #expect(actual == expected)
            #expect(!attributed.string.contains("FOOFOILIMGSIZE"))
        }
    }
}
