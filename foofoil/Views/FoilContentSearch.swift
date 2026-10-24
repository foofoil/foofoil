import AppKit
import SwiftTerm
import Combine
import PDFKit
import SwiftUI
import WebKit
import FoofoilExtensionKit

/// 单个箔的临时查找状态；范围、结果和异步任务不跨窗口共享。
@MainActor
final class FoilContentSearch: ObservableObject {
    @Published var isPresented = false
    @Published var query = "" { didSet { if oldValue != query { scheduleSearch() } } }
    @Published private(set) var count = 0
    @Published private(set) var current = 0
    @Published private(set) var isSearching = false
    @Published private(set) var failed = false
    @Published private(set) var focusRequest = 0
    weak var owner: AppState?
    weak var rootView: NSView?
    weak var inputField: NSSearchField?
    weak var barView: NSView?
    private weak var textView: NSTextView?
    private var originalTextInset: NSSize?
    private weak var pdfView: PDFView?
    private weak var webView: WKWebView?
    private var textRanges: [NSRange] = []
    private var pdfMatches: [PDFSelection] = []
    private var task: Task<Void, Never>?
    private var revision = UUID()
    private var lastContent = ""
    private var lastColor = ""
    private struct WebFrame {
        let info: WKFrameInfo
        let token: String
        var count = 0
    }
    private weak var frameWebView: WKWebView?
    private var webFrames: [WebFrame] = []
    private var matchedWebFrames: [WebFrame] = []
    private var lastWebURL: URL?
    private var wasWebLoading = false
    private var navigationRevision = UUID()
    private var bookSessionID: UUID?
    private var bookSources: [DocumentSearchSource] = []
    private var bookTexts: [String] = []
    private var bookMatches: [(section: Int, local: Int)] = []
    private var reader: SearchHTMLReader?
    private var activeSection: Int?

    nonisolated static func ranges(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var ranges: [NSRange] = []
        var start = 0
        while start < source.length {
            let range = source.range(of: query, options: [.caseInsensitive], range: NSRange(location: start, length: source.length - start))
            guard range.location != NSNotFound, range.length > 0 else { break }
            ranges.append(range)
            start = NSMaxRange(range)
        }
        return ranges
    }

    func resetWebFrames(webView: WKWebView) {
        frameWebView = webView; webFrames = []; matchedWebFrames = []
    }

    func registerWebFrame(_ frame: WKFrameInfo, token: String, webView: WKWebView) {
        if frameWebView !== webView { resetWebFrames(webView: webView) }
        webFrames.append(WebFrame(info: frame, token: token))
        if isPresented { scheduleSearch(scroll: false) }
    }

    private func frameScript(_ script: String, token: String) -> String {
        let tokenJSON = String(decoding: try! JSONEncoder().encode(token), as: UTF8.self)
        return "window.__foofoilSearchFrameToken === \(tokenJSON) ? (\(script)) : null"
    }

    func open() {
        let wasPresented = isPresented
        isPresented = true
        focusRequest &+= 1
        if !wasPresented { scheduleSearch() }
    }

    /// SwiftUI 覆盖层不会裁掉底下 NSTextView 的 cursor rect，窗口派发完事件后按实际搜索栏区域校正。
    func cursor(at point: NSPoint, in window: NSWindow) -> NSCursor? {
        guard isPresented, let barView, barView.window === window,
              !barView.isHiddenOrHasHiddenAncestor,
              barView.visibleRect.contains(barView.convert(point, from: nil)) else { return nil }
        if let field = inputField, field.window === window {
            let textRect = (field.cell as? NSSearchFieldCell)?.searchTextRect(forBounds: field.bounds) ?? field.bounds
            if textRect.contains(field.convert(point, from: nil)) { return .iBeam }
        }
        return .arrow
    }

    func close() {
        let wasPresented = isPresented
        isPresented = false
        revision = UUID()
        task?.cancel()
        reader?.cancel()
        reader = nil
        isSearching = false
        clearHighlights(removeLayout: true)
        count = 0
        current = 0
        if wasPresented, let window = inputField?.window, window.isKeyWindow {
            let content: NSView? = owner?.terminalSession?.view ?? textView ?? pdfView ?? webView
            if let content, content.window === window { window.makeFirstResponder(content) }
        }
    }

