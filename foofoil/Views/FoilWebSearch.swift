import Foundation
import WebKit

/// 使用 Range + CSS Highlight 保留原始 DOM、语法着色和事件处理；支持跨行内标签的匹配。
enum FoilWebSearch {
    static let clearScript = """
    (() => { for (const doc of [document, ...Array.from(document.querySelectorAll('iframe')).flatMap(f => {try{return f.contentDocument ? [f.contentDocument] : []}catch{return []}})]) {
      doc.defaultView.CSS?.highlights?.delete('foofoil-search');
      doc.defaultView.CSS?.highlights?.delete('foofoil-search-current');
      const state = doc.__foofoilSearch;
      if (state) {state.observer.disconnect(); doc.adoptedStyleSheets = doc.adoptedStyleSheets.filter(s => s !== state.sheet); delete doc.__foofoilSearch;}
    } })();
    """

    static let closeScript = clearScript + """
    (() => {for (const doc of [document, ...Array.from(document.querySelectorAll('iframe')).flatMap(f=>{try{return f.contentDocument?[f.contentDocument]:[]}catch{return []}})]) {
      const inset = doc.__foofoilSearchInset;
      if (!inset) continue;
      doc.documentElement.style.setProperty('padding-top', inset.value, inset.priority);
      doc.defaultView.scrollBy(0, -40);
      delete doc.__foofoilSearchInset;
    }})();
    """

    static let textScript = "(\(engine))(null, null, -1, false)"
    static let dirtyScript = "Boolean(document.__foofoilSearch?.dirty)"

