import AppKit
import SwiftUI
import ScreenCaptureKit
import QuartzCore
import UniformTypeIdentifiers
import ImageIO
import FoofoilExtensionKit

/// 每次保存默认 HEIC，扩展名与编码器始终由同一选项决定。
nonisolated enum ContentImageFormat: String, CaseIterable, Sendable {
    case heic, png, jpg

    var contentType: UTType {
        switch self {
        case .heic: .heic
        case .png: .png
        case .jpg: .jpeg
        }
    }

    func fileName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = ["heic", "png", "jpg", "jpeg"].contains(ext)
            ? (name as NSString).deletingPathExtension : name
        return stem + "." + rawValue
    }

    func encode(_ image: CGImage) throws -> Data {
        var encodedImage = image
        if self == .jpg {
            // JPEG 不支持透明度，透明区域合成在白色背景上，避免出现黑底。
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
            context.draw(image, in: rect)
            guard let flattened = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            encodedImage = flattened
        }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, contentType.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let options: [CFString: Any] = self == .png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(output, encodedImage, options as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}

/// 保存面板保持选项控制器存活；切换格式同步更新扩展名与允许类型。
@MainActor final class ContentImageSaveOptions: NSObject {
    private weak var panel: NSSavePanel?
    let selector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 30), pullsDown: false)
    var format: ContentImageFormat { ContentImageFormat.allCases[selector.indexOfSelectedItem] }

    init(panel: NSSavePanel, name: String) {
        self.panel = panel
        super.init()
        selector.addItems(withTitles: ContentImageFormat.allCases.map { $0.rawValue.uppercased() })
        selector.selectItem(at: 0)
        selector.target = self
        selector.action = #selector(formatChanged)
        let formatLabel = NSLocalizedString("Content Image Format", comment: "")
        let label = NSTextField(labelWithString: formatLabel)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        selector.setAccessibilityLabel(formatLabel)

        // 保存面板会拉伸 accessoryView；外层承接宽度，表单行与系统输入框的右边距一致，并保留上下留白。
        let labelWidth = max(58, label.intrinsicContentSize.width.rounded(.up))
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: max(360, labelWidth + 286), height: 64))
        let row = NSStackView(views: [label, selector])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(row)
        NSLayoutConstraint.activate([
            row.trailingAnchor.constraint(equalTo: accessory.trailingAnchor, constant: -40),
            row.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: accessory.leadingAnchor, constant: 8),
            label.widthAnchor.constraint(equalToConstant: labelWidth),
            selector.widthAnchor.constraint(equalToConstant: 230)
        ])
        panel.accessoryView = accessory
        panel.allowedContentTypes = [.heic]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = ContentImageFormat.heic.fileName(name)
    }

    @objc func formatChanged() {
        guard let panel else { return }
        let name = format.fileName(panel.nameFieldStringValue)
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = name
    }
}

