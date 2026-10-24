import AppKit
import CoreText
import PDFKit
import SwiftUI
import SwiftTerm
import Testing
import WebKit
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct FoilContentSearchTests {
    @Test func literalUnicodeRangesDoNotOverlap() {
        #expect(FoilContentSearch.ranges(in: "aA aa 中文😀中文", query: "aa") == [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        #expect(FoilContentSearch.ranges(in: "中文😀中文", query: "中文") == [NSRange(location: 0, length: 2), NSRange(location: 4, length: 2)])
        #expect(FoilContentSearch.ranges(in: "a.b aXb", query: "a.b").count == 1)
        #expect(FoilContentSearch.ranges(in: "abc", query: "").isEmpty)
        #expect(FoilContentSearch.ranges(in: "aaa", query: "aa").count == 1)
    }

    @Test func nativeTextHighlightsCycleAndCloseWithoutEditing() async throws {
        let state = AppState()
        state.text = "Needle 中文 needle"
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        text.string = state.text
        let root = NSView(); root.addSubview(text)
        let search = state.contentSearch
        search.owner = state; search.rootView = root
        search.open(); search.query = "needle"; search.refreshSurface()
        try await settle(search)
        #expect(search.count == 2)
        #expect(text.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
        search.advance(-1); #expect(search.current == 1)
        search.open()
        try await Task.sleep(for: .milliseconds(180))
        #expect(search.current == 1, "Refocusing the search must keep the current match")
        search.advance(1); #expect(search.current == 0)
        search.close()
        #expect(text.string == state.text)
        #expect(text.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
        #expect(search.query == "needle")
        search.open(); try await settle(search)
        #expect(search.count == 2)
        search.close()
    }

    @Test func webHighlightsCrossInlineElementsAndRemainLiteral() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID()).html")
        try "<html><head><meta charset=\"utf-8\"></head><body><p>Need<strong>le</strong> 中文 needle a.b aXb</p><p hidden>needle</p><script>needle</script></body></html>".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = SearchHTMLReader()
        let text = try await reader.text(at: url)
        #expect(text.contains("Needle 中文 needle"))
        #expect(FoilContentSearch.ranges(in: text, query: "needle").count == 2)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: ExtensionDocumentWebViewFactory.makeConfiguration())
        web.loadFileURL(url, allowingReadAccessTo: url)
        for _ in 0..<200 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let count = try await web.evaluateJavaScript(FoilWebSearch.script(query: "needle", color: "#FFE08A", index: 1, scroll: true))
        #expect(count as? Int == 2)
        #expect(try await web.evaluateJavaScript("CSS.highlights.get('foofoil-search').size") as? Int == 2)
        #expect(try await web.evaluateJavaScript(FoilWebSearch.script(query: "a.b", color: "#806A22", index: 0, scroll: false)) as? Int == 1)
        #expect(try await web.evaluateJavaScript("document.querySelector('strong').textContent") as? String == "le")
        _ = try await web.evaluateJavaScript(FoilWebSearch.clearScript)
        #expect(try await web.evaluateJavaScript("CSS.highlights.has('foofoil-search')") as? Bool == false)
        web.loadHTMLString("<html><body><div class='slide'>needle one</div><div class='slide'>needle two</div></body></html>", baseURL: nil)
        for _ in 0..<100 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.querySelectorAll('.slide').length")) as? Int == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await web.evaluateSearchScript(OfficeSearchText.slideIndexScript)
        _ = try await web.evaluateSearchScript(FoilWebSearch.script(query: "needle", color: "#FFE08A", index: 1, scroll: true))
        #expect(try await web.evaluateSearchScript("window.__foofoilSearchSelectedSlide") as? Int == 1)
        web.loadHTMLString("<html><body><div data-wide='true' style='width:1800px'><span style='margin-left:1400px'>needle</span></div></body></html>", baseURL: nil)
        for _ in 0..<100 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.querySelector('[data-wide]') !== null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await web.evaluateSearchScript(FoilWebSearch.script(query: "needle", color: "#FFE08A", index: 0, scroll: true))
        #expect((try await web.evaluateSearchScript("window.scrollX") as? Double ?? 0) > 500)
    }

    @Test func pdfSearchCoversAllPages() async throws {
        let document = PDFDocument()
        for _ in 0..<2 {
            let data = NSMutableData()
            let consumer = try #require(CGDataConsumer(data: data))
            var rect = CGRect(x: 0, y: 0, width: 400, height: 300)
            let context = try #require(CGContext(consumer: consumer, mediaBox: &rect, nil))
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Needle 中文", attributes: [.font: NSFont.systemFont(ofSize: 20)]))
            context.textPosition = CGPoint(x: 40, y: 100); CTLineDraw(line, context)
            context.endPDFPage(); context.closePDF()
            let page = try #require(PDFDocument(data: data as Data)?.page(at: 0))
            document.insert(page, at: document.pageCount)
        }
        let state = AppState(); state.text = "pdf"
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        let view = PDFView(); view.document = document
        let root = NSView(); root.addSubview(view)
        let search = state.contentSearch; search.owner = state; search.rootView = root
        search.open(); search.query = "needle"; search.refreshSurface()
        try await settle(search)
        #expect(search.count == 2)
        search.advance(1)
        #expect(view.highlightedSelections?.count == 2)
        search.close(); #expect(view.highlightedSelections == nil)
    }

    @Test func terminalMatchesHistoryAndWideCharacters() {
        let view = FoilTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.getTerminal().changeHistorySize(1000)
        view.feed(text: "first needle\r\n中文😀 needle\r\n" + String(repeating: "output\r\n", count: 80))
        view.updateSearch(query: "needle", color: .systemYellow)
        #expect(view.searchHighlights.count == 2)
        view.revealSearchMatch(1)
        #expect(view.getTerminal().getTopVisibleRow() < 10)
    }

    @Test func terminalScrollInvalidatesHighlightsInBothDirections() throws {
        let terminal = FoilTerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let window = NSWindow(contentRect: terminal.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = terminal
        window.orderFront(nil)
        defer { window.close() }
        terminal.getTerminal().changeHistorySize(1000)
        terminal.feed(text: String(repeating: "needle\r\n", count: 90))
        terminal.updateSearch(query: "needle", color: .systemYellow)
        let overlay = try #require(terminal.subviews.last)
        terminal.scroll(toPosition: 0)
        for position in [0.5, 1.0, 0.5, 0.0] {
            terminal.needsDisplay = false
            overlay.needsDisplay = false
            let previousTop = terminal.getTerminal().getTopVisibleRow()
            let span = try #require(terminal.searchHighlights.first?.spans.first)
            let previousRect = terminal.searchHighlightRect(for: span)
            terminal.scroll(toPosition: position)
            #expect(overlay.needsDisplay)
            let rowDelta = terminal.getTerminal().getTopVisibleRow() - previousTop
            let nextRect = terminal.searchHighlightRect(for: span)
            #expect(abs(nextRect.minY - previousRect.minY - CGFloat(rowDelta) * nextRect.height) < 0.01)
        }
        overlay.needsDisplay = false
        terminal.needsDisplay = true
        #expect(overlay.needsDisplay)
    }

    @Test func terminalCurrentMatchRemainsVisibleAfterLayout() throws {
        let terminal = FoilTerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let viewport = TerminalSearchViewport(terminal: terminal)
        viewport.searchInset = 40
        viewport.layoutSubtreeIfNeeded()
        let clip = try #require(terminal.superview as? NSClipView)
        terminal.getTerminal().changeHistorySize(1000)
        terminal.feed(text: String(repeating: "needle\r\n", count: 90) + "needle")
        terminal.updateSearch(query: "needle", color: .systemYellow)
        for index in [terminal.searchHighlights.count - 1, 0, 45, terminal.searchHighlights.count - 1] {
            terminal.revealSearchMatch(index)
            let span = try #require(terminal.searchHighlights[index].spans.first)
            let rect = terminal.searchHighlightRect(for: span)
            #expect(clip.bounds.contains(rect))
            let origin = clip.bounds.origin
            viewport.needsLayout = true
            viewport.layoutSubtreeIfNeeded()
            #expect(clip.bounds.origin == origin)
            #expect(clip.bounds.contains(terminal.searchHighlightRect(for: span)))
        }
        viewport.searchInset = 0
        viewport.layoutSubtreeIfNeeded()
        #expect(clip.bounds.origin == .zero)
    }

    @Test func markdownSearchBarDefinesCursorAboveNativeText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-\(UUID()).md")
        try "# Markdown\nneedle needle".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = AppState()
        state.openFile(url: url)
        let controller = FloatingWindowController(appState: state)
        let window = try #require(controller.window)
        window.makeKeyAndOrderFront(nil)
        let search = state.contentSearch
        defer { search.close(); window.close(); HistoryManager.shared.removeFromHistory(state.toConfig()) }
        search.open(); search.query = "needle"
        for _ in 0..<200 {
            if search.count == 2, let bar = search.barView, bar.bounds.width > 100 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let bar = try #require(search.barView)
        let field = try #require(search.inputField)
        #expect(bar.window === window)
        // 使用真实 SwiftUI 搜索栏布局，验证关闭按钮、计数区、留白及输入文字区。
        for x in [bar.bounds.maxX - 16, bar.bounds.maxX - 80, bar.bounds.minX + 4] {
            let point = bar.convert(NSPoint(x: x, y: bar.bounds.midY), to: nil)
            #expect(search.cursor(at: point, in: window) == .arrow)
        }
        let inputPoint = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        #expect(search.cursor(at: inputPoint, in: window) == .iBeam)
        let previousCursor = NSCursor.current
        let previousOrigin = window.frame.origin
        defer { window.setFrameOrigin(previousOrigin); previousCursor.set() }
        let buttonPoint = bar.convert(NSPoint(x: bar.bounds.maxX - 16, y: bar.bounds.midY), to: nil)
        for (point, expected) in [(buttonPoint, NSCursor.arrow), (inputPoint, NSCursor.iBeam)] {
            // 把测试窗口置于当前指针下，走真实窗口的事件派发和最终光标校正，不移动系统指针。
            let mouse = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: mouse.x - point.x, y: mouse.y - point.y))
            let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            (expected == .arrow ? NSCursor.iBeam : NSCursor.arrow).set()
            window.sendEvent(event)
            #expect(NSCursor.current == expected)
        }
        let bodyPoint = bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.maxY + 100), to: nil)
        #expect(search.cursor(at: bodyPoint, in: window) == nil)
        let otherWindow = NSWindow()
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        #expect(search.cursor(at: inputPoint, in: otherWindow) == nil)
        search.close()
        #expect(search.cursor(at: inputPoint, in: window) == nil)
    }

    @Test func hiddenTerminalHistoryIsExcludedUntilANewSession() async throws {
        let state = AppState()
        let session = TerminalSession(configuration: .init(), previousOutput: "history-only needle")
        state.terminalConfiguration = session.configuration
        state.terminalSession = session
        session.view.feed(text: "current-only needle")
        let controller = FloatingWindowController(appState: state)
        let window = try #require(controller.window)
        window.makeKeyAndOrderFront(nil)
        let search = state.contentSearch
        defer { search.close(); window.close(); HistoryManager.shared.removeFromHistory(state.toConfig()) }
        search.open(); search.query = "needle"
        for _ in 0..<200 {
            if search.count == 2 && !search.isSearching { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(search.count == 2)
        session.isPreviousOutputHidden = true
        // 立即刷新，覆盖原生历史视图尚未被 SwiftUI 拆除的时刻。
        search.refreshSurface()
        try await settle(search)
        #expect(search.count == 1)
        #expect(session.previousOutput == "history-only needle")
        search.query = "history-only"
        try await settle(search)
        #expect(search.count == 0)
        search.close(); search.open()
        try await settle(search)
        #expect(session.isPreviousOutputHidden)
        #expect(search.count == 0)
        search.query = "current-only"
        try await settle(search)
        #expect(search.count == 1)
        search.advance(1)
        #expect(search.current == 0)
        session.isPreviousOutputHidden = false
        search.query = "needle"
        for _ in 0..<200 {
            if search.count == 2 && !search.isSearching { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(search.count == 2)
        session.isPreviousOutputHidden = true
        // 不手动刷新：覆盖 SwiftUI 已销毁历史视图后，定时巡视仍需更新匹配数量。
        for _ in 0..<200 {
            if search.count == 1 && !search.isSearching { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(search.count == 1)
        let restored = TerminalSession(configuration: session.configuration, previousOutput: session.previousOutput)
        #expect(!restored.isPreviousOutputHidden)
        #expect(restored.previousOutput == session.previousOutput)
    }

    @Test func contentShortcutDoesNotSearchDirectory() throws {
        let state = AppState(); state.text = "needle"
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        #expect(state.handleContentSearchKey(event))
        #expect(state.contentSearch.isPresented)
        #expect(!state.isNavigatorSearchActive)
        state.contentSearch.close()
    }

    @Test func allHostDocumentChannelsUseTheSameSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foil-search-channels-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (ext, content) in [("txt", "needle 中文 needle"), ("md", "# Heading\nneedle **needle**"), ("swift", "let needle = \"needle\""), ("csv", "Name,Value\nneedle,Needle")] {
            let url = directory.appendingPathComponent("sample.\(ext)")
            try content.write(to: url, atomically: true, encoding: .utf8)
            try await verifyChannel(url: url)
        }
        let word = directory.appendingPathComponent("sample.docx")
        let source = NSAttributedString(string: "needle 中文 needle")
        try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: word)
        try await verifyChannel(url: word)
    }

    @Test func terminalSearchCrossesSoftWraps() {
        let view = FoilTerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 200))
        let columns = view.getTerminal().cols
        view.feed(text: String(repeating: "x", count: columns - 3) + "needle")
        view.updateSearch(query: "needle", color: .systemYellow)
        #expect(view.searchHighlights.count == 1)
        #expect(view.searchHighlights.first?.spans.count == 2)
    }

    @Test func themesProvideHighlightsAndCustomColorsRoundTrip() throws {
        for theme in DocumentThemeCatalog.shared.presets {
            #expect(NSColor(hex: theme.highlightHex(isDark: false)) != nil)
            #expect(NSColor(hex: theme.highlightHex(isDark: true)) != nil)
        }
        let theme = DocumentThemeCatalog.shared.addCustomTheme(name: "Search QA", currentBackgroundHex: "#FFFFFF", currentTextHex: "#111111", currentHighlightHex: "#EEDDAA", isCurrentlyDark: false)
        defer { DocumentThemeCatalog.shared.deleteCustomTheme(id: theme.id) }
        #expect(theme.highlightHex(isDark: false) == "#EEDDAA")
        #expect(try JSONDecoder().decode(DocumentTheme.self, from: JSONEncoder().encode(theme)) == theme)
    }

    @Test func crossOriginFramesAreIncludedInWebSearch() async throws {
        let state = AppState(); state.text = "web"
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        let search = state.contentSearch
        let handler = SearchFrameFixture()
        let configuration = ExtensionDocumentWebViewFactory.makeConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: "foil-search-test")
        let frames = WebSearchFrames()
        WebSearchFrames.install(on: configuration, handler: frames)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: configuration)
        frames.search = search; frames.webView = web
        search.owner = state; search.rootView = web
        web.load(URLRequest(url: URL(string: "foil-search-test://main/index")!))
        search.open(); search.query = "needle"
        defer { search.close(); configuration.userContentController.removeScriptMessageHandler(forName: WebSearchFrames.handlerName, contentWorld: .defaultClient) }
        for _ in 0..<250 {
            search.refreshSurface()
            if search.count == 2 && !search.isSearching { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(search.count == 2)
        #expect(try await web.evaluateJavaScript("document.querySelector('iframe').contentDocument === null") as? Bool == true)
        search.advance(1)
        #expect(search.current == 1)
    }

    @Test func quickLookSearchIncludesEveryWorksheet() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID()).xlsx")
        try Data(base64Encoded: "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")!.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let state = AppState()
        state.openFile(url: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(appState: state))
        window.orderFront(nil)
        defer { state.contentSearch.close(); window.close(); HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.contentSearch.open(); state.contentSearch.query = "中文"
        for _ in 0..<300 {
            if state.contentSearch.count == 2 && !state.contentSearch.isSearching { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.contentSearch.count == 2)
        state.contentSearch.advance(1)
        #expect(state.contentSearch.current == 1)
    }

    @Test func terminalSearchDoesNotResizeItsGrid() {
        let terminal = FoilTerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let viewport = TerminalSearchViewport(terminal: terminal)
        viewport.layoutSubtreeIfNeeded()
        let dimensions = terminal.getTerminal().getDims()
        viewport.searchInset = 40
        viewport.layoutSubtreeIfNeeded()
        #expect(terminal.getTerminal().cols == dimensions.cols)
        #expect(terminal.getTerminal().rows == dimensions.rows)
    }

    @Test func focusedSearchFieldHandlesReturnAndShiftReturn() async throws {
        let state = AppState(); state.text = "needle needle"
        let controller = FloatingWindowController(appState: state)
        let window = try #require(controller.window as? FloatingWindow)
        window.makeKeyAndOrderFront(nil)
        let search = state.contentSearch
        defer { search.close(); window.close(); HistoryManager.shared.removeFromHistory(state.toConfig()) }
        search.open(); search.query = "needle"
        for _ in 0..<150 {
            if search.count == 2, search.inputField?.currentEditor() != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let field = try #require(search.inputField)
        #expect(window.makeFirstResponder(field))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(window.performKeyEquivalent(with: event))
        #expect(search.current == 1)
        #expect(search.query == "needle")
    }

    @Test func powerpointFallbackIncludesBodyAndPreservesSlideOrder() throws {
        let source = try PPTXDocumentTests.fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let html = try OfficeSearchText.html(url: source)
        #expect(html.contains("目录 &amp; Title"))
        #expect(html.contains("Body should not be a title"))
        let first = try #require(html.range(of: "data-foofoil-slide='0'"))
        let second = try #require(html.range(of: "data-foofoil-slide='1'"))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test func bothAppearancesKeepFirstMatchBelowTheSearchBar() async throws {
        for dark in [false, true] {
            let state = AppState(); state.text = "needle needle"
            defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
            let theme = DocumentThemeCatalog.defaultTheme
            state.applyDocumentTheme(theme, isDark: dark)
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
            text.string = state.text
            text.textColor = NSColor(hex: theme.textHex(isDark: dark))
            text.textContainerInset = NSSize(width: 24, height: 24)
            let scroll = NSScrollView(frame: text.frame); scroll.documentView = text
            scroll.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let search = state.contentSearch; search.owner = state; search.rootView = scroll
            search.open(); search.query = "needle"; search.refreshSurface()
            try await settle(search)
            let highlight = try #require(text.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor)
            let expected = try #require(NSColor(hex: theme.highlightHex(isDark: dark)))
            #expect(abs(highlight.redComponent - expected.redComponent) < 0.001)
            #expect(text.textContainerInset.height == 64)
            search.close()
            #expect(text.textContainerInset.height == 24)
        }
    }

    private func verifyChannel(url: URL) async throws {
        let state = AppState()
        state.openFile(url: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(appState: state))
        window.orderFront(nil)
        defer { state.contentSearch.close(); window.close(); HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.contentSearch.open(); state.contentSearch.query = "needle"
        for _ in 0..<300 {
            if state.contentSearch.count == 2 && !state.contentSearch.isSearching { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.supportsContentSearch, "Unsupported search in \(url.pathExtension)")
        #expect(state.contentSearch.count == 2, "Missing matches in \(url.pathExtension), active=\(state.contentSearch.isPresented), loading=\(state.isLoading), quicklook=\(state.isQuickLookDocument)")
        state.contentSearch.advance(1)
        #expect(state.contentSearch.current == 1)
    }

    private func settle(_ search: FoilContentSearch) async throws {
        for _ in 0..<300 {
            if !search.isSearching { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Search did not finish")
    }
}

@MainActor
private final class SearchFrameFixture: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url!
        let body = url.host == "main" ? "<p>needle main</p><iframe src='foil-search-test://remote/child'></iframe>" : "<p>needle child</p>"
        let data = Data("<!doctype html><html><head><meta charset='utf-8'></head><body>\(body)</body></html>".utf8)
        task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
