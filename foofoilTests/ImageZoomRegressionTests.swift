import AppKit
import SwiftUI
import Testing
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct ImageZoomRegressionTests {
    @Test func fullScreenStartsFittedAllowsZoomAndRestoresWindowScale() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = AppState()
        state.imageURL = url
        let controller = FloatingWindowController(appState: state)
        let window = try #require(controller.window)
        defer { window.close() }
        state.showBorder = false
        window.setFrame(NSRect(x: 100, y: 100, width: 400, height: 200), display: false)
        state.imageScale = 1
        state.showBorder = true
        #expect(abs(state.imageScale - 0.5) < 0.001)
        state.imageScale = 0.5
        controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
        window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: false)
        controller.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        #expect(abs(state.imageScale - 1.5) < 0.001)
        controller.applyInteractiveImageZoom(factor: 1.2)
        #expect(abs(state.imageScale - 1.8) < 0.001)
        #expect(window.frame.size == NSSize(width: 1200, height: 800))
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        #expect(state.imageScale == 0.5)
    }
    @Test func draggingPansOverflowAndClampsToImageEdges() {
        final class Document: NSView { override var isFlipped: Bool { true } }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let anchor = ImagePanAnchorView(frame: document.bounds)
        document.addSubview(anchor)
        scroll.documentView = document
        anchor.attachToScrollView()
        #expect(anchor.scrollView === scroll)
        scroll.contentView.scroll(to: NSPoint(x: 200, y: 150))
        anchor.beginPan()
        anchor.pan(by: NSPoint(x: -100, y: -50))
        #expect(scroll.contentView.bounds.origin == NSPoint(x: 300, y: 200))
        anchor.pan(by: NSPoint(x: 1000, y: 1000))
        #expect(scroll.contentView.bounds.origin == .zero)
        anchor.pan(by: NSPoint(x: -2000, y: -2000))
        #expect(scroll.contentView.bounds.maxX == document.frame.maxX)
        #expect(scroll.contentView.bounds.maxY == document.frame.maxY)
        document.setFrameSize(NSSize(width: 1000, height: 300))
        anchor.beginPan()
        anchor.pan(by: NSPoint(x: 0, y: -500))
        #expect(scroll.contentView.bounds.origin.y == 0)
        anchor.detach()
        #expect(scroll.contentView.gestureRecognizers.isEmpty)
    }

    @Test func swiftUIScrollViewInstallsImagePanRecognizer() async throws {
        let host = NSHostingView(rootView: ScrollView([.horizontal, .vertical]) {
            Color.red.frame(width: 1000, height: 700).background { ImagePanGesture() }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.orderFront(nil)
        func findAnchor(_ view: NSView) -> ImagePanAnchorView? {
            if let anchor = view as? ImagePanAnchorView { return anchor }
            return view.subviews.lazy.compactMap { findAnchor($0) }.first
        }
        for _ in 0..<50 {
            if findAnchor(host)?.scrollView != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let anchor = try #require(findAnchor(host))
        let scroll = try #require(anchor.scrollView)
        anchor.beginPan()
        anchor.pan(by: NSPoint(x: -100, y: -80))
        #expect(scroll.contentView.bounds.origin.x > 0)
        #expect(scroll.contentView.bounds.origin.y > 0)
    }

    @Test func zoomKeepsImagePointUnderPointerAndAccountsForCenteredMargins() {
        final class Document: NSView { override var isFlipped: Bool { true } }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document = Document(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let anchor = ImagePanAnchorView(frame: document.bounds)
        document.addSubview(anchor)
        scroll.documentView = document
        anchor.attachToScrollView()
        anchor.updateImageSize(NSSize(width: 1000, height: 700))
        scroll.contentView.scroll(to: NSPoint(x: 200, y: 150))
        anchor.updateImageSize(NSSize(width: 2000, height: 1400), pointerInViewport: NSPoint(x: 100, y: 80))
        document.setFrameSize(NSSize(width: 2000, height: 1400))
        anchor.applyPendingZoom()
        #expect(abs(scroll.contentView.bounds.minX - 500) < 0.01)
        #expect(abs(scroll.contentView.bounds.minY - 380) < 0.01)
        // 连续缩回去应回到原来的图像坐标，不积累偏移。
        anchor.updateImageSize(NSSize(width: 1000, height: 700), pointerInViewport: NSPoint(x: 100, y: 80))
        document.setFrameSize(NSSize(width: 1000, height: 700))
        anchor.applyPendingZoom()
        #expect(abs(scroll.contentView.bounds.minX - 200) < 0.01)
        #expect(abs(scroll.contentView.bounds.minY - 150) < 0.01)

        let centered = ImagePanAnchorView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        anchor.detach()
        document.addSubview(centered)
        document.setFrameSize(NSSize(width: 400, height: 300))
        scroll.contentView.scroll(to: .zero)
        centered.attachToScrollView()
        centered.updateImageSize(NSSize(width: 200, height: 200))
        centered.updateImageSize(NSSize(width: 800, height: 800), pointerInViewport: NSPoint(x: 180, y: 140))
        document.setFrameSize(NSSize(width: 800, height: 800))
        centered.applyPendingZoom()
        #expect(abs(scroll.contentView.bounds.minX - 140) < 0.01)
        #expect(abs(scroll.contentView.bounds.minY - 220) < 0.01)
    }

}
