import Foundation
import Testing
@testable import foofoil

/// 搜索索引的 n-gram 编码跨版本必须保持一致，否则历史搜索会漏检；
/// 这里用旧的逐字符实现作为参照，防止编码优化改变 token 结果。
struct SearchNGramEncoderTests {
    private func hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private func referenceTitleTerms(_ normalized: String) -> String {
        let characters = Array(normalized.filter { !$0.isWhitespace })
        let singles = characters.map { "t1x" + hex(String($0)) }
        let grams = characters.count >= 2
            ? (0..<(characters.count - 1)).map { "t2x" + hex(String(characters[$0...($0 + 1)])) }
            : []
        return (singles + grams).joined(separator: " ")
    }

    private func referenceBodyTerms(_ normalized: String) -> String {
        let characters = Array(normalized.filter { !$0.isWhitespace })
        let grams = characters.count >= 2
            ? (0..<(characters.count - 1)).map { "b2x" + hex(String(characters[$0...($0 + 1)])) }
            : []
        return grams.joined(separator: " ")
    }

    @Test func encodingMatchesReferenceImplementation() {
        let samples = [
            "",
            "a",
            "ab",
            "hello world",
            "中文内容用 于测试",
            "Mixed 中文 English 123",
            "emoji 😀 and 🇨🇳 flags",
            "combining é vs e\u{0301}",
            "tabs\tand\nnewlines",
            "  ",
            "ünïcödé"
        ]
        for sample in samples {
            #expect(SearchNGramEncoder.titleTerms(sample) == referenceTitleTerms(sample), "titleTerms mismatch for \(sample)")
            #expect(SearchNGramEncoder.bodyTerms(sample) == referenceBodyTerms(sample), "bodyTerms mismatch for \(sample)")
        }
    }

    @Test func matchExpressionUsesEncodedGrams() {
        #expect(SearchNGramEncoder.matchExpression(for: "中") == "title_terms:t1xe4b8ad")
        #expect(SearchNGramEncoder.matchExpression(for: "ab") == "(title_terms:t2x6162) OR (body_terms:b2x6162)")
        #expect(SearchNGramEncoder.matchExpression(for: "  ") == nil)
    }
}
