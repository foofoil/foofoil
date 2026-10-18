import Foundation
import JavaScriptCore

/// 复用代码预览自带的离线语法库；每次渲染独立上下文，避免跨线程共享 JS 状态。
enum MarkdownCodeHighlighter {
    nonisolated private static let source: String? = {
        let url = Bundle.main.url(forResource: "highlight-worker", withExtension: "js")
            ?? Bundle.main.url(forResource: "highlight-worker", withExtension: "js", subdirectory: "CodePreview")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }()

    nonisolated static func highlightHTML(_ html: String, isDark: Bool) -> String {
        let pattern = #"<pre><code class="language-([^"]+)">([\s\S]*?)</code></pre>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let original = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: original.length))
        guard !matches.isEmpty, let source, let context = JSContext() else { return html }
        // Worker 尾部只注册回调；提供空消息端口即可在 JavaScriptCore 中复用完整语言库。
        context.evaluateScript("var self = { postMessage: function() {} };")
        context.evaluateScript(source)
        let highlight = context.evaluateScript("(function(code, language) { if (!hljs.getLanguage(language)) return null; return hljs.highlight(code, {language: language, ignoreIllegals: true}).value; })")
        let spanRegex = try? NSRegularExpression(pattern: #"<span class="([^"]+)">"#)
        var result = html
        for match in matches.reversed() {
            if Task.isCancelled { return html }
            let escaped = original.substring(with: match.range(at: 2))
            // 大代码块保持纯文本，避免语法识别占用过多时间与内存。
            guard escaped.utf8.count <= 100_000 else { continue }
            let code = escaped.replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
            let language = original.substring(with: match.range(at: 1)).lowercased()
            guard let value = highlight?.call(withArguments: [code, language]), !value.isNull, !value.isUndefined,
                  var colored = value.toString(), let spanRegex else { continue }
            let snapshot = colored as NSString
            for span in spanRegex.matches(in: colored, range: NSRange(location: 0, length: snapshot.length)).reversed() {
                let scope = snapshot.substring(with: span.range(at: 1))
                let color: String
                if scope.contains("comment") || scope.contains("quote") { color = isDark ? "#8B949E" : "#6E7781" }
                else if scope.contains("keyword") || scope.contains("literal") { color = isDark ? "#FF7B72" : "#CF222E" }
                else if scope.contains("string") || scope.contains("regexp") { color = isDark ? "#A5D6FF" : "#0A3069" }
                else if scope.contains("number") || scope.contains("attr") { color = isDark ? "#79C0FF" : "#0550AE" }
                else if scope.contains("title") || scope.contains("built_in") || scope.contains("type") { color = isDark ? "#D2A8FF" : "#8250DF" }
                else { color = isDark ? "#FFA657" : "#953800" }
                colored = (colored as NSString).replacingCharacters(in: span.range, with: "<span style=\"color: \(color)\">")
            }
            result = (result as NSString).replacingCharacters(in: match.range(at: 2), with: colored)
        }
        return result
    }
}