    func reset() {
        close()
        bookSessionID = nil; bookSources = []; bookTexts = []; bookMatches = []
        activeSection = nil; query = ""
    }

    func reportFailure() { failed = true; isSearching = false; count = 0 }

    func advance(_ delta: Int) {
        guard isPresented, count > 0, !isSearching else { return }
        current = ((current + delta) % count + count) % count
        revealCurrent()
    }

    /// 只在可见正文变化时重新匹配；终端新输出不触发定位，避免抢走阅读位置。
    func refreshSurface() {
        guard isPresented, let rootView else { return }
        let views = Self.descendants(rootView)
        let pdf = views.compactMap { $0 as? PDFView }.first
        let web = views.compactMap { $0 as? WKWebView }.first
        // 隐藏状态先于 SwiftUI 移除原生视图生效，避免关闭后仍把残留的历史视图纳入搜索。
        let text = owner?.terminalSession?.isPreviousOutputHidden == true ? nil : views.compactMap { $0 as? NSTextView }.first { !$0.isFieldEditor && $0.identifier?.rawValue != "foil-search-field" }
        let changed = pdfView !== pdf || webView !== web || textView !== text
        if changed {
            clearHighlights(removeLayout: true)
            pdfView = pdf; webView = web; textView = text
        }
        prepareTextInset()
        // 历史记录的增删、折叠或隐藏也属于搜索正文变化，即使弱引用已随视图销毁而变成 nil。
        let content = owner?.terminalSession.map { String(decoding: $0.view.getTerminal().getBufferAsData(), as: UTF8.self) + "\0" + (text?.string ?? "") } ?? text?.string ?? ""
        let color = owner?.resolvedSearchHighlightHex ?? ""
        let urlChanged = web?.url != lastWebURL
        let finishedLoading = wasWebLoading && web?.isLoading == false
        wasWebLoading = web?.isLoading ?? false
        let contentChanged = content != lastContent
        let colorChanged = color != lastColor
        if changed || contentChanged || colorChanged || urlChanged || finishedLoading {
            lastContent = content; lastColor = color; lastWebURL = web?.url
            if bookSessionID == owner?.extensionSession?.id, !bookMatches.isEmpty {
                if finishedLoading || colorChanged || changed || urlChanged { applyWebMatch(scroll: finishedLoading) }
            } else { scheduleSearch(scroll: changed || urlChanged || finishedLoading) }
        } else if let web, frameWebView === web, !isSearching, !query.isEmpty {
            let revision = revision
            for frame in matchedWebFrames {
                web.evaluateSearchScript(frameScript(FoilWebSearch.dirtyScript, token: frame.token), frame: frame.info) { [weak self] value, _ in
                    guard let self, self.revision == revision, value as? Bool == true else { return }
                    self.scheduleSearch(scroll: false)
                }
            }
        } else if let web, !web.isLoading, !isSearching, !query.isEmpty {
            let revision = revision
            web.evaluateSearchScript(FoilWebSearch.dirtyScript) { [weak self] value, _ in
                guard let self, self.revision == revision, value as? Bool == true else { return }
                self.scheduleSearch(scroll: false)
            }
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        // 原生 PDF/WebKit 自己的内部文本视图不参与宿主文本匹配。
        if view is PDFView || view is WKWebView || view is NSTextView { return [view] }
        return view.subviews.flatMap { descendants($0) }
    }

    private func prepareTextInset() {
        guard owner?.terminalSession == nil, let textView else { return }
        if originalTextInset == nil { originalTextInset = textView.textContainerInset }
        guard let inset = originalTextInset, textView.textContainerInset.height != inset.height + 40 else { return }
        let scroll = textView.enclosingScrollView
        let offset = scroll?.contentView.bounds.origin ?? .zero
        textView.textContainerInset = NSSize(width: inset.width, height: inset.height + 40)
        if offset.y > 0, let scroll { scroll.contentView.scroll(to: NSPoint(x: offset.x, y: offset.y + 40)); scroll.reflectScrolledClipView(scroll.contentView) }
    }

    private func clearHighlights(removeLayout: Bool = false) {
        if let textView, let manager = textView.layoutManager {
            manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length))
        }
        if removeLayout, let textView, let inset = originalTextInset {
            let scroll = textView.enclosingScrollView
            let offset = scroll?.contentView.bounds.origin ?? .zero
            textView.textContainerInset = inset
            scroll?.contentView.scroll(to: NSPoint(x: offset.x, y: max(0, offset.y - 40)))
            if let scroll { scroll.reflectScrolledClipView(scroll.contentView) }
            originalTextInset = nil
        }
        pdfView?.highlightedSelections = nil
        if let webView {
            let script = removeLayout ? FoilWebSearch.closeScript : FoilWebSearch.clearScript
            webView.evaluateSearchScript(script, completionHandler: nil)
            if frameWebView === webView {
                for frame in webFrames { webView.evaluateSearchScript(script, frame: frame.info, completionHandler: nil) }
            }
        }
        owner?.terminalSession?.view.searchHighlights = []
    }

    private func scheduleSearch(scroll: Bool = true) {
        guard isPresented else { return }
        task?.cancel()
        reader?.cancel()
        reader = nil
        revision = UUID()
        let revision = revision
        isSearching = !query.isEmpty
        failed = false
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard let self, !Task.isCancelled, self.revision == revision else { return }
            await self.search(revision: revision, scroll: scroll)
        }
    }

    private func search(revision: UUID, scroll: Bool) async {
        clearHighlights()
        textRanges = []; pdfMatches = []; bookMatches = []
        let previousCurrent = current
        count = 0; current = 0
        guard !query.isEmpty else { isSearching = false; return }
        do {
            if let session = owner?.extensionSession, session.documentSearchSources != nil {
                try await searchBook(session: session, revision: revision)
            } else if let terminal = owner?.terminalSession {
                terminal.view.updateSearch(query: query, color: highlightColor)
                if let text = textView { textRanges = Self.ranges(in: text.string, query: query); paintText() }
                count = textRanges.count + terminal.view.searchHighlights.count
            } else if let pdf = pdfView, let document = pdf.document {
                // PDFKit 的异步扫描避免整本文档查找阻塞主线程。
                pdfMatches = try await PDFSearchScanner.matches(in: document, query: query)
                guard self.revision == revision, !Task.isCancelled else { return }
                count = pdfMatches.count
                paintPDF()
            } else if let web = webView {
                if frameWebView === web, !webFrames.isEmpty {
                    var frames: [WebFrame] = []
                    var total = 0
                    for var frame in webFrames {
                        let script = FoilWebSearch.script(query: query, color: owner?.resolvedSearchHighlightHex ?? "#FFE08A", index: -total, scroll: scroll, includeFrames: false)
                        if let value = try? await web.evaluateSearchScript(frameScript(script, token: frame.token), frame: frame.info), let found = value as? Int {
                            frame.count = found; total += found; frames.append(frame)
                        }
                        guard self.revision == revision, !Task.isCancelled else { return }
                    }
                    matchedWebFrames = frames; count = total
                    webFrames = frames
                } else {
                    let value = try await web.evaluateSearchScript(FoilWebSearch.script(query: query, color: owner?.resolvedSearchHighlightHex ?? "#FFE08A", index: 0, scroll: scroll))
                    guard self.revision == revision, !Task.isCancelled else { return }
                    count = (value as? Int) ?? 0
                }
            } else if let text = textView {
                let content = text.string
                let query = query
                let ranges = await Task.detached(priority: .userInitiated) { Self.ranges(in: content, query: query) }.value
                guard self.revision == revision, !Task.isCancelled, text.string == content else { return }
                textRanges = ranges
                count = ranges.count
                paintText()
            } else {
                // 预览仍在异步加载时保持“搜索中”，不把未加载误报为无匹配。
                return
            }
            guard self.revision == revision, !Task.isCancelled else { return }
            if !scroll { current = min(previousCurrent, max(0, count - 1)); paintText(); paintPDF() }
            isSearching = false
            if !scroll, count > 0 { applyWebMatch(scroll: false) }
            if scroll && count > 0 { revealCurrent() }
        } catch {
            guard self.revision == revision, !Task.isCancelled else { return }
            isSearching = false
            failed = true
            count = 0
        }
    }

    private var highlightColor: NSColor { NSColor(hex: owner?.resolvedSearchHighlightHex ?? "#FFE08A") ?? .systemYellow }

    private func paintText() {
        guard let text = textView, let manager = text.layoutManager else { return }
        manager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (text.string as NSString).length))
        for (index, range) in textRanges.enumerated() {
            manager.addTemporaryAttribute(.backgroundColor, value: highlightColor.withAlphaComponent(index == current ? 0.95 : 0.2), forCharacterRange: range)
        }
    }

    private func paintPDF() {
        for (index, selection) in pdfMatches.enumerated() { selection.color = highlightColor.withAlphaComponent(index == current ? 0.95 : 0.2) }
        pdfView?.highlightedSelections = pdfMatches
    }

    private func revealCurrent() {
        if !bookMatches.isEmpty {
            let match = bookMatches[current]
            if activeSection != match.section, let session = owner?.extensionSession {
                let source = bookSources[match.section]
                activeSection = match.section
                let revision = revision
                task?.cancel()
                navigationRevision = UUID()
                let navigationRevision = navigationRevision
                task = Task { [weak self] in
                    do {
                        let updated = try await ExtensionHost.shared.perform(navigatorAction: NavigatorAction(contributionID: source.contributionID, kind: .activate, itemIDs: [source.itemID]), in: session)
                        guard let self, self.revision == revision, self.navigationRevision == navigationRevision, self.isPresented, !Task.isCancelled else { return }
                        self.owner?.extensionSession = updated
                        // 新章节完成加载后由正文探针恢复匹配；旧 DOM 不执行跨章定位。
                    } catch {
                        guard let self, self.revision == revision else { return }
                        self.failed = true
                    }
                }
            } else { applyWebMatch(scroll: true) }
        } else if let terminal = owner?.terminalSession {
            paintText()
            if current < textRanges.count, let textView { textView.scrollRangeToVisible(textRanges[current]) }
            else { terminal.view.revealSearchMatch(current - textRanges.count) }
        } else if let pdf = pdfView, pdfMatches.indices.contains(current) {
            paintPDF()
            pdf.go(to: pdfMatches[current])
            if owner?.isPPTXDocument == true, let page = pdfMatches[current].pages.first, let document = pdf.document {
                owner?.pptxNavigationController.select(document.index(for: page))
            }
        } else if let text = textView, textRanges.indices.contains(current) {
            paintText()
            text.scrollRangeToVisible(textRanges[current])
        } else { applyWebMatch(scroll: true) }
    }

    private func applyWebMatch(scroll: Bool) {
        guard let web = webView, !web.isLoading, isPresented, !query.isEmpty else { return }
        if bookMatches.indices.contains(current), let section = bookSources.firstIndex(where: { $0.url.path == web.url?.path }) {
            activeSection = section
            let match = bookMatches[current]
            let local = match.section == section ? match.local : -1
            web.evaluateSearchScript(FoilWebSearch.script(query: query, color: owner?.resolvedSearchHighlightHex ?? "#FFE08A", index: local, scroll: scroll && local >= 0), completionHandler: nil)
            return
        }
        if frameWebView === web, !matchedWebFrames.isEmpty {
            var offset = 0
            for frame in matchedWebFrames {
                let local = current - offset
                let script = FoilWebSearch.script(query: query, color: owner?.resolvedSearchHighlightHex ?? "#FFE08A", index: local, scroll: scroll, includeFrames: false)
                web.evaluateSearchScript(frameScript(script, token: frame.token), frame: frame.info) { [weak self, weak web] _, _ in
                    if local >= 0 && local < frame.count, let web { self?.syncPresentationPosition(in: web, frame: frame.info) }
                }
                if local >= 0 && local < frame.count, scroll, !frame.info.isMainFrame {
                    let url = String(decoding: try! JSONEncoder().encode(frame.info.request.url?.absoluteString ?? ""), as: UTF8.self)
                    web.evaluateSearchScript("Array.from(document.querySelectorAll('iframe,frame')).find(f=>f.src===\(url))?.scrollIntoView({block:'center'})", completionHandler: nil)
                }
                offset += frame.count
            }
            return
        }
        let local = bookMatches.indices.contains(current) ? bookMatches[current].local : current
        web.evaluateSearchScript(FoilWebSearch.script(query: query, color: owner?.resolvedSearchHighlightHex ?? "#FFE08A", index: local, scroll: scroll)) { [weak self, weak web] _, _ in
            if let web { self?.syncPresentationPosition(in: web) }
        }
    }

    private func syncPresentationPosition(in web: WKWebView, frame: WKFrameInfo? = nil) {
        guard owner?.isPPTXDocument == true else { return }
        web.evaluateSearchScript("window.__foofoilSearchSelectedSlide", frame: frame) { [weak self] value, _ in
            if let index = value as? Int, self?.owner?.pptxNavigationController.currentIndex != index {
                self?.owner?.pptxNavigationController.select(index)
            }
        }
    }

    private func searchBook(session: ContentSession, revision: UUID) async throws {
        if bookSessionID != session.id {
            bookSources = []; bookTexts = []; bookSessionID = session.id; activeSection = nil
        }
        if bookSources.isEmpty {
            let prepared = try await ExtensionHost.shared.perform(commandID: "document.search.prepare", in: session)
            guard self.revision == revision, !Task.isCancelled else { return }
            let sources = prepared.documentSearchSources ?? []
            let reader = SearchHTMLReader()
            self.reader = reader
            var texts: [String] = []
            for source in sources {
                try Task.checkCancellation()
                guard ExtensionDocumentURLPolicy.fileURL(for: source.url) != nil else { throw CocoaError(.fileReadNoPermission) }
                texts.append(try await reader.text(at: source.url))
            }
            guard self.revision == revision, !Task.isCancelled else { return }
            self.reader = nil
            bookSources = sources; bookTexts = texts
        }
        let texts = bookTexts
        let query = query
        let matches = await Task.detached(priority: .userInitiated) {
            texts.enumerated().flatMap { section, text in Self.ranges(in: text, query: query).indices.map { (section: section, local: $0) } }
        }.value
        guard self.revision == revision, !Task.isCancelled else { return }
        bookMatches = matches
        count = matches.count
        if case .document(let url) = session.presentation {
            activeSection = bookSources.firstIndex { $0.url.path == url.path }
        }
    }
}

