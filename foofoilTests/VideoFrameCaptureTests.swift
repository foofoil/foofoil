import Foundation
import AppKit
import FoofoilExtensionKit
import Testing
@testable import foofoil

@MainActor @Suite(.serialized) struct VideoFrameCaptureTests {
    @Test func capturedFrameNamesCannotBeMistakenForVideos() {
        for name in ["Movie.mp4", "Movie.mkv", "Movie.avi", "Movie.mp4.mkv", "电影.mov"] {
            let title = VideoFrameCapture.imageTitle(sourceName: name)
            #expect(!AppState.isVideoFileName(title))
            #expect((title as NSString).pathExtension == "png")
        }
    }
    @Test func captureIncludesOnlyVisibleTimedSubtitlesAndFreezesStyle() throws {
        let store = SubtitleStyleStore.shared
        let original = store.style
        defer { store.style = original }
        store.style = SubtitleStyle(size: 100, background: "#000000", delay: 1)
        let controller = VideoSubtitleController()
        let cue = VideoSubtitleSnapshot(start: 1, end: 3, text: "CAPTION")
        let size = CGSize(width: 960, height: 540)
        func snapshot(at time: Double) -> SubtitleCaptureSnapshot {
            .init(controller: controller, time: time, embedded: cue, displaySize: size, sourceSize: size, controlsVisible: false)
        }
        #expect(snapshot(at: 1.5).text.isEmpty)
        let visible = snapshot(at: 2.5)
        #expect(visible.text == "CAPTION")
        controller.hide()
        #expect(snapshot(at: 2.5).text.isEmpty)
        #expect(visible.text == "CAPTION")
        store.style.color = "#FF0000"
        #expect(visible.style.color == "#FFFFFF")
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 960, pixelsHigh: 540,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        let source = try #require(rep.cgImage)
        let exported = visible.composite(on: source)
        #expect(exported.width == 960 && exported.height == 540)
        let output = NSBitmapImageRep(cgImage: exported)
        #expect(output.colorAt(x: 480, y: 485) != rep.colorAt(x: 480, y: 485))
        let hidden = snapshot(at: 2.5).composite(on: source)
        #expect(hidden === source)
    }
}
