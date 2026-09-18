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
