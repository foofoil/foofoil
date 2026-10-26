import Testing
import AppKit
import PDFKit
@testable import foofoil

struct QuickLookHistoryThumbnailTests {
    @Test func contentPreviewAndFinderFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let document = PDFDocument()
        document.insert(try #require(PDFPage(image: image)), at: 0)
        let pdf = directory.appendingPathComponent("preview.pdf")
        try #require(document.write(to: pdf))
        let unknown = directory.appendingPathComponent("fallback.foofoil-unknown")
        try Data("unsupported preview".utf8).write(to: unknown)
        for source in [pdf, unknown] {
            let target = source.appendingPathExtension("heic")
            let generated = await Task.detached {
                HistoryThumbnailGenerator.generateThumbnail(for: source, kind: .quickLook, destinationURL: target)
            }.value
            #expect(generated)
            let bitmap = try #require(NSBitmapImageRep(data: Data(contentsOf: target)))
            #expect(bitmap.pixelsWide == HistoryThumbnailGenerator.pixelSize)
            #expect(bitmap.pixelsHigh == HistoryThumbnailGenerator.pixelSize)
            if source == pdf {
                let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
                #expect(center.redComponent > 0.8 && center.greenComponent < 0.2)
            } else {
                let corner = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
                #expect(corner.redComponent > 0.9 && corner.greenComponent > 0.9 && corner.blueComponent > 0.9)
            }
        }
    }
}
