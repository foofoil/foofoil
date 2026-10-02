//
//  ClipboardOpenableContentTests.swift
//  foofoil
//
//  Created by tolg on 2026/9/30.
//

import AppKit
import Foundation
import Testing
@testable import foofoil

/// 剪贴板内容类型检测：断言检测分支与 openClipboardContentInNewWindow 的实际打开结果一致，
/// 文件来源的类型另带扩展名（如 “.flac音频”、“.log文本”）。
@MainActor
struct ClipboardOpenableContentTests {
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-clipboard-type-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func makeFile(_ name: String, contents: Data = Data([0x00]), in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    /// 1x1 PNG：图片文件需要能被 NSImage 解码才会被判定为可打开。
    private let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    // MARK: - 文本分支（对应 openClipboardText）

    @Test func declaredMarkdownTypeWins() {
        let result = ClipboardOpenableContent.forText(
            declaredMarkdown: "# 标题",
            plainText: "标题",
            html: "<b>标题</b>"
        )
        #expect(result?.kind == .markdown)
    }

    @Test func markdownHeuristicMatchesOpenOrder() {
        // 浏览器复制的 Markdown 文本常同时带 HTML 表示；打开时 Markdown 优先于 HTML。
        let result = ClipboardOpenableContent.forText(
            declaredMarkdown: nil,
            plainText: "# 标题\n\n- 第一项",
            html: "<h1>标题</h1>"
        )
        #expect(result?.kind == .markdown)
    }

    @Test func plainTextWithHTMLRepresentationOpensAsHTMLFragment() {
        let result = ClipboardOpenableContent.forText(
            declaredMarkdown: nil,
            plainText: "只是普通的一句话。",
            html: "<p>只是普通的一句话。</p>"
        )
        #expect(result?.kind == .htmlFragment)
    }

    @Test func websiteURLTextOpensAsWebsite() {
        let result = ClipboardOpenableContent.forText(
            declaredMarkdown: nil,
            plainText: "  https://www.apple.com.cn/  \n",
            html: nil
        )
        #expect(result?.kind == .website)
    }

    @Test func urlWithSurroundingTextIsNotWebsite() {
        // 网址混在其它文字里时不按网站打开，与 websiteURL(fromClipboardText:) 的整体判定一致。
        let result = ClipboardOpenableContent.forText(
            declaredMarkdown: nil,
            plainText: "看看这个 https://www.apple.com 很不错",
            html: nil
        )
        #expect(result?.kind == .text)
    }

    @Test func nonHTTPSSchemeIsNotWebsite() {
        let result = ClipboardOpenableContent.forText(
            declaredMarkdown: nil,
            plainText: "ftp://example.com/file.zip",
            html: nil
        )
        #expect(result?.kind == .text)
    }

    @Test func declaredMarkdownURLStillOpensAsMarkdown() {
        // 声明为 Markdown 类型的内容优先按 Markdown，不再走网址判定。
        let result = ClipboardOpenableContent.forText(
            declaredMarkdown: "https://www.apple.com",
            plainText: "https://www.apple.com",
            html: nil
        )
        #expect(result?.kind == .markdown)
    }

    @Test func htmlSourceTextOpensAsHTMLFragment() {
        let result = ClipboardOpenableContent.forText(
            declaredMarkdown: nil,
            plainText: "<!doctype html><html><body>hi</body></html>",
            html: nil
        )
        #expect(result?.kind == .htmlFragment)
    }

    @Test func plainTextOnlyOpensAsText() {
        let result = ClipboardOpenableContent.forText(
            declaredMarkdown: nil,
            plainText: "只是普通的一句话。",
            html: nil
        )
        #expect(result?.kind == .text)
    }

    @Test func htmlWithoutReadableTextOpensAsHTMLFragment() {
        let result = ClipboardOpenableContent.forText(
            declaredMarkdown: nil,
            plainText: "   ",
            html: "<p>只有 HTML 表示</p>"
        )
        #expect(result?.kind == .htmlFragment)
    }

    @Test func emptyClipboardTextHasNoContent() {
        #expect(ClipboardOpenableContent.forText(declaredMarkdown: nil, plainText: nil, html: nil) == nil)
        #expect(ClipboardOpenableContent.forText(declaredMarkdown: "  ", plainText: " ", html: nil) == nil)
    }

    @Test func nonFileContentHasNoExtension() {
        let result = ClipboardOpenableContent.forText(
            declaredMarkdown: nil,
            plainText: "https://www.apple.com",
            html: nil
        )
        #expect(result?.fileExtension == nil)
    }

    // MARK: - 文件分支（对应 openClipboardFileURLs → handleDroppedFileURLs）

    @Test func singleAudioFileIsAudioWithExtension() throws {
        let directory = try makeTempDirectory()
        let url = try makeFile("song.flac", in: directory)
        let result = ClipboardOpenableContent.forFileURLs([url])
        #expect(result?.kind == .audio)
        #expect(result?.fileExtension == "flac")
    }

    @Test func sameExtensionAudioListKeepsExtension() throws {
        let directory = try makeTempDirectory()
        let urls = [
            try makeFile("a.flac", in: directory),
            try makeFile("b.flac", in: directory),
        ]
        let result = ClipboardOpenableContent.forFileURLs(urls)
        #expect(result?.kind == .audioList)
        #expect(result?.fileExtension == "flac")
    }

    @Test func mixedExtensionAudioListOmitsExtension() throws {
        let directory = try makeTempDirectory()
        let urls = [
            try makeFile("a.mp3", in: directory),
            try makeFile("b.flac", in: directory),
        ]
        let result = ClipboardOpenableContent.forFileURLs(urls)
        #expect(result?.kind == .audioList)
        #expect(result?.fileExtension == nil)
    }

    @Test func cueSheetIsAudioWithExtension() throws {
        let directory = try makeTempDirectory()
        let url = try makeFile("album.cue", in: directory)
        let result = ClipboardOpenableContent.forFileURLs([url])
        #expect(result?.kind == .audio)
        #expect(result?.fileExtension == "cue")
    }

    @Test func videoFilesMatchGroupKind() throws {
        let directory = try makeTempDirectory()
        let single = try makeFile("clip.mp4", in: directory)
        let singleResult = ClipboardOpenableContent.forFileURLs([single])
        #expect(singleResult?.kind == .video)
        #expect(singleResult?.fileExtension == "mp4")
        let second = try makeFile("other.mov", in: directory)
        let listResult = ClipboardOpenableContent.forFileURLs([single, second])
        #expect(listResult?.kind == .videoList)
        #expect(listResult?.fileExtension == nil)
    }

    @Test func imageFilesMatchGroupKind() throws {
        let directory = try makeTempDirectory()
        let single = try makeFile("pic.png", contents: pngData, in: directory)
        let singleResult = ClipboardOpenableContent.forFileURLs([single])
        #expect(singleResult?.kind == .image)
        #expect(singleResult?.fileExtension == "png")
        let second = try makeFile("pic2.png", contents: pngData, in: directory)
        let listResult = ClipboardOpenableContent.forFileURLs([single, second])
        #expect(listResult?.kind == .imageList)
        #expect(listResult?.fileExtension == "png")
    }

    @Test func markdownFileMatchesOpenTextFile() throws {
        let directory = try makeTempDirectory()
        let url = try makeFile("notes.md", contents: Data("# 标题".utf8), in: directory)
        let result = ClipboardOpenableContent.forFileURLs([url])
        #expect(result?.kind == .markdown)
        #expect(result?.fileExtension == "md")
    }

    @Test func plainTextFileIsTextWithExtension() throws {
        let directory = try makeTempDirectory()
        let url = try makeFile("notes.txt", contents: Data("hello".utf8), in: directory)
        let result = ClipboardOpenableContent.forFileURLs([url])
        #expect(result?.kind == .text)
        #expect(result?.fileExtension == "txt")
    }

    @Test func logFileIsTextWithExtension() throws {
        let directory = try makeTempDirectory()
        let url = try makeFile("console.log", contents: Data("hello".utf8), in: directory)
        let result = ClipboardOpenableContent.forFileURLs([url])
        #expect(result?.kind == .text)
        #expect(result?.fileExtension == "log")
    }

    @Test func htmlFileIsWebWithExtension() throws {
        let directory = try makeTempDirectory()
        let url = try makeFile("page.html", contents: Data("<html></html>".utf8), in: directory)
        let result = ClipboardOpenableContent.forFileURLs([url])
        #expect(result?.kind == .web)
        #expect(result?.fileExtension == "html")
    }

    @Test func directoryIsFolderWithoutExtension() throws {
        let directory = try makeTempDirectory()
        _ = try makeFile("song.mp3", in: directory)
        let result = ClipboardOpenableContent.forFileURLs([directory])
        #expect(result?.kind == .folder)
        #expect(result?.fileExtension == nil)
    }

    @Test func mixedBatchPrefersAudioLikeGrouping() throws {
        // groups(from:) 在混合批次里优先音频组，打开的也是音频；提示须一致。
        let directory = try makeTempDirectory()
        let urls = [
            try makeFile("song.mp3", in: directory),
            try makeFile("notes.txt", contents: Data("hello".utf8), in: directory),
        ]
        let result = ClipboardOpenableContent.forFileURLs(urls)
        #expect(result?.kind == .audio)
        #expect(result?.fileExtension == "mp3")
    }

    @Test func unknownFileOffersQuickLook() throws {
        // 未知格式也可以交给系统 Quick Look。
        let directory = try makeTempDirectory()
        let url = try makeFile("data.foofoilunknownext", in: directory)
        #expect(ClipboardOpenableContent.forFileURLs([url])?.kind == .file)
    }
}
