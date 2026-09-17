//  AppState+ClipboardContent.swift
//  foofoil
//
//  Created by tolg on 2026/9/12.
//

import AppKit
import Foundation

extension AppState {
    /// 剪贴板纯文本的 Markdown 启发式判断：只统计强语法特征，避免把普通笔记误判为 Markdown。
    nonisolated static func looksLikeMarkdown(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        var score = 0
        var inFence = false
        var hasFence = false
        var hasHeading = false
        var hasQuote = false
        var hasListItem = false
        var hasTable = false
        var hasRule = false

        func award(_ flag: inout Bool, _ points: Int) {
            guard !flag else { return }
            flag = true
            score += points
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                // 围栏代码块是最可靠的 Markdown 特征，成对出现也只记一次。
                award(&hasFence, 2)
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }

            if isATXHeading(trimmed) {
                award(&hasHeading, 2)
            } else if trimmed.hasPrefix(">") {
                award(&hasQuote, 1)
            } else if isListItem(trimmed) {
                award(&hasListItem, 1)
            } else if isThematicBreak(trimmed) {
                award(&hasRule, 1)
            }

            if !hasTable,
               index + 1 < lines.count,
               line.contains("|"),
               parseTableDelimiterLine(lines[index + 1]) != nil {
                award(&hasTable, 2)
            }
        }

        if text.contains("](") || text.contains("![") {
            score += 2
        }
        if text.contains("**") {
            score += 1
        }
        if text.filter({ $0 == "`" }).count >= 2 {
            score += 1
        }

        return score >= 2
    }

    /// 剪贴板文本是否本身就是一份 HTML 源码。
    nonisolated static func looksLikeHTML(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("<") else { return false }
        return trimmed.range(of: "<html") != nil
            || trimmed.range(of: "<!doctype") != nil
            || trimmed.range(of: "<body") != nil
    }

    /// 剪贴板 HTML 片段通常没有可用的 `<title>`，历史标题改用粘贴文本开头的摘要。
    nonisolated static func clipboardHTMLTitle(html: String, plainText: String?) -> String? {
        if let plainText, let title = plainTextHistoryTitle(from: plainText) { return title }
        return plainTextFromHTML(html).flatMap { plainTextHistoryTitle(from: $0) }
    }

    /// 折叠空白后截取开头，作为无标题内容的可读历史标题。
    nonisolated static func plainTextHistoryTitle(from text: String, limit: Int = 30) -> String? {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "..." : collapsed
    }

    /// 借助系统 HTML 导入器提取片段正文，供只有 HTML 表示、没有纯文本时生成标题。
    nonisolated static func plainTextFromHTML(_ html: String) -> String? {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil
              ) else { return nil }
        return attributed.string
    }

    /// 网页标题回填：本地缓存页（如剪贴板 HTML）没有 `<title>` 时 WebKit 会把 URL/路径当作标题，
    /// 那不是有效标题，保留打开时由内容推导的名称。
    func applyWebDocumentTitle(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if webURL?.isFileURL == true, Self.looksLikeURLLikeWebTitle(trimmed) { return }
        originalImageName = trimmed
    }

    nonisolated static func looksLikeURLLikeWebTitle(_ title: String) -> Bool {
        if title.contains("://") || title.hasPrefix("/") { return true }
        return URL(string: title)?.scheme != nil
    }

    /// 打开剪贴板等无来源文件的文本；`isMarkdown` 决定进入 Markdown 预览还是普通笔记。
    public func openText(_ content: String, isMarkdown: Bool) {
        resetFileList()
        clearCustomCover()

        isBatchUpdating = true
        defer {
            isBatchUpdating = false
            saveState()
        }

        if hasOpenedContent {
            self.id = UUID()
        }
        stopVideoAccess()
        self.sourceFingerprint = nil
        // Markdown 依赖文件名后缀进入预览，无来源文件时给出稳定的未命名名称。
        self.originalImageName = isMarkdown ? "\(NSLocalizedString("Untitled Markdown", comment: "")).md" : nil
        self.imageSource = nil
        self.imageURL = nil
        self.webURL = nil
        self.actualWebURL = nil
        self.textURL = nil
        self.text = content
        self.isMarkdownPreview = isMarkdown
        self.showBorder = true
        self.createdAt = Date()
    }

    /// 将 HTML 源码写入网页缓存文件后按网页打开。
    @discardableResult
    public func openHTML(_ html: String, originalName: String? = nil) -> Bool {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let destinationURL = getCachedContentURL(kind: "web", extension: "html"),
              (try? html.write(to: destinationURL, atomically: true, encoding: .utf8)) != nil else {
            return false
        }
        openWeb(url: destinationURL, originalName: originalName)
        return true
    }

    nonisolated private static func isATXHeading(_ line: String) -> Bool {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return false }
        let rest = line.dropFirst(hashes.count)
        return rest.isEmpty || rest.first == " "
    }

    nonisolated private static func isListItem(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if ["-", "*", "+"].contains(first) {
            let rest = line.dropFirst()
            return rest.first == " " || rest.first == "\t"
        }
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return false }
        let rest = line.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return false }
        let remainder = rest.dropFirst()
        return remainder.isEmpty || remainder.first == " " || remainder.first == "\t"
    }

    nonisolated private static func isThematicBreak(_ line: String) -> Bool {
        guard let marker = line.first, ["-", "*", "_"].contains(marker) else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 && trimmed.allSatisfy { $0 == marker }
    }
}
