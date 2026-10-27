import AppKit
import Testing
@testable import foofoil

@MainActor
struct ClipboardEntryArtworkTests {
    private func imageView(_ id: String, in view: NSView) throws -> NSImageView {
        try #require(view.subviews.compactMap { $0 as? NSImageView }.first { $0.accessibilityIdentifier() == id })
    }
    @Test func imageGetsBoundedThumbnailAndLowerRightSourceBadge() async throws {
        let original = NSImage(size: NSSize(width: 1800, height: 900))
        original.lockFocus()
        NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: 1800, height: 900).fill()
        original.unlockFocus()
        let data = try #require(original.tiffRepresentation)
        let entry = ClipboardSearchEntry(id: "artwork-large-image", title: "Image", searchText: "Image", content: .image(data), date: Date(), sourceBundleIdentifier: "com.apple.finder")
        let view = ClipboardEntryArtworkView(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
        view.configure(entry)
        view.layoutSubtreeIfNeeded()
        let image = try imageView("clipboard.artwork.image", in: view)
        for _ in 0..<200 {
            if image.contentTintColor == nil && image.image != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let thumbnail = try #require(image.image)
        #expect(!thumbnail.isTemplate && image.contentTintColor == nil)
        #expect(abs(thumbnail.size.width / thumbnail.size.height - 2) < 0.001)
        #expect(thumbnail.size.width <= 96 && thumbnail.size.height <= 96)
        let badge = try imageView("clipboard.artwork.source", in: view)
        #expect(!badge.isHidden && badge.image != nil)
        #expect(badge.frame.maxX > image.frame.maxX && badge.frame.maxY > image.frame.maxY)
        #expect(badge.frame.minX > image.frame.midX && badge.frame.minY > image.frame.midY)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearance)
            view.viewDidChangeEffectiveAppearance()
            #expect(badge.layer?.backgroundColor == nil)
            #expect((badge.layer?.borderWidth ?? 0) == 0)
        }
        // 复用为普通文本时清理图像与旧角标，不能把前一条的来源留在当前条目上。
        view.prepareForReuse()
        view.configure(.init(id: "artwork-text", title: "Text", searchText: "Text", content: .text("Text"), date: Date()))
        #expect(image.image?.isTemplate == true)
        #expect(badge.isHidden && badge.image == nil)
        #expect(image.frame.size == NSSize(width: 40, height: 40))
    }
    @Test func unknownSourceDoesNotInventAnApplicationBadge() throws {
        let entry = ClipboardSearchEntry(id: "unknown-source", title: "Text", searchText: "Text", content: .text("Text"), date: Date(), sourceBundleIdentifier: "invalid.foofoil.uninstalled-app")
        let view = ClipboardEntryArtworkView(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
        view.configure(entry)
        #expect(try imageView("clipboard.artwork.source", in: view).isHidden)
    }
}
