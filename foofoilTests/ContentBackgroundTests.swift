//  ContentBackgroundTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/18.
//

import AppKit
import Foundation
import FoofoilExtensionKit
import SwiftUI
import Testing
@testable import foofoil

@MainActor
@Suite(.serialized)
struct ContentBackgroundTests {
    /// 只有文档箔提供内容背景色：图片、视频、音频以自身画面填充箔片，窗口只作画框。
    @Test func onlyDocumentFoilsSupportContentBackgroundColor() {
        var states: [AppState] = []
        defer { states.forEach { HistoryManager.shared.removeFromHistory($0.toConfig()) } }
        func makeState() -> AppState {
            let state = AppState()
            states.append(state)
            return state
        }

        // 空白箔与纯文本通道（文本、Markdown、CSV）都是文档。
        #expect(makeState().supportsContentBackgroundColor)

        for name in ["photo.png", "vector.svg", "clip.mp4", "song.mp3"] {
            let state = makeState()
            state.originalImageName = name
            state.imageURL = URL(fileURLWithPath: "/tmp/\(name)")
            #expect(!state.supportsContentBackgroundColor, "\(name)")
        }

        for name in ["paper.pdf", "notes.txt", "notes.md", "table.csv"] {
            let state = makeState()
            state.originalImageName = name
            // PDF 复用图片内容通道，其余文档走文本通道。
            if name.hasSuffix(".pdf") {
                state.imageURL = URL(fileURLWithPath: "/tmp/\(name)")
            } else {
                state.textURL = URL(fileURLWithPath: "/tmp/\(name)")
            }
            #expect(state.supportsContentBackgroundColor, "\(name)")
        }

        // 网页：即使保留了截图缓存也仍按网页处理。
        let web = makeState()
        web.webURL = URL(string: "https://example.com")!
        #expect(web.supportsContentBackgroundColor)
        web.imageURL = URL(fileURLWithPath: "/tmp/captured-page.png")
        #expect(web.supportsContentBackgroundColor)
    }

    /// 扩展只有文档呈现属于文档箔；文本回退与音频等呈现仍以自身画面或窗口为背景。
    @Test func extensionDocumentPresentationSupportsContentBackgroundColor() {
        let documentFoil = AppState()
        defer {
            documentFoil.extensionSession = nil
            HistoryManager.shared.removeFromHistory(documentFoil.toConfig())
        }
        documentFoil.extensionSession = Self.session(
            presentation: .document(url: URL(fileURLWithPath: "/tmp/chapter.html"))
        )
        #expect(documentFoil.supportsContentBackgroundColor)

        let textFoil = AppState()
        defer {
            textFoil.extensionSession = nil
            HistoryManager.shared.removeFromHistory(textFoil.toConfig())
        }
        textFoil.extensionSession = Self.session(
            presentation: .text(titleKey: "Hi-Fi", body: "album.dsf")
        )
        #expect(!textFoil.supportsContentBackgroundColor)
    }

    @Test func contentBackgroundColorFollowsDocumentScope() {
        var states: [AppState] = []
        defer { states.forEach { HistoryManager.shared.removeFromHistory($0.toConfig()) } }
        func makeState() -> AppState {
            let state = AppState()
            states.append(state)
            return state
        }

        let text = makeState()
        text.backgroundColorHex = "#123456"
        #expect(text.contentBackgroundHex == "#123456")
        #expect(text.contentBackgroundColor == NSColor(hex: "#123456"))

        // 图片箔即使带着历史背景色，也不把它当作文档背景。
        let image = makeState()
        image.originalImageName = "photo.png"
        image.imageURL = URL(fileURLWithPath: "/tmp/photo.png")
        image.backgroundColorHex = "#123456"
        #expect(image.contentBackgroundHex == nil)
        #expect(image.contentBackgroundColor == nil)
    }