/// Markdown 保存仍默认源格式；选择 HTML 时生成独立的 UTF-8 文档。
@MainActor final class ContentMarkdownSaveOptions: NSObject {
    private weak var panel: NSSavePanel?
    let selector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 230, height: 30), pullsDown: false)
    var savesHTML: Bool { selector.indexOfSelectedItem == 1 }

    init(panel: NSSavePanel) {
        self.panel = panel
        super.init()
        selector.addItems(withTitles: ["Markdown (.md)", "HTML (.html)"])
        selector.setAccessibilityLabel(NSLocalizedString("Document Format", comment: ""))
        selector.target = self
        selector.action = #selector(formatChanged)
        let row = NSStackView(views: [NSTextField(labelWithString: NSLocalizedString("Document Format", comment: "")), selector])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        row.frame = NSRect(x: 0, y: 0, width: 380, height: 64)
        panel.accessoryView = row
        panel.allowsOtherFileTypes = false
    }

    @objc func formatChanged() {
        guard let panel else { return }
        let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.allowedContentTypes = [savesHTML ? .html : UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = stem + (savesHTML ? ".html" : ".md")
    }

    /// 无原文件名时沿用正文标题提取规则，过滤路径字符并限制长度。
    nonisolated static func defaultFileName(for markdown: String, originalName: String?) -> String {
        if let originalName, !originalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return originalName
        }
        let title = WindowConfig.markdownHistoryTitle(from: markdown)
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
        let cleaned = title.components(separatedBy: invalid).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let stem = String(cleaned.prefix(80))
        return (stem.isEmpty ? "Untitled" : stem) + ".md"
    }

    nonisolated static func html(_ markdown: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root{color-scheme:light dark}body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.6;max-width:900px;margin:auto;padding:32px;overflow-wrap:anywhere}pre{padding:16px;overflow:auto;border:1px solid GrayText;border-radius:8px}code{font-family:ui-monospace,monospace}table{border-collapse:collapse}th,td{border:1px solid GrayText;padding:6px 12px}img{max-width:100%}blockquote{border-left:3px solid GrayText;margin-left:0;padding-left:16px}</style>
        </head><body>
        \(AppState.cmarkToHTML(markdown))
        </body></html>
        """
    }
}

/// 冻结源文件或正文，面板打开后切换内容不影响保存对象。
nonisolated enum ContentSavePayload: Sendable {
    case file(URL)
    case text(String, markdown: Bool)
    case webArchive
    case archive(Data)

    var contentType: UTType {
        switch self {
        case .file(let url): UTType(filenameExtension: url.pathExtension) ?? .data
        case .text(_, let markdown): markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .plainText
        case .webArchive, .archive: UTType(filenameExtension: "webarchive") ?? .data
        }
    }

    func write(to destination: URL) throws {
        let accessed = destination.startAccessingSecurityScopedResource()
        defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
        switch self {
        case .file(let source):
            let sourceAccess = source.startAccessingSecurityScopedResource()
            defer { if sourceAccess { source.stopAccessingSecurityScopedResource() } }
            if source.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL { return }
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: source, to: destination)
                return
            }
            // 使用系统替换目录原子覆盖，避免把大视频读进内存。
            let replacementDirectory = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
            defer { try? FileManager.default.removeItem(at: replacementDirectory) }
            let staged = replacementDirectory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: staged)
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        case .text(let text, _): try text.write(to: destination, atomically: true, encoding: .utf8)
        case .archive(let data): try data.write(to: destination, options: .atomic)
        case .webArchive: throw CocoaError(.fileWriteUnknown)
        }
    }
}

extension AppState {
    var canSaveContentImage: Bool {
        if isLoading || isFileOpenFeedback || isCapturingContentImage { return false }
        if isCamera { return cameraController?.hasFrame == true }
        if isAudioDocument { return audioCoverImage != nil }
        if isVideoDocument { return true }
        return webURL != nil || imageURL != nil || textURL != nil || !text.isEmpty || isExtensionDocument
    }
    var contentImageName: String {
        if isCamera {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            return NSLocalizedString("Camera Foil", comment: "") + "_" + formatter.string(from: Date()) + ".heic"
        }
        return ((originalImageName ?? "Untitled") as NSString).deletingPathExtension + ".heic"
    }
    var savesClipboardImageAsContentImage: Bool {
        imageSource == .clipboard && imageURL != nil && webURL == nil && !isExternalMediaDocument
    }

    var canSaveAs: Bool {
        selectedArchiveSession.map { $0.canExport }
            ?? (savesClipboardImageAsContentImage ? canSaveContentImage : contentSavePayload != nil)
    }

    var saveAsTitle: String {
        NSLocalizedString(terminalConfiguration != nil ? "Export Terminal Transcript..." : "Save As...", comment: "")
    }

    /// 剪贴板 Markdown 的未命名标题只是模式标记，不是来源文件名。
    var contentSaveName: String? {
        if terminalConfiguration != nil {
            return NSLocalizedString("Terminal Transcript", comment: "") + ".txt"
        }
        guard isMarkdownDocument, let textURL, Self.isManagedCacheURL(textURL),
              let originalImageName else { return originalImageName }
        let placeholderNames = Bundle.main.localizations.compactMap { localization -> String? in
            guard let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return bundle.localizedString(forKey: "Untitled Markdown", value: nil, table: nil) + ".md"
        } + [NSLocalizedString("Untitled Markdown", comment: "") + ".md"]
        return placeholderNames.contains(originalImageName) ? nil : originalImageName
    }

    var contentSavePayload: ContentSavePayload? {
        guard !isCamera, !isLoading, !isFileOpenFeedback, appleMusicReference == nil else { return nil }
        if terminalConfiguration != nil {
            // 导出当前保留的普通屏幕记录，面板打开时冻结内容，包含恢复的旧会话输出。
            return .text(terminalSession?.outputTranscript ?? "", markdown: false)
        }
        if isAudioDocument {
            let resource = extensionSession.flatMap {
                ExtensionPlaybackSupport.authorizedResource(in: $0, fileList: fileList)
            }
            let source = resource.map(Self.saveSourceURL) ?? currentAudioPresentationURL
            guard fileList?.currentItem?.cue == nil, let source,
                  !["cue", "iso"].contains(source.pathExtension.lowercased()) else { return nil }
            return .file(source)
        }
        if webURL != nil { return .webArchive }
        if let resource = extensionSession?.request.resources.first {
            // 容器会话载入失败时可能没有音频呈现，仍不可把 CUE/ISO 当普通文件导出。
            let source = Self.saveSourceURL(resource)
            guard !["cue", "iso"].contains(source.pathExtension.lowercased()) else { return nil }
            return .file(source)
        }
        if let imageURL { return .file(imageURL) }
        if textURL != nil || !text.isEmpty { return .text(text, markdown: isMarkdownDocument) }
        return nil
    }

    /// 历史恢复后的资源使用书签解析实际位置，并让保存任务持有自己的读取授权。
    nonisolated private static func saveSourceURL(_ resource: ExtensionResource) -> URL {
        guard let bookmark = resource.securityScopedBookmark else { return resource.url }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: .withoutUI,
                         bookmarkDataIsStale: &stale)) ?? resource.url
    }
}

extension AppDelegate {
    func presentContentImagePanel(_ image: NSImage, name: String) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showSaveErrorAlert(CocoaError(.fileWriteUnknown)); return
        }
        presentContentImagePanel(cgImage, name: name)
    }

    func presentContentImagePanel(_ image: CGImage, name: String) {
        let panel = NSSavePanel()
        panel.title = NSLocalizedString("Save Content Image", comment: "")
        panel.canCreateDirectories = true
        let options = ContentImageSaveOptions(panel: panel, name: name)
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            let format = options.format
            let accessed = destination.startAccessingSecurityScopedResource()
            Task { @MainActor in
                defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try format.encode(image).write(to: destination, options: .atomic)
                    }.value
                } catch { self?.showSaveErrorAlert(error) }
            }
        }
    }
    func presentContentSavePanel(_ content: ContentSavePayload, name: String?, title: String = NSLocalizedString("Save As...", comment: "")) {
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = [content.contentType]
        panel.canCreateDirectories = true
        switch content {
        case .file(let source): panel.nameFieldStringValue = name ?? source.lastPathComponent
        case .text(let text, let markdown):
            panel.nameFieldStringValue = markdown
                ? ContentMarkdownSaveOptions.defaultFileName(for: text, originalName: name)
                : name ?? "Untitled.txt"
            // JSON 等文本文件不属于 plainText，按原扩展名限制类型，避免面板强行改成 .txt。
            if let name, let type = UTType(filenameExtension: (name as NSString).pathExtension) {
                panel.allowedContentTypes = [type]
            }
        case .archive, .webArchive:
            panel.nameFieldStringValue = ((name ?? "Untitled") as NSString).deletingPathExtension + ".webarchive"
        }
        let markdownOptions: ContentMarkdownSaveOptions?
        if case .text(_, markdown: true) = content {
            markdownOptions = ContentMarkdownSaveOptions(panel: panel)
        } else { markdownOptions = nil }
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            let savesHTML = markdownOptions?.savesHTML == true
            let accessed = destination.startAccessingSecurityScopedResource()
            Task { @MainActor in
                defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        if savesHTML, case .text(let markdown, _) = content {
                            try ContentMarkdownSaveOptions.html(markdown).write(to: destination, atomically: true, encoding: .utf8)
                        } else { try content.write(to: destination) }
                    }.value
                } catch { self?.showSaveErrorAlert(error) }
            }
        }
    }
}

/// 不绘制、不接收输入的视口标记，用于排除窗口边框与嵌平导航栏。
struct FoilCaptureArea: NSViewRepresentable {
    let id: UUID
    final class Marker: NSView {
        var foilID = UUID()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Marker {
        let view = Marker(); view.foilID = id; return view
    }
    func updateNSView(_ view: Marker, context: Context) { view.foilID = id }
}

@MainActor enum FoilContentCapture {
    static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
    static func capture(in root: NSView, state: AppState) async throws -> NSImage {
        let sourceID = state.id
        let windowState = state.presentationWindowState
        state.isCapturingContentImage = true
        windowState.isCapturingContentImage = true
        defer {
            state.isCapturingContentImage = false
            windowState.isCapturingContentImage = false
        }
        // 让 SwiftUI 收起控件并提交到窗口合成器；不改变正文滚动位置和缩放。
        try await Task.sleep(for: .milliseconds(50))
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        CATransaction.flush()
        guard state.id == sourceID, let window = root.window,
              let marker = descendants(of: root).compactMap({ $0 as? FoilCaptureArea.Marker })
                .first(where: { $0.foilID == sourceID }) else { throw CocoaError(.fileReadUnknown) }
        let rect = root.convert(marker.bounds, from: marker).intersection(root.bounds)
        guard rect.width > 0, rect.height > 0 else { throw CocoaError(.fileReadUnknown) }
        let windowRect = root.convert(rect, to: nil)
        let frameSize = window.frame.size
        // 仅枚举本进程可捕获的窗口，不请求屏幕录制权限、不采集其他应用或桌面。
        // 窗口合成器可完整捕获 Quick Look/WebKit 的跨进程图层，以及 GIF 当前帧。
        let content = try await SCShareableContent.currentProcess
        guard let ownWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CocoaError(.fileReadUnknown)
        }
        let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((frameSize.width * scale).rounded())
        config.height = Int((frameSize.height * scale).rounded())
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.includeChildWindows = false
        config.captureResolution = .best
        let captured = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let scaleX = CGFloat(captured.width) / frameSize.width
        let scaleY = CGFloat(captured.height) / frameSize.height
        let crop = CGRect(x: windowRect.minX * scaleX,
                          y: (frameSize.height - windowRect.maxY) * scaleY,
                          width: windowRect.width * scaleX, height: windowRect.height * scaleY).integral
        guard state.id == sourceID, let image = captured.cropping(to: crop) else { throw CocoaError(.fileReadUnknown) }
        return NSImage(cgImage: image, size: rect.size)
    }
}
