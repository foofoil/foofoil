import AppKit
import Testing
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct MarkdownTaskTests {
    @Test func onlyRealListItemsBecomeInputs() {
        let source = """
        😀 前言
        - [ ] 第一项
          - [X] 嵌套
        > - [x] 引用
        ```markdown
        - [ ] 示例
        ```
            - [ ] 缩进代码
        - \\[ ] 转义
        普通 [ ] 文字
        FOOFOILTASK2NEND
        """
        let locations = AppState.markdownTaskLocations(source)
        #expect(locations.count == 3)
        for location in locations {
            #expect(["[ ]", "[x]", "[X]"].contains((source as NSString).substring(with: NSRange(location: location, length: 3))))
        }
        let html = AppState.cmarkToHTML(source)
        #expect(html.components(separatedBy: "<input type=\"checkbox\"").count - 1 == 3)
        #expect(html.contains("- [ ] 示例"))
        #expect(html.contains("FOOFOILTASK2NEND"))
        #expect(!html.contains("☐"))
        #expect(!html.contains("☑"))
    }

    @Test func inputImportsAsNativeCheckbox() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let source = "- [x] Task"
            let html = AppState.taskInputsForTextKit(AppState.cmarkToHTML(source))
            let data = try #require(html.data(using: .utf8))
            let attributed = try NSMutableAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            AppState.prepareTaskAttachments(attributed, source: source, fontSize: 14)
            #expect(!attributed.string.contains("•"))
            #expect(!attributed.string.contains("\t"))
            let view = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            view.isEditable = false
            view.appearance = NSAppearance(named: appearance)
            view.textStorage?.setAttributedString(attributed)
            view.taskSource = source
            view.rebuildTaskButtons()
            let button = try #require(view.subviews.compactMap { $0 as? NSButton }.first)
            #expect(!button.isAccessibilityEnabled())
            #expect(!button.acceptsFirstResponder)
            #expect(button.state == .on)
            let initial = button.state
            button.performClick(nil)
            #expect(button.state == initial)
            #expect(!button.accessibilityPerformPress())
            #expect(button.state == initial)
            #expect(button.accessibilityLabel() == "Task")
            #expect(button.frame.width >= 18)
            let manager = try #require(view.layoutManager)
            let container = try #require(view.textContainer)
            manager.ensureLayout(for: container)
            let bodyRange = (attributed.string as NSString).range(of: "Task")
            let bodyGlyphs = manager.glyphRange(forCharacterRange: bodyRange, actualCharacterRange: nil)
            let bodyFrame = manager.boundingRect(forGlyphRange: bodyGlyphs, in: container).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            #expect(button.frame.maxX <= bodyFrame.minX)
            #expect(view.accessibilityChildren()?.contains(where: { ($0 as? NSButton) === button }) == true)
            #expect(view.isEditable == false)
        }
    }
}