    static func script(query: String, color: String, index: Int, scroll: Bool, includeFrames: Bool = true) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [query, color])
        let arguments = String(decoding: data, as: UTF8.self)
        return "(() => { const args = \(arguments); return (\(engine))(args[0], args[1], \(index), \(scroll), \(includeFrames)); })()"
    }

    private static let engine = #"""
    function(query, color, index, scroll, includeFrames = true) {
      const documents = [document];
      for (let i = 0; includeFrames && i < documents.length; i++) {
        for (const frame of documents[i].querySelectorAll('iframe,frame')) {
          try { if (frame.contentDocument) documents.push(frame.contentDocument); } catch {}
        }
      }
      let allText = '', total = 0;
      for (const doc of documents) {
        const win = doc.defaultView;
        if (query !== null && !doc.__foofoilSearchInset) {
          const root = doc.documentElement;
          doc.__foofoilSearchInset = {value:root.style.getPropertyValue('padding-top'),priority:root.style.getPropertyPriority('padding-top')};
          const offset = win.scrollY;
          root.style.setProperty('padding-top', `${parseFloat(win.getComputedStyle(root).paddingTop) + 40}px`, 'important');
          if (offset > 0) win.scrollTo(win.scrollX, offset + 40);
        }
        const roots = [doc.body || doc.documentElement];
        for (let i = 0; i < roots.length; i++) {
          for (const el of roots[i].querySelectorAll('*')) if (el.shadowRoot) roots.push(el.shadowRoot);
        }
        let text = '', nodes = [], previousBlock = null;
        for (const root of roots) {
          const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode(node) {
              const p = node.parentElement;
              if (doc.getElementById('code')?.classList.contains('code') && p?.closest('.n')) return NodeFilter.FILTER_REJECT;
              if (!p || p.closest('script,style,noscript,textarea,input,select,[hidden],[aria-hidden="true"]')) return NodeFilter.FILTER_REJECT;
              const style = win.getComputedStyle(p);
              if (style.visibility === 'hidden' || style.display === 'none' || p.getClientRects().length === 0) return NodeFilter.FILTER_REJECT;
              return NodeFilter.FILTER_ACCEPT;
            }
          });
          let node;
          while (node = walker.nextNode()) {
            const block = node.parentElement?.closest('p,div,section,article,li,h1,h2,h3,h4,h5,h6,pre,td,th');
            if (previousBlock && block !== previousBlock && !text.endsWith('\n')) text += '\n';
            previousBlock = block;
            nodes.push({node, start: text.length, end: text.length + node.length});
            text += node.textContent;
          }
        }
        allText += (allText ? '\n' : '') + text;
        if (query === null) continue;
        // Unicode regexp 的大小写折叠不会改变 UTF-16 偏移，避免 İ 等字符导致高亮错位。
        const escaped = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const expression = new RegExp(escaped, 'giu');
        const ranges = [];
        const nodeAt = offset => {
          let low=0, high=nodes.length;
          while(low<high) {const mid=(low+high)>>1; if(nodes[mid].end<=offset) low=mid+1; else high=mid;}
          return nodes[low];
        };
        for (const match of text.matchAll(expression)) {
          const start = match.index, end = start + match[0].length;
          const a = nodeAt(start);
          const b = nodeAt(end-1);
          if (!a || !b) continue;
          const range = doc.createRange();
          range.setStart(a.node, start - a.start); range.setEnd(b.node, end - b.start);
          ranges.push(range);
        }
        if (!doc.__foofoilSearch) {
          const sheet = new win.CSSStyleSheet();
          doc.adoptedStyleSheets = [...doc.adoptedStyleSheets, sheet];
          const observer = new win.MutationObserver(() => {if (doc.__foofoilSearch) doc.__foofoilSearch.dirty = true;});
          observer.observe(doc.documentElement, {subtree: true, childList: true, characterData: true});
          doc.__foofoilSearch = {sheet, observer, dirty: false};
        }
        const state = doc.__foofoilSearch;
        state.dirty = false;
        const safeColor = /^#[0-9a-f]{6}$/i.test(color) ? color : '#FFE08A';
        state.sheet.replaceSync(`::highlight(foofoil-search){background-color:${safeColor}33;} ::highlight(foofoil-search-current){background-color:${safeColor};text-decoration:underline;}`);
        win.CSS.highlights.set('foofoil-search', new win.Highlight(...ranges));
        const selected = ranges[index - total];
        win.CSS.highlights.set('foofoil-search-current', new win.Highlight(...(selected ? [selected] : [])));
        if (selected) {
          const slide = selected.startContainer.parentElement?.closest('[data-foofoil-slide]');
          if (slide) window.__foofoilSearchSelectedSlide = Number(slide.dataset.foofoilSlide);
        }
        if (selected && scroll) {
          if (win.frameElement) win.frameElement.scrollIntoView({block:'center'});
          const rect = selected.getBoundingClientRect();
          const left = rect.left < 16 ? rect.left - 16 : rect.right > win.innerWidth - 16 ? rect.right - win.innerWidth + 16 : 0;
          win.scrollBy({left, top: rect.top - Math.max(52, win.innerHeight / 3), behavior: 'instant'});
          // 嵌套滚动容器（例如代码预览）需要滚动到同一命中，随后留出顶部搜索条。
          let parent = selected.startContainer.parentElement;
          while (parent && parent !== doc.body) {
            const s = win.getComputedStyle(parent);
            if (/(auto|scroll)/.test(s.overflowX) && parent.scrollWidth > parent.clientWidth) {
              const r = selected.getBoundingClientRect(), box = parent.getBoundingClientRect();
              if (r.left < box.left || r.right > box.left + parent.clientWidth) parent.scrollLeft += r.left - box.left - Math.max(16, (parent.clientWidth - r.width) / 2);
            }
            if (/(auto|scroll)/.test(s.overflowY) && parent.scrollHeight > parent.clientHeight) {
              parent.scrollTop += selected.getBoundingClientRect().top - parent.getBoundingClientRect().top - Math.max(52, parent.clientHeight / 3);
            }
            parent = parent.parentElement;
          }
        }
        total += ranges.length;
      }
      return query === null ? allText : total;
    }
    """#
}

/// 搜索索引使用禁用页面脚本的独立 WebKit 实例，提取规则与可见正文完全相同。
@MainActor
final class SearchHTMLReader: NSObject, WKNavigationDelegate {
    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: ExtensionDocumentWebViewFactory.makeConfiguration())
    private var continuation: CheckedContinuation<String, Error>?
    override init() { super.init(); webView.navigationDelegate = self }
    func text(at url: URL, allowingReadAccessTo directory: URL? = nil) async throws -> String {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadFileURL(url.resolvingSymlinksInPath(), allowingReadAccessTo: (directory ?? url).resolvingSymlinksInPath())
        }
    }
    func cancel() {
        webView.stopLoading()
        finish(.failure(CancellationError()))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(FoilWebSearch.textScript) { [weak self] result, error in
            if let error { self?.finish(.failure(error)) }
            else { self?.finish(.success(result as? String ?? "")) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    private func finish(_ result: Result<String, Error>) {
        let continuation = continuation; self.continuation = nil
        continuation?.resume(with: result)
    }
}
