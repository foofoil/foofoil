import Foundation
import AppKit
import Testing
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct MarkdownCodeHighlighterTests {
    @Test func knownLanguagesAndAliasesHighlightWithoutChangingEscapedText() {
        let html = "<pre><code class=\"language-js\">const 文本 = &quot;&lt;b&gt;&amp;😀&lt;/b&gt;&quot;;\n</code></pre>"
        let light = MarkdownCodeHighlighter.highlightHTML(html, isDark: false)
        let dark = MarkdownCodeHighlighter.highlightHTML(html, isDark: true)
        #expect(light.contains("color: #CF222E"))
        #expect(dark.contains("color: #FF7B72"))
        #expect(light.contains("&lt;b&gt;&amp;😀&lt;/b&gt;"))
        #expect(light.contains("文本"))
    }

    @Test func unsupportedAndUnlabelledBlocksStayPlain() {
        for html in ["<pre><code>let x = 1</code></pre>", "<pre><code class=\"language-no-such-language\">let x = 1</code></pre>", "<p><code>let x = 1</code></p>"] {
            #expect(MarkdownCodeHighlighter.highlightHTML(html, isDark: false) == html)
        }
    }

    @Test func largeBlocksStayPlain() {
        let html = "<pre><code class=\"language-swift\">" + String(repeating: "let x = 1\n", count: 12_000) + "</code></pre>"
        #expect(MarkdownCodeHighlighter.highlightHTML(html, isDark: false) == html)
    }
    @Test func nativeMarkdownRenderingPreservesTokenColorsAndCopyText() async throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.originalImageName = "syntax-regression.md"
        state.text = "```swift\nlet 中文 = \"😀\"\n```"
        state.isMarkdownPreview = true
        for _ in 0..<100 {
            if state.renderedMarkdown.string.contains("let 中文") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let rendered = state.renderedMarkdown
        let keyword = (rendered.string as NSString).range(of: "let")
        let string = (rendered.string as NSString).range(of: "😀")
        #expect(keyword.location != NSNotFound)
        #expect(string.location != NSNotFound)
        let keywordColor = try #require(rendered.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? NSColor)
        let stringColor = try #require(rendered.attribute(.foregroundColor, at: string.location, effectiveRange: nil) as? NSColor)
        #expect(keywordColor != stringColor)
        #expect(rendered.string.contains("let 中文 = \"😀\""))
    }

}