    /// 文字颜色与字体只对无排版文档内容开放：纯文本/笔记、Markdown、扩展文档（电子书）。
    @Test func textStylingScopeFollowsUnstyledDocuments() {
        var states: [AppState] = []
        defer { states.forEach { HistoryManager.shared.removeFromHistory($0.toConfig()) } }
        func makeState() -> AppState {
            let state = AppState()
            states.append(state)
            return state
        }

        // 空白箔与纯文本、Markdown：由宿主排版，可改文字颜色与字体。
        #expect(makeState().supportsDocumentTextStyling)
        for name in ["notes.txt", "notes.md"] {
            let state = makeState()
            state.originalImageName = name
            state.textURL = URL(fileURLWithPath: "/tmp/\(name)")
            #expect(state.supportsDocumentTextStyling, "\(name)")
        }

        // PDF 自带版式、CSV 是表格、网页有站点自己的排版：都不参与。
        let pdf = makeState()
        pdf.originalImageName = "paper.pdf"
        pdf.imageURL = URL(fileURLWithPath: "/tmp/paper.pdf")
        #expect(!pdf.supportsDocumentTextStyling)

        let csv = makeState()
        csv.originalImageName = "table.csv"
        csv.textURL = URL(fileURLWithPath: "/tmp/table.csv")
        #expect(!csv.supportsDocumentTextStyling)

        let web = makeState()
        web.webURL = URL(string: "https://example.com")!
        #expect(!web.supportsDocumentTextStyling)

        for name in ["photo.png", "clip.mp4", "song.mp3"] {
            let state = makeState()
            state.originalImageName = name
            state.imageURL = URL(fileURLWithPath: "/tmp/\(name)")
            #expect(!state.supportsDocumentTextStyling, "\(name)")
        }

        // 文字颜色同样只对这类内容生效。
        let text = makeState()
        text.textColorHex = "#123456"
        text.documentFontName = "Songti SC"
        text.documentLineSpacing = 1.8
        #expect(text.documentTextColorHex == "#123456")
        #expect(text.documentFontFamily?.contains("Songti SC") == true)
        #expect(text.documentLineHeightMultiple == 1.8)
        let styled = makeState()
        styled.originalImageName = "table.csv"
        styled.textURL = URL(fileURLWithPath: "/tmp/table.csv")
        styled.textColorHex = "#123456"
        styled.documentFontName = "Songti SC"
        styled.documentLineSpacing = 1.8
        #expect(styled.documentTextColorHex == nil)
        #expect(styled.documentFontFamily == nil)
        #expect(styled.documentLineHeightMultiple == nil)
    }

    /// 文字颜色的明暗适配方向与背景相反：深色主题下深色文字换成浅色。
    @Test func textColorAdaptsOppositeToBackground() {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        state.textColorHex = "#1C1C1E"
        state.adaptDocumentColorsToAppearanceChange(toDarkAppearance: true)
        #expect(state.textColorHex != "#1C1C1E", "深色文字在深色主题下未换成浅色")

        state.textColorHex = "#F5EFE0"
        state.adaptDocumentColorsToAppearanceChange(toDarkAppearance: true)
        #expect(state.textColorHex == "#F5EFE0", "浅色文字在深色主题下被改动")

        state.backgroundColorHex = "#F5EFE0"
        state.adaptDocumentColorsToAppearanceChange(toDarkAppearance: true)
        #expect(state.backgroundColorHex != "#F5EFE0", "浅色背景在深色主题下未换成深色")
    }

    /// 内容背景真的落在内容上，而不是给整个窗口着色。
    @Test func contentBackgroundRendersBehindDocumentContent() throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.originalImageName = "notes.txt"
        state.textURL = URL(fileURLWithPath: "/tmp/notes.txt")
        state.backgroundColorHex = "#123456"