extension AppState {
    var supportsContentSearch: Bool {
        (supportsContentBackgroundColor || isQuickLookDocument) && !isBlank && !isExternalMediaDocument && !isCamera
    }

    /// 窗口优先接管查找快捷键，防止网页、终端或导航列表吞键。
    func handleContentSearchKey(_ event: NSEvent) -> Bool {
        let target = archiveSession?.preview ?? self
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command, key == "f", target.supportsContentSearch {
            target.contentSearch.open(); return true
        }
        guard target.contentSearch.isPresented else { return false }
        if [36, 76].contains(event.keyCode), modifiers.isEmpty || modifiers == .shift,
           let editor = target.contentSearch.inputField?.currentEditor() as? NSTextView {
            guard !editor.hasMarkedText() else { return false }
            target.contentSearch.advance(modifiers.contains(.shift) ? -1 : 1)
            return true
        }
        if key == "g", modifiers == .command || modifiers == [.command, .shift] {
            target.contentSearch.advance(modifiers.contains(.shift) ? -1 : 1); return true
        }
        if event.keyCode == 53, modifiers.isEmpty {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            target.contentSearch.close(); return true
        }
        return false
    }
}

/// 与正文共享视图生命周期，仅在查找期间巡视原生呈现通道，异步加载完成后自动重绑。
struct FoilSearchProbe: NSViewRepresentable {
    let appState: AppState
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let search = appState.contentSearch
        search.owner = appState
        context.coordinator.search = search
        context.coordinator.view = view
        context.coordinator.start()
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.timer?.invalidate(); coordinator.search?.close() }
    @MainActor final class Coordinator {
        weak var search: FoilContentSearch?
        weak var view: NSView?
        var timer: Timer?
        private var subscription: AnyCancellable?
        func start() {
            guard subscription == nil, let search else { return }
            subscription = search.$isPresented.sink { [weak self] active in
                self?.timer?.invalidate(); self?.timer = nil
                guard active else { return }
                self?.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let search = self.search, search.isPresented else { return }
                        search.rootView = self.view?.window?.contentView
                        search.refreshSurface()
                    }
                }
            }
        }
        deinit { timer?.invalidate() }
    }
}

