//
//  ImageSubjectTests.swift
//  foofoil
//
//  Created by tolg on 2026/10/3.
//

import AppKit
import Foundation
import ImageIO
import Testing
@testable import foofoil

/// 图片提取主体：菜单项要等 Vision 检测出可分离主体才可用，提取结果必须是主体外透明的 PNG。
@MainActor
@Suite(.serialized)
struct ImageSubjectTests {
    /// 主体提取默认不占键位，但要在快捷键设置里可配置，并标注只对图片箔有效。
    @Test func extractSubjectShortcutIsConfigurableWithoutDefault() throws {
        let definition = try #require(KeyboardShortcutCatalog.definition(withID: "edit.extractImageSubject"))
        #expect(definition.defaultShortcut == nil)
        #expect(definition.noteKey == "Shortcut Scope Images")

        let store = KeyboardShortcutStore.shared
        defer { store.reset(definition) }
        let custom = KeyboardShortcut(keyEquivalent: "j", modifiers: [.command, .option])
        store.setShortcut(custom, for: definition)
        #expect(store.shortcut(forID: "edit.extractImageSubject") == custom)
        store.reset(definition)
        #expect(store.shortcut(forID: "edit.extractImageSubject") == nil)
    }

    /// 可用性 = 光栅图片门禁 且 已检测到主体：检测结论没落地就一律禁用。
    @Test func subjectExtractionNeedsRasterImageAndDetection() throws {
        var states: [AppState] = []
        defer { states.forEach { HistoryManager.shared.removeFromHistory($0.toConfig()) } }
        func makeState(_ name: String) -> AppState {
            let state = AppState()
            states.append(state)
            state.originalImageName = name
            state.imageURL = URL(fileURLWithPath: "/tmp/\(name)")
            return state
        }

        let photo = makeState("photo.png")
        #expect(!photo.canExtractImageSubject)
        photo.hasExtractableImageSubject = true
        #expect(photo.canExtractImageSubject)

        // 换图清空上一张图的结论，避免旧检测点亮新图片的菜单项。
        photo.imageURL = URL(fileURLWithPath: "/tmp/next.jpeg")
        #expect(!photo.hasExtractableImageSubject)
        #expect(!photo.canExtractImageSubject)

        for name in ["paper.pdf", "vector.svg", "clip.mp4", "song.mp3"] {
            let state = makeState(name)
            state.hasExtractableImageSubject = true
            #expect(!state.canExtractImageSubject, "\(name)")
        }
    }

    /// 检测结论按图去重并绑定到那张图；解码失败的图判为无主体。
    @Test func detectionResultIsTiedToTheDetectedImage() async throws {
        var states: [AppState] = []
        defer { states.forEach { HistoryManager.shared.removeFromHistory($0.toConfig()) } }
        let state = AppState()
        states.append(state)
        state.originalImageName = "missing.png"
        state.imageURL = URL(fileURLWithPath: "/tmp/foofoil-missing-\(UUID().uuidString).png")
        let url = try #require(state.imageURL)

        state.detectImageSubjectIfNeeded(for: url)
        let task = try #require(state.imageSubjectDetectionTask)
        await task.value
        #expect(!state.hasExtractableImageSubject)
        #expect(state.imageSubjectCutoutURL == nil)
        #expect(state.imageSubjectDetectedURL == url)

        // 同一张图不再起新任务。
        state.detectImageSubjectIfNeeded(for: url)
        #expect(state.imageSubjectDetectionTask == nil)

        // 换图后结论与去重记录一起作废。
        state.hasExtractableImageSubject = true
        state.imageURL = URL(fileURLWithPath: "/tmp/foofoil-next-\(UUID().uuidString).png")
        #expect(!state.hasExtractableImageSubject)
        #expect(state.imageSubjectCutoutURL == nil)
        #expect(state.imageSubjectDetectedURL != state.imageURL)
    }

    /// 管线冒烟：纯色图判为无主体；真实照片若判出主体，PNG 必须带 alpha 且主体外为透明。
    @Test func writeSubjectPNGProducesTransparencyOrRejectsImage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-subject-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let flatURL = directory.appendingPathComponent("flat.png")
        try Self.makeSolidImage().write(to: flatURL)
        let flatOut = directory.appendingPathComponent("flat-subject.png")
        #expect(!ImageSubjectExtractor.hasSubject(url: flatURL))
        #expect(!ImageSubjectExtractor.writeSubjectPNG(from: flatURL, to: flatOut))
        #expect(!FileManager.default.fileExists(atPath: flatOut.path))