        let size = CGSize(width: 400, height: 400)
        let bitmap = try render(ContentView(appState: state), size: size)
        let color = try #require(NSColor(hex: "#123456"))
        // 内容区（文本下方的空白正文）是所选背景色。
        #expect(
            try components(bitmap, at: CGPoint(x: 200, y: 120), size: size)
                .isClose(to: components(color)),
            "内容背景未使用所选颜色"
        )
        // 内容与窗口边缘之间的留白不受内容背景色影响。
        #expect(
            try components(bitmap, at: CGPoint(x: 2, y: 200), size: size)
                .distance(to: components(color)) > 16,
            "窗口留白被内容背景色染色"
        )

        // 全屏没有窗口留白，内容背景铺满整屏。
        state.isFullScreen = true
        let fullScreenBitmap = try render(ContentView(appState: state), size: size)
        #expect(
            try components(fullScreenBitmap, at: CGPoint(x: 2, y: 2), size: size)
                .isClose(to: components(color)),
            "全屏内容背景未铺满"
        )
    }

    /// 非文档箔（图片）不使用背景色：历史里带着颜色时，窗口也不能被着色。
    @Test func imageFoilDoesNotUseContentBackgroundColor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-content-background-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("photo.png")
        try writeTestImage(to: imageURL)

        let state = AppState()
        defer {
            state.resetContent()
            HistoryManager.shared.removeFromHistory(state.toConfig())
        }
        state.originalImageName = "photo.png"
        state.imageURL = imageURL
        state.backgroundColorHex = "#123456"

        let size = CGSize(width: 400, height: 400)
        let bitmap = try render(ContentView(appState: state), size: size)
        let color = try #require(NSColor(hex: "#123456"))
        // 先确认图片真的渲染出来了，像素断言才有意义。
        #expect(
            try components(bitmap, at: CGPoint(x: 200, y: 200), size: size)
                .isClose(to: ColorComponents(red: 255, green: 255, blue: 255)),
            "图片内容未渲染"
        )
        for point in [CGPoint(x: 200, y: 200), CGPoint(x: 2, y: 200), CGPoint(x: 398, y: 200)] {
            #expect(
                try components(bitmap, at: point, size: size).distance(to: components(color)) > 16,
                "图片箔的窗口不应出现内容背景色（\(point)）"
            )
        }
    }

    private func writeTestImage(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 120, height: 120))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 120, height: 120).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let representation = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(representation.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    /// 视图层真的接到了明暗切换：内容背景色随外观环境变化自动适配。
    @Test func contentViewAdaptsBackgroundOnAppearanceChange() throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.originalImageName = "notes.txt"
        state.textURL = URL(fileURLWithPath: "/tmp/notes.txt")
        state.backgroundColorHex = "#F5EFE0"

        let hosting = NSHostingView(
            rootView: ContentView(appState: state).environment(\.colorScheme, .light)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        hosting.layoutSubtreeIfNeeded()

        hosting.rootView = ContentView(appState: state).environment(\.colorScheme, .dark)
        hosting.layoutSubtreeIfNeeded()
        // 外观变化的回调在渲染之后派发，跑几轮 runloop 等它落地。
        for _ in 0..<20 where state.backgroundColorHex == "#F5EFE0" {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let adapted = try #require(state.backgroundColorHex)
        #expect(adapted != "#F5EFE0", "深色外观下浅色背景未被适配")
    }

    /// 系统明暗切换时，只有文档箔把不符主题的自选背景色换成同色相的深浅版本。
    @Test func backgroundAdaptsToSystemAppearance() throws {
        var states: [AppState] = []
        defer { states.forEach { HistoryManager.shared.removeFromHistory($0.toConfig()) } }
        func makeState() -> AppState {
            let state = AppState()
            states.append(state)
            return state
        }

        let document = makeState()
        document.backgroundColorHex = "#F5EFE0"
        document.adaptDocumentColorsToAppearanceChange(toDarkAppearance: true)
        let darkHex = try #require(document.backgroundColorHex)
        #expect(darkHex != "#F5EFE0", "浅色背景未随深色主题适配")
        #expect(NSColor(hex: darkHex)?.usingColorSpace(.sRGB)?.toHex() == darkHex)
        // 匹配主题的颜色与中间色都不改。
        document.adaptDocumentColorsToAppearanceChange(toDarkAppearance: true)
        #expect(document.backgroundColorHex == darkHex)
        document.backgroundColorHex = "#808080"
        document.adaptDocumentColorsToAppearanceChange(toDarkAppearance: true)
        #expect(document.backgroundColorHex == "#808080")

        // 图片箔不使用内容背景色，历史里带着的浅色也不会被改写。
        let image = makeState()
        image.originalImageName = "photo.png"
        image.imageURL = URL(fileURLWithPath: "/tmp/photo.png")
        image.backgroundColorHex = "#F5EFE0"
        image.adaptDocumentColorsToAppearanceChange(toDarkAppearance: true)
        #expect(image.backgroundColorHex == "#F5EFE0")
    }

    /// 离屏渲染真实视图：窗口毛玻璃在无窗口环境下透明，内容背景仍按所选颜色绘制。
    private func render(_ view: some View, size: CGSize) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return bitmap
    }

    /// 截图按显示缩放放大，采样前换算回视图坐标；色彩空间换算留 8 位容差。
    private func components(_ bitmap: NSBitmapImageRep, at point: CGPoint, size: CGSize) throws -> ColorComponents {
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        return try components(
            #require(
                bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?
                    .usingColorSpace(.sRGB)
            )
        )
    }

    private func components(_ color: NSColor) -> ColorComponents {
        ColorComponents(
            red: Int((color.redComponent * 255).rounded()),
            green: Int((color.greenComponent * 255).rounded()),
            blue: Int((color.blueComponent * 255).rounded())
        )
    }

    private static func session(presentation: SessionPresentation) -> ContentSession {
        ContentSession(
            extensionID: nil,
            providerID: "ebook.epub",
            request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/book.epub"))),
            presentation: presentation
        )
    }
}

/// 8 位分量比较：渲染与截图的色彩空间换算会带来 1~2 的偏移。
private struct ColorComponents {
    let red: Int
    let green: Int
    let blue: Int

    func isClose(to other: ColorComponents) -> Bool {
        distance(to: other) <= 2
    }

    func distance(to other: ColorComponents) -> Int {
        abs(red - other.red) + abs(green - other.green) + abs(blue - other.blue)
    }
}