struct FoilSearchBar: View {
    @ObservedObject var search: FoilContentSearch
    let placeholder: String
    var body: some View {
        if search.isPresented {
            HStack(spacing: 7) {
                SearchInput(search: search, placeholder: placeholder)
                    .frame(minWidth: 25, maxWidth: .infinity)
                if search.isSearching { ProgressView().controlSize(.mini).help("Searching Content") }
                else if search.failed { Image(systemName: "exclamationmark.triangle").help("Content Search Failed") }
                else if !search.query.isEmpty {
                    Text("\(search.count == 0 ? 0 : search.current + 1)/\(search.count)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        .help(search.count == 0 ? NSLocalizedString("No Matches", comment: "") : "\(search.current + 1)/\(search.count)")
                        .accessibilityLabel(Text("Search Match Count"))
                        .accessibilityValue(Text("\(search.count == 0 ? 0 : search.current + 1)/\(search.count)"))
                }
                Button { search.advance(-1) } label: { Image(systemName: "chevron.up") }.help("Find Previous")
                    .accessibilityLabel(Text("Find Previous")).disabled(search.count == 0 || search.isSearching)
                Button { search.advance(1) } label: { Image(systemName: "chevron.down") }.help("Find Next")
                    .accessibilityLabel(Text("Find Next")).disabled(search.count == 0 || search.isSearching)
                Button { search.close() } label: { Image(systemName: "xmark") }.help("Close Search")
                    .accessibilityLabel(Text("Close Search"))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.regularMaterial)
            .background(SearchBarBounds(search: search))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        }
    }
}

/// 只提供搜索栏的原生坐标，鼠标事件仍交给输入框和 SwiftUI 按钮。
private struct SearchBarBounds: NSViewRepresentable {
    let search: FoilContentSearch
    func makeNSView(context: Context) -> NSView {
        let view = BoundsView()
        search.barView = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { search.barView = view }
    private final class BoundsView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct SearchInput: NSViewRepresentable {
    @ObservedObject var search: FoilContentSearch
    let placeholder: String
    func makeCoordinator() -> Coordinator { Coordinator(search) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        search.inputField = field
        field.placeholderString = NSLocalizedString(placeholder, comment: "")
        field.delegate = context.coordinator
        field.focusRingType = .none
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.identifier = NSUserInterfaceItemIdentifier("foil-search-field")
        field.setAccessibilityLabel(NSLocalizedString(placeholder, comment: ""))
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != search.query { field.stringValue = search.query }
        if context.coordinator.focusRequest != search.focusRequest {
            context.coordinator.focusRequest = search.focusRequest
            DispatchQueue.main.async {
                guard search.isPresented else { return }
                field.window?.makeKeyAndOrderFront(nil)
                field.window?.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let search: FoilContentSearch
        var focusRequest = -1
        init(_ search: FoilContentSearch) { self.search = search }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            search.query = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                // 标记文本仍交给输入法确认，不把候选提交当作结果导航。
                guard !textView.hasMarkedText() else { return false }
                search.advance(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) { search.close(); return true }
            return false
        }
    }
}

/// PDFKit 在主线程发起增量扫描，结果逐批回调；取消不会提交过时的匹配。
@MainActor
private final class PDFSearchScanner: NSObject {
    private var continuation: CheckedContinuation<[PDFSelection], Error>?
    private var matches: [PDFSelection] = []
    private var observers: [NSObjectProtocol] = []
    private let document: PDFDocument
    private init(document: PDFDocument) { self.document = document }
    static func matches(in document: PDFDocument, query: String) async throws -> [PDFSelection] {
        let scanner = PDFSearchScanner(document: document)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                scanner.continuation = continuation
                let center = NotificationCenter.default
                scanner.observers = [
                    center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { note in
                        MainActor.assumeIsolated { if let match = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection { scanner.matches.append(match) } }
                    },
                    center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { _ in
                        MainActor.assumeIsolated { scanner.finish() }
                    }
                ]
                document.beginFindString(query, withOptions: [.caseInsensitive])
            }
        } onCancel: {
            Task { @MainActor in scanner.document.cancelFindString(); scanner.finish(cancelled: true) }
        }
    }
    private func finish(cancelled: Bool = false) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        let continuation = continuation; self.continuation = nil
        if cancelled { continuation?.resume(throwing: CancellationError()) }
        else { continuation?.resume(returning: matches) }
    }
}
