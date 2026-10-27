import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 小尺寸预览在独立 actor 中解码，避免滚动列表时展开原始 TIFF/PNG 到主线程内存。
private actor ClipboardArtworkDecoder {
    static let shared = ClipboardArtworkDecoder()
    func thumbnail(data: Data?, file: URL?) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source: CGImageSource?
        if let data { source = CGImageSourceCreateWithData(data as CFData, options) }
        else if let file { source = CGImageSourceCreateWithURL(file as CFURL, options) }
        else { return nil }
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 96,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary), !Task.isCancelled else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// 三个搜索入口共用相同的图像、类型图标和来源 App 角标。
@MainActor
final class ClipboardEntryArtworkView: NSView {
    private static let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128; cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    private final class SourceApplication: NSObject {
        let image: NSImage
        let name: String
        init(image: NSImage, name: String) { self.image = image; self.name = name }
    }
    private static let applications: NSCache<NSString, SourceApplication> = {
        let cache = NSCache<NSString, SourceApplication>(); cache.countLimit = 64; return cache
    }()
    private let artwork = NSImageView()
    private let sourceBadge = NSImageView()
    private var task: Task<Void, Never>?
    private var imageKey: String?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 44) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 4
        artwork.layer?.masksToBounds = true
        artwork.setAccessibilityIdentifier("clipboard.artwork.image")
        sourceBadge.imageScaling = .scaleProportionallyUpOrDown
        sourceBadge.setAccessibilityIdentifier("clipboard.artwork.source")
        addSubview(artwork); addSubview(sourceBadge)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { task?.cancel() }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel(); task = nil; imageKey = nil
        artwork.image = nil; sourceBadge.image = nil; sourceBadge.isHidden = true
    }
    func configure(_ entry: ClipboardSearchEntry) {
        // 来源取自系统记录的 related-app 字段，不能把 Spotlight 自己的索引 bundle 当作来源。
        let application = Self.sourceApplication(bundleIdentifier: entry.sourceBundleIdentifier)
        sourceBadge.image = application?.image
        sourceBadge.isHidden = application == nil
        sourceBadge.toolTip = application?.name
        sourceBadge.setAccessibilityLabel(application?.name)
        let data: Data?
        let file: URL?
        switch entry.content {
        case .image(let image): data = image; file = nil
        case .files(let urls) where urls.count == 1 && UTType(filenameExtension: urls[0].pathExtension)?.conforms(to: .image) == true:
            data = nil; file = urls[0]
        default: data = nil; file = nil
        }
        let key = "\(entry.id):\(data?.count ?? 0):\(file?.path ?? "")"
        guard key != imageKey else { return }
        task?.cancel(); imageKey = key
        artwork.contentTintColor = .secondaryLabelColor
        artwork.image = NSImage(systemSymbolName: entry.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 34, weight: .regular))
        guard data != nil || file != nil else { return }
        if let image = Self.thumbnails.object(forKey: key as NSString) {
            artwork.image = image; artwork.contentTintColor = nil; return
        }
        task = Task { [weak self] in
            guard let thumbnail = await ClipboardArtworkDecoder.shared.thumbnail(data: data, file: file),
                  !Task.isCancelled, let self, self.imageKey == key, let image = NSImage(data: thumbnail) else { return }
            Self.thumbnails.setObject(image, forKey: key as NSString, cost: 96 * 96 * 4)
            self.artwork.image = image; self.artwork.contentTintColor = nil
        }
    }
    private static func sourceApplication(bundleIdentifier: String?) -> SourceApplication? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        if let application = applications.object(forKey: bundleIdentifier as NSString) { return application }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let application = SourceApplication(image: NSWorkspace.shared.icon(forFile: url.path),
                                            name: FileManager.default.displayName(atPath: url.path))
        applications.setObject(application, forKey: bundleIdentifier as NSString)
        return application
    }
    override func layout() {
        super.layout()
        artwork.frame = NSRect(x: 2, y: 2, width: 40, height: 40)
        sourceBadge.frame = NSRect(x: 26, y: 26, width: 18, height: 18)
    }

}

struct ClipboardEntryArtwork: NSViewRepresentable {
    let entry: ClipboardSearchEntry
    func makeNSView(context: Context) -> ClipboardEntryArtworkView { ClipboardEntryArtworkView() }
    func updateNSView(_ nsView: ClipboardEntryArtworkView, context: Context) { nsView.configure(entry) }
    static func dismantleNSView(_ nsView: ClipboardEntryArtworkView, coordinator: ()) { nsView.prepareForReuse() }
}