        // 系统桌面图片是真实照片；这台机器取不到、或该图判不出主体时跳过强断言。
        guard let photoURL = Self.systemDesktopPictures().first else { return }
        let photoOut = directory.appendingPathComponent("photo-subject.png")
        guard ImageSubjectExtractor.writeSubjectPNG(from: photoURL, to: photoOut) else { return }
        let cutout = try #require(Self.transparencySummary(of: photoOut))
        #expect(cutout.hasAlphaChannel, "\(photoURL.lastPathComponent)")
        #expect(cutout.opaquePixels > 0)
        #expect(cutout.transparentPixels > 0)
    }

    /// 检测阶段即写出抠图缓存；提取时直接复制缓存，不再重跑 Vision，结果应与缓存同源。
    @Test func detectionCachesSubjectAndExtractionReusesIt() async throws {
        guard let photoURL = Self.systemPicturesWithSubject().first else { return }
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.originalImageName = photoURL.lastPathComponent
        state.imageURL = photoURL
        let url = try #require(state.imageURL)

        state.detectImageSubjectIfNeeded(for: url)
        let task = try #require(state.imageSubjectDetectionTask)
        await task.value
        #expect(state.hasExtractableImageSubject)
        #expect(state.canExtractImageSubject)
        let cutoutURL = try #require(state.imageSubjectCutoutURL)
        #expect(FileManager.default.fileExists(atPath: cutoutURL.path))

        // 提取回调只保留 Sendable 字段。
        var postedImageURL: URL?
        let observer = NotificationCenter.default.addObserver(
            forName: .createNewFoofoilFromImage,
            object: nil,
            queue: nil
        ) { notification in
            guard postedImageURL == nil else { return }
            postedImageURL = notification.userInfo?["imageURL"] as? URL
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let appDelegate = AppDelegate()
        appDelegate.extractImageSubject(from: state)
        #expect(state.isExtractingImageSubject)
        for _ in 0..<200 where postedImageURL == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let resultURL = try #require(postedImageURL)
        defer { try? FileManager.default.removeItem(at: resultURL) }
        // 提取结果是缓存抠图的一份拷贝，而不是重新推理得到的新文件。
        #expect(resultURL.path != cutoutURL.path)
        #expect(FileManager.default.contentsEqual(atPath: resultURL.path, andPath: cutoutURL.path))
        #expect(!state.isExtractingImageSubject)
    }

    /// 动作只走“从图片新建箔片”这条通道：结果 PNG 必须带透明，且剪贴板一个字节都不写。
    @Test func extractImageSubjectActionOpensResultInNewFoil() async throws {
        guard let photoURL = Self.systemPicturesWithSubject().first else { return }
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        let originalName = photoURL.lastPathComponent
        state.originalImageName = originalName
        state.imageURL = photoURL
        state.hasExtractableImageSubject = true
        #expect(state.canExtractImageSubject)

        // 回调里只留 Sendable 字段，避免在 @Sendable 闭包中捕获字典。
        var postedID: UUID?
        var postedImageURL: URL?
        var postedOriginalName: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .createNewFoofoilFromImage,
            object: nil,
            queue: nil
        ) { notification in
            guard postedImageURL == nil else { return }
            postedID = notification.userInfo?["id"] as? UUID
            postedImageURL = notification.userInfo?["imageURL"] as? URL
            postedOriginalName = notification.userInfo?["originalName"] as? String
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let pasteboard = NSPasteboard.general
        let pasteboardChangeCount = pasteboard.changeCount

        let appDelegate = AppDelegate()
        appDelegate.extractImageSubject(from: state)
        // 提取期间重复触发应当被门禁挡住。
        #expect(state.isExtractingImageSubject)

        // 结果由后台队列回到主队列再发布，这里让出主 Actor 轮询到通知为止。
        for _ in 0..<200 where postedImageURL == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let cutoutURL = try #require(postedImageURL)
        defer { try? FileManager.default.removeItem(at: cutoutURL) }
        #expect(postedID != nil)
        #expect(postedOriginalName?.contains(originalName) == true)
        #expect(!state.isExtractingImageSubject)

        #expect(FileManager.default.fileExists(atPath: cutoutURL.path))
        let cutout = try #require(Self.transparencySummary(of: cutoutURL))
        #expect(cutout.hasAlphaChannel)
        #expect(cutout.opaquePixels > 0)
        #expect(cutout.transparentPixels > 0)

        #expect(pasteboard.changeCount == pasteboardChangeCount)
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

    private static func systemDesktopPictures() -> [URL] {        let directory = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls.filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 真实照片样本：系统桌面图片里 Vision 判得出主体的那些，纯风景的跳过。
    private static func systemPicturesWithSubject() -> [URL] {
        Array(systemDesktopPictures().prefix(6)).filter { ImageSubjectExtractor.hasSubject(url: $0) }
    }

    /// 统计 PNG 的 alpha 情况：只有真的存在全透明像素，才说明主体外被抠掉了。
    private static func transparencySummary(of url: URL) -> (hasAlphaChannel: Bool, opaquePixels: Int, transparentPixels: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var opaque = 0
        var transparent = 0
        for alpha in stride(from: 3, to: bytes.count, by: 4) {
            if bytes[alpha] == 255 { opaque += 1 }
            else if bytes[alpha] == 0 { transparent += 1 }
        }
        let hasAlpha = image.alphaInfo != .none
            && image.alphaInfo != .noneSkipLast
            && image.alphaInfo != .noneSkipFirst
        return (hasAlpha, opaque, transparent)
    }
}
