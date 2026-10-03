//
//  TextExtractionTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/10/3.
//

import AppKit
import Foundation
import Testing
@testable import foofoil

/// 图片取字：仅光栅图片箔可用系统 OCR 提取文字，其余内容（网页、PDF、音视频、SVG、Quick Look、纯文本）都不可用。
@MainActor
@Suite(.serialized)
struct TextExtractionTests {
    /// 取字命令在快捷键设置里可配置：默认 ⌘E，仅对图片有效，改键后存储生效、可恢复默认。
    @Test func extractTextShortcutIsConfigurable() throws {
        let definition = try #require(KeyboardShortcutCatalog.definition(withID: "edit.extractText"))
        #expect(definition.defaultShortcut == KeyboardShortcut(keyEquivalent: "e", modifiers: [.command]))
        #expect(definition.noteKey == "Shortcut Scope Images")
        // 编辑分组紧随文件分组，设置面板按目录顺序展示。
        #expect(KeyboardShortcutCatalog.sections.prefix(3) == [.global, .file, .edit])

        let store = KeyboardShortcutStore.shared
        let wasCustomized = store.isCustomized(definition)
        let previous = store.shortcut(for: definition)
        defer {
            if wasCustomized { store.setShortcut(previous, for: definition) }
            else { store.reset(definition) }
        }

        let custom = KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .option])
        store.setShortcut(custom, for: definition)
        #expect(store.shortcut(forID: "edit.extractText") == custom)
        store.reset(definition)
        #expect(store.shortcut(forID: "edit.extractText") == KeyboardShortcut(keyEquivalent: "e", modifiers: [.command]))
    }

    @Test func onlyRasterImageFoilsCanExtractText() {
        var states: [AppState] = []
        defer { states.forEach { HistoryManager.shared.removeFromHistory($0.toConfig()) } }
        func makeState() -> AppState {
            let state = AppState()
            states.append(state)
            return state
        }

        // 空白箔没有可提取的画面。
        #expect(!makeState().canExtractTextFromImage)

        for name in ["photo.png", "scan.jpeg", "screenshot.heic"] {
            let state = makeState()
            state.originalImageName = name
            state.imageURL = URL(fileURLWithPath: "/tmp/\(name)")
            #expect(state.canExtractTextFromImage, "\(name)")
        }

        // PDF 走 PDFKit、SVG 走 WebKit、音视频是独立通道，都不做图片 OCR。
        for name in ["paper.pdf", "vector.svg", "clip.mp4", "song.mp3"] {
            let state = makeState()
            state.originalImageName = name
            state.imageURL = URL(fileURLWithPath: "/tmp/\(name)")
            #expect(!state.canExtractTextFromImage, "\(name)")
        }

        // 网页即使保留了截图缓存也仍按网页处理。
        let web = makeState()
        web.originalImageName = "page.png"
        web.webURL = URL(string: "https://example.com")!
        web.imageURL = URL(fileURLWithPath: "/tmp/captured.png")
        #expect(!web.canExtractTextFromImage)

        // Quick Look 预览的是其它文档类型，不当作图片。
        let quickLook = makeState()
        quickLook.originalImageName = "notes.txt"
        quickLook.imageURL = URL(fileURLWithPath: "/tmp/notes.txt")
        quickLook.quickLookSourceURL = quickLook.imageURL
        #expect(!quickLook.canExtractTextFromImage)

        // 已是文字的箔无需再提取。
        let text = makeState()
        text.text = "正文"
        #expect(!text.canExtractTextFromImage)
    }

    /// 端到端冒烟：渲染出的图片文字应能被与索引共用的系统 Vision OCR 识别。
    @Test func recognizesRenderedImageText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-ocr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("sample.png")
        let png = try #require(Self.makeTextImage(text: "FOOFOIL OCR 12345", size: NSSize(width: 900, height: 220)))
        try png.write(to: imageURL)

        let recognized = (try ImageOCRIndexer.recognize(url: imageURL)).uppercased()
        #expect(recognized.contains("FOOFOIL"))
    }

    /// 可用性 = 光栅图片门禁 且 已检测到文字：检测结论没落地就一律禁用。
    @Test func textExtractionNeedsRasterImageAndDetection() {
        var states: [AppState] = []
        defer { states.forEach { HistoryManager.shared.removeFromHistory($0.toConfig()) } }
        func makeState(_ name: String?) -> AppState {
            let state = AppState()
            states.append(state)
            if let name {
                state.originalImageName = name
                state.imageURL = URL(fileURLWithPath: "/tmp/\(name)")
            }
            return state
        }

        // 检测未完成时，即使是光栅图片也禁用。
        let photo = makeState("photo.png")
        #expect(photo.canExtractTextFromImage)
        #expect(!photo.canExtractImageText)
        photo.hasExtractableImageText = true
        #expect(photo.canExtractImageText)

        // 换图清空上一张图的结论，避免旧检测点亮新图片的菜单项。
        photo.imageURL = URL(fileURLWithPath: "/tmp/next.jpeg")
        #expect(!photo.hasExtractableImageText)
        #expect(!photo.canExtractImageText)

        // 非光栅内容即使残留了结论也不可用。
        for name in ["paper.pdf", "vector.svg", "clip.mp4", "song.mp3"] {
            let state = makeState(name)
            state.hasExtractableImageText = true
            #expect(!state.canExtractImageText, "\(name)")
        }
    }

    /// 检测结论按图去重并绑定到那张图；解码失败的图判为无字。
    @Test func textDetectionResultIsTiedToTheDetectedImage() async throws {
        var states: [AppState] = []
        defer { states.forEach { HistoryManager.shared.removeFromHistory($0.toConfig()) } }
        let state = AppState()
        states.append(state)
        state.originalImageName = "missing.png"
        state.imageURL = URL(fileURLWithPath: "/tmp/foofoil-missing-\(UUID().uuidString).png")
        let url = try #require(state.imageURL)

        state.detectImageTextIfNeeded(for: url)
        let task = try #require(state.imageTextDetectionTask)
        await task.value
        #expect(!state.hasExtractableImageText)
        // 已分析并缓存空结果（无字），据此重开历史不必再跑 OCR。
        #expect(state.imageOCRText == "")
        #expect(state.imageTextDetectedURL == url)

        // 同一张图不再起新任务。
        state.detectImageTextIfNeeded(for: url)
        #expect(state.imageTextDetectionTask == nil)

        // 换图后结论与去重记录一起作废。
        state.hasExtractableImageText = true
        state.imageOCRText = "旧文字"
        state.imageURL = URL(fileURLWithPath: "/tmp/foofoil-next-\(UUID().uuidString).png")
        #expect(!state.hasExtractableImageText)
        #expect(state.imageOCRText == nil)
        #expect(state.imageTextDetectedURL != state.imageURL)
    }

    /// 派生缓存随历史持久化：写入后能原样读回，重开历史无需重跑 Vision。
    @Test func derivedImageCachePersistsInHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-derived-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let id = UUID()
        let config = WindowConfig(
            id: id,
            imagePath: directory.appendingPathComponent("cached_image_\(id.uuidString).png").path,
            originalImageName: "scan.png",
            contentKind: .image,
            imageOCRText: "识别到的文字",
            imageHasSubject: true,
            imageSubjectPath: directory.appendingPathComponent("cached_subject_\(id.uuidString).png").path
        )
        #expect(repository.upsert(config))

        let stored = try #require(repository.config(id: id))
        #expect(stored.imageOCRText == "识别到的文字")
        #expect(stored.imageHasSubject == true)
        #expect(stored.imageSubjectPath == config.imageSubjectPath)

        // 已分析但无字的空结果同样能区分于"尚未分析"（nil）。
        var blank = config
        blank.imageOCRText = ""
        blank.imageHasSubject = false
        blank.imageSubjectPath = nil
        #expect(repository.upsert(blank))
        let reloaded = try #require(repository.config(id: id))
        #expect(reloaded.imageOCRText == "")
        #expect(reloaded.imageHasSubject == false)
        #expect(reloaded.imageSubjectPath == nil)
    }

    /// 文字检测与提取走同一通道：渲染出文字的图识别结果非空，纯色图识别结果为空。
    @Test func recognizeDistinguishesTextFromBlank() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-text-detect-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let textURL = directory.appendingPathComponent("text.png")
        let textPNG = try #require(Self.makeTextImage(text: "FOOFOIL OCR 12345", size: NSSize(width: 900, height: 220)))
        try textPNG.write(to: textURL)
        let textResult = ((try? ImageOCRIndexer.recognize(url: textURL)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!textResult.isEmpty)

        let blankURL = directory.appendingPathComponent("blank.png")
        try Self.makeSolidImage().write(to: blankURL)
        let blankResult = ((try? ImageOCRIndexer.recognize(url: blankURL)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(blankResult.isEmpty)
    }

    private static func makeSolidImage() throws -> Data {
        let size = NSSize(width: 800, height: 600)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemGray.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private static func makeTextImage(text: String, size: NSSize) -> Data? {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 96, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
