//  CodeHighlightWorkerTests.swift
//  foofoilTests
//

import Foundation
import JavaScriptCore
import Testing

/// 直接在 JavaScriptCore 中执行随应用打包的 Worker 脚本，验证语法注册与高亮协议；
/// 页面侧的 DOM 行布局与复制由 WebKit 端到端手工验证。
struct CodeHighlightWorkerTests {
    private static let workerURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("foofoil/Resources/CodePreview/highlight-worker.js")

    private static func makeContext() throws -> JSContext {
        let source = try String(contentsOf: workerURL, encoding: .utf8)
        let context = try #require(JSContext())
        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in exceptionMessage = exception?.toString() }
        context.evaluateScript("""
            var __posted = [];
            this.self = this;
            this.postMessage = function (message) { __posted.push(JSON.stringify(message)); };
            """)
        context.evaluateScript(source)
        #expect(exceptionMessage == nil, "Worker 脚本执行异常：\(exceptionMessage ?? "")")
        return context
    }

    private static func highlight(_ source: String, language: String, id: Int = 1) throws -> [String: Any] {
        let context = try Self.makeContext()
        let message: [String: Any] = ["id": id, "language": language, "source": source]
        let json = try String(data: JSONSerialization.data(withJSONObject: message), encoding: .utf8) ?? "{}"
        context.evaluateScript("self.onmessage({ data: \(json) });")
        let posted = context.evaluateScript("__posted.length ? __posted[__posted.length - 1] : null")?.toString() ?? "null"
        let result = try JSONSerialization.jsonObject(with: Data(posted.utf8)) as? [String: Any]
        return try #require(result)
    }

    /// 去掉高亮标记并还原实体，得到应与源码完全一致的纯文本。
    private static func plainText(fromHTML html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return withoutTags
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    @Test func registersEveryBundledLanguage() throws {
        let context = try Self.makeContext()
        let count = context.evaluateScript("hljs.listLanguages().length")?.toInt32() ?? 0
        #expect(count == 194)
        for language in ["kotlin", "zig", "yaml", "ini", "dockerfile", "makefile", "cmake", "typescript", "plaintext"] {
            let registered = context.evaluateScript("hljs.getLanguage('\(language)') !== undefined")?.toBool() ?? false
            #expect(registered, "\(language) 未注册")
        }
    }

    @Test func highlightsKotlinZigYamlAndIniTokens() throws {
        let kotlin = try Self.highlight("fun main() {\n    val answer = 42 // note\n}\n", language: "kotlin")
        #expect((kotlin["html"] as? String)?.contains("hljs-keyword") == true)
        #expect((kotlin["html"] as? String)?.contains("hljs-comment") == true)

        let zig = try Self.highlight("const n: u32 = 0x1F + 3.14e2; // hi\n", language: "zig")
        #expect((zig["html"] as? String)?.contains("hljs-numbers") == true)

        let yaml = try Self.highlight("name: demo\nitems:\n  - 1\n", language: "yaml")
        #expect((yaml["html"] as? String)?.contains("hljs-") == true)

        let ini = try Self.highlight("[server]\nport = 8080\n", language: "ini")
        #expect((ini["html"] as? String)?.contains("hljs-section") == true)
    }

    @Test func highlightedTextMatchesSourceIncludingSpecialCharacters() throws {
        let source = "let s = \"<b>中文 🎉 `tick`</b>\"; // &amp;\r\n\r\n/* multi\n line */\tend\n"
        let result = try Self.highlight(source, language: "javascript")
        let html = try #require(result["html"] as? String)
        #expect(Self.plainText(fromHTML: html) == source)
    }

    @Test func reportsUnknownLanguageAsErrorWithoutCrashing() throws {
        let result = try Self.highlight("plain", language: "no-such-language")
        #expect(result["html"] == nil)
        #expect((result["error"] as? String)?.isEmpty == false)
    }
}
