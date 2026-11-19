import AppKit
import Testing
@testable import foofoil

struct MarkdownMermaidTests {
    @Test func findsOnlyMermaidFencesAndDecodesSource() throws {
        let markdown = """
        ````text
        ```mermaid
        sample
        ```
        ````

        > ~~~MERMAID title
        > flowchart LR
        >     A["鱼 & <猫> &lt;"] --> B["don't"]
        > ~~~

        `mermaid`
        """
        let blocks = MarkdownMermaidBlock.blocks(in: AppState.cmarkToHTML(markdown))
        #expect(blocks.count == 1)
        let source = try #require(blocks.first?.source)
        #expect(source == """
            flowchart LR
                A["鱼 & <猫> &lt;"] --> B["don't"]

            """)
    }

    @MainActor @Test func rendersFullDiagramsInBothThemes() async throws {
        let renderer = MarkdownMermaidRenderer.shared
        let light = try #require(await renderer.render("mindmap\n  root((Idea))\n    Branch", isDark: false))
        let dark = try #require(await renderer.render("mindmap\n  root((Idea))\n    Branch", isDark: true))
        let architecture = try #require(await renderer.render("""
            architecture-beta
                service web(server)[Web]
                service db(database)[Database]
                web:R -- L:db
            """, isDark: false))
        let elk = try #require(await renderer.render("""
            ---
            config:
              layout: elk
            ---
            flowchart LR
                A --> B
            """, isDark: false))

        for image in [light, dark, architecture, elk] {
            #expect(image.size.width > 20 && image.size.height > 20)
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let colors = stride(from: 0, to: bitmap.pixelsHigh, by: 8).flatMap { y in
                stride(from: 0, to: bitmap.pixelsWide, by: 8).compactMap { x in
                    bitmap.colorAt(x: x, y: y)
                }
            }
            #expect(colors.contains { $0.alphaComponent > 0.9 })
            #expect(colors.contains { $0.alphaComponent < 0.1 })
        }
        #expect(light.tiffRepresentation != dark.tiffRepresentation)
    }

    @MainActor @Test func previewKeepsInvalidCodeAndAddsResponsiveAttachment() async throws {
        let state = AppState()
        state.openText("""
            # Before

            ```mermaid
            flowchart LR
                A["A long node label"] --> B["Another long node label"]
            ```

            ```mermaid
            invalid graph definition
            ```

            # After
            """, isMarkdown: true)
        state.isMarkdownPreview = true
        for _ in 0..<400 where state.renderedMarkdown.length == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        let rendered = state.renderedMarkdown
        #expect(rendered.string.contains("Before"))
        #expect(rendered.string.contains("After"))
        #expect(!rendered.string.contains("A long node label"))
        #expect(!rendered.string.contains("FOOFOILMERMAID"))
        let range = (rendered.string as NSString).range(of: "invalid graph definition")
        try #require(range.location != NSNotFound)
        #expect(rendered.attribute(.markdownCodeBlockLanguage, at: range.location, effectiveRange: nil) as? String == "MERMAID")
        let attachment = (rendered.string as NSString).range(of: "\u{FFFC}")
        try #require(attachment.location != NSNotFound)
        let cell = try #require((rendered.attribute(.attachment, at: attachment.location, effectiveRange: nil)
            as? NSTextAttachment)?.attachmentCell as? MarkdownMermaidAttachmentCell)

        let container = NSTextContainer(size: NSSize(width: 120, height: 1000))
        let narrow = cell.cellFrame(for: container, proposedLineFragment: NSRect(x: 0, y: 0, width: 120, height: 20),
                                    glyphPosition: .zero, characterIndex: attachment.location)
        let natural = cell.cellSize()
        #expect(narrow.width > 0 && narrow.width < natural.width && narrow.width <= 120)
        #expect(abs(narrow.height / narrow.width - natural.height / natural.width) < 0.01)
    }
}
