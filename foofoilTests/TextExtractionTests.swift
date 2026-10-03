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
