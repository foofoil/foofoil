import AppKit
import SwiftUI
import Testing
import WebKit
@testable import foofoil

@MainActor
@Suite(.serialized)
struct SVGImageRenderingTests {
    // 开放路径必须继承 fill="none"；滤镜、渐变和 use 引用须由同一渲染器处理。
    private let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" fill="none">
      <defs>
        <path id="rim" d="M10 90 10 10 90 10"/>
        <linearGradient id="blue"><stop stop-color="#80c0ff"/><stop offset="1" stop-color="#4080c0"/></linearGradient>
        <filter id="blur" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="4"/></filter>
        <clipPath id="clip"><rect x="10" y="10" width="80" height="80"/></clipPath>
      </defs>
      <rect x="10" y="10" width="80" height="80" fill="url(#blue)"/>
      <g clip-path="url(#clip)"><use href="#rim" stroke="white" stroke-width="2"/></g>
      <rect x="45" y="65" width="10" height="10" fill="white" filter="url(#blur)"/>
    </svg>
    """

    @Test(arguments: [false, true])
    func inheritedFillGradientsFiltersAndTransparency(dark: Bool) async throws {
        let bitmap = try await render(svg, dark: dark)
        let interior = try pixel(bitmap, x: 25, y: 30)
        #expect(interior.blueComponent > 0.65)
        #expect(interior.redComponent > 0.2) // 不能被开放路径自动闭合后的黑色三角覆盖。
        #expect(try pixel(bitmap, x: 3, y: 3).alphaComponent < 0.05)
        let glow = try pixel(bitmap, x: 41, y: 70)
        let background = try pixel(bitmap, x: 41, y: 45)
        #expect(glow.redComponent > background.redComponent + 0.03)
    }

    @Test func tintPreservesTransparentBackground() async throws {
        let bitmap = try await render(svg, color: "#FF0000")
        let interior = try pixel(bitmap, x: 25, y: 30)
        #expect(interior.redComponent > 0.95)
        #expect(interior.blueComponent < 0.05)
        #expect(try pixel(bitmap, x: 3, y: 3).alphaComponent < 0.05)
    }

    @Test func fitAndFillKeepImageAspectRatio() async throws {
        let wide = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"50\"><rect width=\"100\" height=\"50\" fill=\"red\"/></svg>"
        let fit = try await render(wide)
        #expect(try pixel(fit, x: 50, y: 10).alphaComponent < 0.05)
        #expect(try pixel(fit, x: 50, y: 50).redComponent > 0.95)
        let fill = try await render(wide, mode: .fill)
        #expect(try pixel(fill, x: 50, y: 10).alphaComponent > 0.95)
    }

    private func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try #require(bitmap.colorAt(x: x * bitmap.pixelsWide / 100, y: y * bitmap.pixelsHigh / 100)?.usingColorSpace(.sRGB))
    }

    private func render(_ source: String, mode: ContentMode = .fit, color: String? = nil, dark: Bool = false) async throws -> NSBitmapImageRep {
        let webView = SVGWebImage.makeWebView()
        webView.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = webView
        defer { window.orderOut(nil); webView.stopLoading() }
        #expect(webView.hitTest(NSPoint(x: 50, y: 50)) == nil)
        #expect(!webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        webView.loadHTMLString(SVGWebImage.html(data: Data(source.utf8), contentMode: mode, colorHex: color), baseURL: nil)
        var ready = false
        for _ in 0..<100 {
            if !webView.isLoading, webView.url != nil {
                let state = try? await webView.evaluateJavaScript("document.readyState")
                if state as? String == "complete" { ready = true; break }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ready)
        let snapshot = try await webView.takeSnapshot(configuration: nil)
        return try #require(snapshot.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    }
}
