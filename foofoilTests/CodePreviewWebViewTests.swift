//  CodePreviewWebViewTests.swift
//  foofoilTests
//

import AppKit
import Foundation
import Testing
import WebKit
@testable import foofoil

/// 在离屏窗口中加载真实的代码预览页面，覆盖 Worker 高亮、逐行一致性、行号与复制映射。
@MainActor
@Suite(.serialized)
struct CodePreviewWebViewTests {
    private static let sample = "fun main() {\r\n    val 中文 = \"emoji 🎉 <b>tag</b>\"  // note\r\n\r\n/* multi\n   line */\n}\n"

    /// 通过合成的 copy 事件读取页面写入的 text/plain，避免依赖系统剪贴板。
    private static let copyExpression = """
        (() => {
            const data = new DataTransfer();
            document.dispatchEvent(new ClipboardEvent('copy', { clipboardData: data, bubbles: true, cancelable: true }));
            return data.getData('text/plain');
        })()
        """

    private static let highlightedCondition = "document.querySelector('#code .hljs-keyword') !== null"

    private static func style(showsLineNumbers: Bool = true) -> CodePreviewStyle {
        CodePreviewStyle(
            fontFamily: DocumentFontCatalog.defaultCodeFontFamily,
            fontSize: 16,
            lineHeight: nil,
            paragraphSpacing: 0,
            textColor: nil,
            isDark: false,
            showsLineNumbers: showsLineNumbers
        )
    }

    @Test func highlightsRowsWithoutFailureAndKeepsLineNumbers() async throws {
        let harness = Harness(text: Self.sample, languageID: "kotlin", style: Self.style())
        defer { harness.dispose() }
        #expect(await harness.waitUntil(Self.highlightedCondition))

        let lineCount = try await harness.number("document.querySelectorAll('#code > .l').length")
        #expect(lineCount == 7)
        let numbers = try await harness.string(
            "Array.from(document.querySelectorAll('#code > .l > .n')).map(n => n.textContent).join(',')"
        )
        #expect(numbers == "1,2,3,4,5,6,7")
        #expect(harness.failureCount == 0)
    }

    @Test func hidingLineNumbersOnlyChangesStyle() async throws {
        let harness = Harness(text: Self.sample, languageID: "kotlin", style: Self.style())
        defer { harness.dispose() }
        #expect(await harness.waitUntil(Self.highlightedCondition))

        harness.update(style: Self.style(showsLineNumbers: false))
        #expect(await harness.waitUntil("document.documentElement.classList.contains('no-ln')"))
        let hidden = try await harness.number(
            "getComputedStyle(document.querySelector('#code > .l > .n')).display === 'none' ? 1 : 0"
        )
        #expect(hidden == 1)
        // 隐藏行号后内容必须贴齐左侧，不能被放进已不存在的第二列而靠右。
        let offset = try await harness.number("""
            (() => {
                const row = document.querySelector('#code > .l');
                const content = row.querySelector('.c');
                return Math.round(content.getBoundingClientRect().left - row.getBoundingClientRect().left);
            })()
            """)
        #expect(offset == 0)
        #expect(harness.failureCount == 0)
    }

    @Test func copiesExactSourceSlicesFromSelection() async throws {
        let harness = Harness(text: Self.sample, languageID: "kotlin", style: Self.style())
        defer { harness.dispose() }
        #expect(await harness.waitUntil(Self.highlightedCondition))

        _ = try await harness.webView.evaluateJavaScript("""
            (() => {
                const rows = document.querySelectorAll('#code > .l');
                const range = document.createRange();
                range.setStart(rows[1].children[1], 0);
                range.setEnd(rows[3].children[1], rows[3].children[1].childNodes.length);
                const selection = document.getSelection();
                selection.removeAllRanges();
                selection.addRange(range);
            })()
            """)
        let partial = try await harness.string(Self.copyExpression)
        #expect(partial == "    val 中文 = \"emoji 🎉 <b>tag</b>\"  // note\r\n\r\n/* multi")

        _ = try await harness.webView.evaluateJavaScript(
            "document.getSelection().selectAllChildren(document.getElementById('code'))"
        )
        let whole = try await harness.string(Self.copyExpression)
        #expect(whole == Self.sample)
    }

    @Test func highlightsOnlyTheLineUnderThePointer() async throws {
        let harness = Harness(text: Self.sample, languageID: "kotlin", style: Self.style())
        defer { harness.dispose() }
        #expect(await harness.waitUntil(Self.highlightedCondition))

        _ = try await harness.webView.evaluateJavaScript("""
            document.querySelectorAll('#code > .l')[2].children[1]
                .dispatchEvent(new MouseEvent('mousemove', { bubbles: true }));
            """)
        let hovered = try await harness.string("""
            Array.from(document.querySelectorAll('#code > .l.is-hovered')).map(row => row.dataset.s).join(',')
            """)
        #expect(hovered == String(Self.lineStart(of: 2)))

        _ = try await harness.webView.evaluateJavaScript(
            "document.getElementById('code').dispatchEvent(new MouseEvent('mouseleave'))"
        )
        let remaining = try await harness.number("document.querySelectorAll('.is-hovered').length")
        #expect(remaining == 0)
    }

    /// 第 `line` 个逻辑行（从 0 开始）在源码中的 UTF-16 起点，与页面行号计算规则一致。
    private static func lineStart(of line: Int) -> Int {
        var starts = [0]
        var index = 0
        var previous: UInt16 = 0
        for unit in sample.utf16 {
            if previous == 13 && unit != 10 { starts.append(index) }
            if unit == 10 { starts.append(index + 1) }
            previous = unit
            index += 1
        }
        return starts[line]
    }

    @Test func fallsBackWhenRenderedTextDoesNotMatchSource() async throws {
        let harness = Harness(text: "let a = 1\u{0}\n", languageID: "swift", style: Self.style())
        defer { harness.dispose() }
        #expect(await harness.waitForFailure(timeout: 8))
    }
}

/// 驱动 Coordinator 的测试夹具：与应用中的生命周期一致，窗口放在屏幕外。
@MainActor
private final class Harness {
    private let coordinator: ReadOnlyCodeView.Coordinator
    let webView: CodePreviewWebView
    private let window: NSWindow
    private var sourceText: String
    private var languageID: String
    private(set) var failureCount = 0

    init(text: String, languageID: String, style: CodePreviewStyle) {
        sourceText = text
        self.languageID = languageID
        coordinator = ReadOnlyCodeView.Coordinator(onFailure: {})
        webView = coordinator.makeWebView()
        window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 640, height: 480),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()
        coordinator.onFailure = { [weak self] in self?.failureCount += 1 }
        coordinator.update(text: text, languageID: languageID, style: style)
    }

    func update(style: CodePreviewStyle) {
        coordinator.update(text: sourceText, languageID: languageID, style: style)
    }

    func dispose() {
        coordinator.dispose()
        window.orderOut(nil)
    }

    func waitUntil(_ condition: String, timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await webView.evaluateJavaScript("Boolean(\(condition))")) as? Bool == true { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func waitForFailure(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if failureCount > 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func string(_ script: String) async throws -> String {
        try #require(try await webView.evaluateJavaScript(script) as? String)
    }

    func number(_ script: String) async throws -> Int {
        let value = try #require(try await webView.evaluateJavaScript(script) as? NSNumber)
        return value.intValue
    }
}
