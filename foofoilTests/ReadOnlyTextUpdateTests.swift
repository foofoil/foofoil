import AppKit
import Testing
import SwiftUI
@testable import foofoil

@MainActor
struct ReadOnlyTextUpdateTests {
    @Test func plainTextUsesLineClippedLayoutAndCodeKeepsViewportLayout() throws {
        let source = String(repeating: "{\"message\":\"超长段落 English words\"},", count: 6_000)
        for code in [false, true] {
            let configuration = ReadOnlyTextNSView(
                text: source, font: .systemFont(ofSize: 16), textColor: nil,
                lineHeightMultiple: nil, paragraphSpacingMultiple: nil,
                codeLineNumbersVisible: code ? false : nil
            )
            let hosting = NSHostingView(rootView: configuration)
            hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
            hosting.layoutSubtreeIfNeeded()
            let textView = try #require(firstTextView(in: hosting))
            #expect((textView.textLayoutManager != nil) == code)
            #expect(textView.string == source)
            #expect(!textView.isEditable)
            #expect(textView.isSelectable)
            #expect(textView.textContainer?.widthTracksTextView == true)
            if !code {
                // 查找仍能定位软换行后的尾部，且不需要改写原文或插入换行。
                let range = NSRange(location: (source as NSString).length - 10, length: 10)
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)
                #expect(textView.selectedRange() == range)
                #expect(textView.enclosingScrollView!.documentVisibleRect.minY > 0)
            }
        }
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { firstTextView(in: $0) }.first
    }

    @Test func unchangedLongTextDoesNotReadNativeStorage() {
        let text = String(repeating: "纯文本 English words，长文本滚动。\n", count: 30_000)
        let configuration = configuration(text: text)
        let scrollView = NSScrollView()
        let textView = StorageTrackingTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        textView.isRichText = false
        textView.isEditable = false
        scrollView.documentView = textView
        let coordinator = ReadOnlyTextNSView.Coordinator()
        coordinator.update(scrollView, configuration: configuration)
        textView.nativeReads = 0

        for _ in 0..<120 {
            coordinator.update(scrollView, configuration: configuration)
        }

        #expect(textView.nativeReads == 0)
        #expect(textView.string == text)
        #expect(textView.textLayoutManager != nil)
    }

    @Test func replacementAndStyleChangesApplyToWholeText() throws {
        let scrollView = NSScrollView()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        textView.isRichText = false
        textView.isEditable = false
        scrollView.documentView = textView
        let coordinator = ReadOnlyTextNSView.Coordinator()
        coordinator.update(scrollView, configuration: configuration(text: "第一段\n第二段", spacing: 1.8))
        coordinator.update(scrollView, configuration: configuration(text: "新的正文\n末段", spacing: 1.8))
        #expect(textView.string == "新的正文\n末段")
        var style = try #require(textView.textStorage?.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.lineHeightMultiple == 1.8)
        #expect(style.paragraphSpacing == 16)

        coordinator.update(scrollView, configuration: configuration(text: "新的正文\n末段", size: 24, spacing: 1.8))
        style = try #require(textView.textStorage?.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle)
        #expect(textView.font?.pointSize == 24)
        #expect(style.paragraphSpacing == 24)

        coordinator.update(scrollView, configuration: configuration(text: "新的正文\n末段", spacing: nil))
        style = try #require(textView.textStorage?.attribute(.paragraphStyle, at: 6, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.lineHeightMultiple == 0)
        #expect(style.paragraphSpacing == 0)
    }

    private func configuration(text: String, size: CGFloat = 16, spacing: Double? = nil) -> ReadOnlyTextNSView {
        ReadOnlyTextNSView(text: text, font: .systemFont(ofSize: size), textColor: nil,
                           lineHeightMultiple: spacing, paragraphSpacingMultiple: spacing == nil ? nil : 1,
                           codeLineNumbersVisible: nil)
    }
}

@MainActor
private final class StorageTrackingTextView: NSTextView {
    var nativeReads = 0

    override var string: String {
        get { nativeReads += 1; return super.string }
        set { super.string = newValue }
    }

    override var textStorage: NSTextStorage? {
        nativeReads += 1
        return super.textStorage
    }
}
