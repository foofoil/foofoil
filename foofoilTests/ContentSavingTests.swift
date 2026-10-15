import AppKit
import SwiftUI
import Testing
import FoofoilExtensionKit
import QuickLookUI
import WebKit
import ImageIO
@testable import foofoil

@Suite(.sharedApplicationState, .serialized) @MainActor
struct ContentSavingTests {
    @Test(arguments: ContentImageFormat.allCases)
    func imageFormatsProduceMatchingDecodableFiles(_ format: ContentImageFormat) throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8,
            bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 48, y: 0, width: 48, height: 64))
        let data = try format.encode(try #require(context.makeImage()))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == format.contentType.identifier)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 96)
        #expect(decoded.height == 64)
        if format == .jpg {
            let bitmap = NSBitmapImageRep(cgImage: decoded)
            let color = try #require(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
            #expect(color.redComponent > 0.95)
            #expect(color.greenComponent > 0.95)
            #expect(color.blueComponent > 0.95)
        }
    }

    @Test func imagePanelDefaultsToHEICAndUpdatesFileExtension() {
        let panel = NSSavePanel()
        let options = ContentImageSaveOptions(panel: panel, name: "Frame.png")
        #expect(options.format == .heic)
        #expect(panel.allowedContentTypes == [.heic])
        #expect(panel.nameFieldStringValue == "Frame.heic")
        #expect(options.selector.itemTitles == ["HEIC", "PNG", "JPG"])
        options.selector.selectItem(at: 1)
        options.formatChanged()
        #expect(panel.nameFieldStringValue == "Frame.png")
        #expect(panel.allowedContentTypes == [.png])
        options.selector.selectItem(at: 2)
        options.formatChanged()
        #expect(panel.nameFieldStringValue == "Frame.jpg")
        #expect(panel.allowedContentTypes == [.jpeg])
        #expect(ContentImageFormat.heic.fileName("Chapter.1") == "Chapter.1.heic")
    }

    @Test func availabilityAndOriginalSources() throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        #expect(!state.canSaveContentImage)
        #expect(state.contentSavePayload == nil)
        state.text = "# Edited Markdown"
        state.originalImageName = "notes.md"
        #expect(state.canSaveContentImage)
        guard case .text(let text, _) = state.contentSavePayload else { Issue.record("Missing text payload"); return }
        #expect(text == "# Edited Markdown")
        state.text = ""
        state.textURL = URL(fileURLWithPath: "/tmp/empty.json")
        #expect(state.canSaveContentImage)
        #expect(state.contentSavePayload != nil)
        state.textURL = nil
        state.imageURL = URL(fileURLWithPath: "/tmp/document.pdf")
        state.originalImageName = "document.pdf"
        guard case .file(let pdf) = state.contentSavePayload else { Issue.record("Missing PDF"); return }
        #expect(pdf.pathExtension == "pdf")
        state.imageURL = nil
        state.extensionSession = ContentSession(id: UUID(), extensionID: nil, providerID: "test.document",
            request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/book.epub"))),
            presentation: .document(url: URL(fileURLWithPath: "/tmp/generated.html")))
        #expect(state.canSaveContentImage)
        guard case .file(let epub) = state.contentSavePayload else { Issue.record("Missing EPUB"); return }
        #expect(epub.pathExtension == "epub")
        state.extensionSession = nil
        state.webURL = URL(string: "https://example.com")
        guard case .webArchive = state.contentSavePayload else { Issue.record("Missing web archive"); return }
    }

    @Test func audioCoverAndContainerRestrictions() {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.imageURL = URL(fileURLWithPath: "/tmp/song.mp3")
        state.originalImageName = "song.mp3"
        #expect(!state.canSaveContentImage)
        #expect(state.contentSavePayload != nil)
        state.displayedArtwork = NSImage(size: NSSize(width: 32, height: 32))
        #expect(state.canSaveContentImage)
        state.fileList = FileListState(kind: .audio, items: [FileListItem(
            id: "track", path: "/tmp/song.mp3", displayName: "Track",
            cue: FileListCueInfo(startCueFrames: 0, cueSheetPath: "/tmp/album.cue"))], currentID: "track")
        #expect(state.contentSavePayload == nil)
        state.fileList = nil
        state.imageURL = nil
        state.extensionSession = ContentSession(id: UUID(), extensionID: nil, providerID: "test.audio",
            request: .singleFile(.init(url: URL(fileURLWithPath: "/tmp/album.iso"))),
            presentation: .text(titleKey: "Audio", body: ""))
        state.originalImageName = "album.iso"
        // 容器禁用由音频呈现元数据决定，测试使用宿主音频列表而非特定 provider ID。
        state.fileList = FileListState(kind: .audio, items: [FileListItem(id: "iso", path: "/tmp/album.iso", displayName: "Album")], currentID: "iso")
        #expect(state.contentSavePayload == nil)
        state.fileList = nil
        state.extensionSession?.presentation = .unavailable(titleKey: "Unavailable", messageKey: "Unavailable")
        #expect(state.contentSavePayload == nil)
    }

    @Test func cameraAndAppleMusicHaveNoSourceSave() {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.isCamera = true
        #expect(state.contentSavePayload == nil)
        #expect(!state.canSaveContentImage)
        state.isCamera = false
        state.appleMusicReference = AppleMusicReference(kind: .song, id: "test-song", title: "Song", subtitle: "Artist")
        #expect(state.contentSavePayload == nil)
        #expect(!state.canSaveContentImage)
    }

    @Test func payloadSurvivesContentChangesAndSamePathSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.txt")
        let target = directory.appendingPathComponent("target.txt")
        try "original".write(to: source, atomically: true, encoding: .utf8)
        try ContentSavePayload.file(source).write(to: source)
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.text = "frozen"
        let payload = try #require(state.contentSavePayload)
        state.text = "changed"
        try payload.write(to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "frozen")
    }

    @Test func copiesPackagesAndReplacesExistingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent("source.rtfd")
        let target = directory.appendingPathComponent("saved.rtfd")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try "document".write(to: package.appendingPathComponent("TXT.rtf"), atomically: true, encoding: .utf8)
        try ContentSavePayload.file(package).write(to: target)
        #expect(try String(contentsOf: target.appendingPathComponent("TXT.rtf"), encoding: .utf8) == "document")
        let file = directory.appendingPathComponent("source.mp4")
        let saved = directory.appendingPathComponent("saved.mp4")
        try Data([1, 2, 3]).write(to: file)
        try Data([9]).write(to: saved)
        try ContentSavePayload.file(file).write(to: saved)
        #expect(try Data(contentsOf: saved) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
    }

    @Test func quickLookRemoteContentIsCaptured() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let context = try #require(CGContext(data: nil, width: 240, height: 140, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 140))
        let cg = try #require(context.makeImage())
        try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])).write(to: fixture)
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.imageURL = fixture
        let content = QuickLookModeView(url: fixture).frame(width: 240, height: 140)
            .background(FoilCaptureArea(id: state.id)).padding(20).background(Color.blue)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: content)
        window.orderFront(nil)
        try await Task.sleep(for: .seconds(2))
        let image = try await FoilContentCapture.capture(in: try #require(window.contentView), state: state)
        let captured = NSBitmapImageRep(cgImage: try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        Attachment.record(image, named: "Quick Look visible content", as: .png)
        let color = try #require(captured.colorAt(x: captured.pixelsWide / 2, y: captured.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(color.greenComponent > 0.8)
        // Quick Look 对图片执行色彩管理，验证绿色主导而不是要求设备 RGB 精确相等。
        #expect(color.greenComponent > color.redComponent + 0.3)
        #expect(color.greenComponent > color.blueComponent + 0.3)
    }

    @Test func markdownFoilCapturesCurrentViewport() async throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.openText("# Visible heading\n\n" + Array(repeating: "Document content beyond the viewport.", count: 100).joined(separator: "\n\n"), isMarkdown: true)
        state.isMarkdownPreview = true
        let controller = FloatingWindowController(appState: state)
        defer { controller.close() }
        controller.showWindow(nil)
        try await Task.sleep(for: .milliseconds(300))
        let root = try #require(controller.window?.contentView)
        let image = try await FoilContentCapture.capture(in: root, state: state)
        let marker = try #require(FoilContentCapture.descendants(of: root)
            .compactMap { $0 as? FoilCaptureArea.Marker }.first { $0.foilID == state.id })
        let viewport = root.convert(marker.bounds, from: marker).intersection(root.bounds)
        #expect(abs(image.size.height - viewport.height) < 1)
        #expect(image.size.width > 100)
        #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        Attachment.record(image, named: "Markdown visible content", as: .png)
        #expect(!state.isCapturingContentImage)
    }

    @Test func webArchiveContainsDocumentAndResources() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 240, height: 140))
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFront(nil)
        defer { window.close() }
        web.loadHTMLString("<html><body><h1>Archive fixture</h1></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(5)
        while web.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            web.createWebArchiveData { continuation.resume(with: $0) }
        }
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let resource = try #require(plist["WebMainResource"] as? [String: Any])
        let body = try #require(resource["WebResourceData"] as? Data)
        #expect(String(decoding: body, as: UTF8.self).contains("Archive fixture"))
    }

    @Test func visibleCaptureHasContentAndExcludesBorder() async throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.text = "Visible viewport"
        let content = Color(red: 1, green: 0, blue: 0).frame(width: 240, height: 140)
            .background(FoilCaptureArea(id: state.id)).padding(20).background(Color.blue)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 280, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: content)
        window.orderFront(nil)
        let root = try #require(window.contentView)
        let image = try await FoilContentCapture.capture(in: root, state: state)
        #expect(image.size == NSSize(width: 240, height: 140))
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(color.redComponent > 0.8)
        #expect(color.blueComponent < 0.2)
        #expect(!state.isCapturingContentImage)
    }
}
