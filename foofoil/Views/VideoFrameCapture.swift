import AppKit
import AVFoundation
import SwiftUI
import CoreImage
import IOSurface
import FoofoilExtensionKit
import ImageIO
import UniformTypeIdentifiers

/// 截取源画面而非窗口，避免把控件、边框和桌面一并写入图片。
@MainActor enum VideoFrameCapture {
    static func notification(for id: UUID) -> Notification.Name {
        Notification.Name("captureVideoFrame_\(id.uuidString)")
    }
    static func capture(player: AVPlayer, state: AppState, displaySize: CGSize, sourceSize: CGSize) {
        guard let item = player.currentItem else { return }
        let source = state.imageURL
        let time = player.currentTime()
        let subtitles = SubtitleCaptureSnapshot(controller: state.subtitles, time: time.seconds, native: true,
                                               displaySize: displaySize, sourceSize: sourceSize, controlsVisible: state.isMediaPlaybackControlsVisible)
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        Task { [weak state] in
            do {
                let result = try await generator.image(at: time)
                guard let state, state.isVideoDocument, state.imageURL == source else { return }
                finish(subtitles.composite(on: result.image), state: state)
            } catch {
                guard let state, state.isVideoDocument, state.imageURL == source else { return }
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Video Frame Capture Failed", comment: "")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
    static func finish(_ image: CGImage, state: AppState) {
        let sourceName = state.originalImageName ?? state.imageURL?.lastPathComponent ?? NSLocalizedString("Video", comment: "")
        (NSApp.delegate as? AppDelegate)?.presentContentImagePanel(image, name: imageTitle(sourceName: sourceName))
    }
    static func imageTitle(sourceName: String) -> String {
        // 使用图片扩展名作为默认保存名称。
        String(format: NSLocalizedString("Video Frame: %@", comment: ""),
               (sourceName as NSString).deletingPathExtension) + ".heic"
    }

}

/// 点击时冻结字幕内容、样式及图形数据，保存面板停留期间的视频播放不影响结果。
@MainActor struct SubtitleCaptureSnapshot {
    var text = ""
    var bitmap: CGImage?
    let style: SubtitleStyle
    let bottomFraction: Double
    init(controller: VideoSubtitleController, time: Double, native: Bool = false,
         embedded: VideoSubtitleSnapshot? = nil, displaySize: CGSize, sourceSize: CGSize, controlsVisible: Bool) {
        style = SubtitleStyleStore.shared.style
        let ratio = sourceSize.height > 0 ? sourceSize.width / sourceSize.height : displaySize.width / max(1, displaySize.height)
        let fitHeight = min(displaySize.height, displaySize.width / max(0.01, ratio))
        bottomFraction = max(style.bottom / 100, controlsVisible ? 72 / max(1, fitHeight) : 0)
        guard !controller.isHidden else { return }
        if controller.association.selectedPath != nil { text = controller.text(at: time) }
        else if native { text = controller.nativeText(at: time) }
        else if let embedded, embedded.start <= time - style.delay, time - style.delay < embedded.end {
            text = embedded.text
            if let id = embedded.surfaceID, let surface = IOSurfaceLookup(id) {
                IOSurfaceLock(surface, .readOnly, nil)
                let source = CIImage(ioSurface: surface)
                bitmap = CIContext(options: [.cacheIntermediates: false]).createCGImage(source, from: source.extent)
                IOSurfaceUnlock(surface, .readOnly, nil)
            }
        }
    }
    func composite(on image: CGImage) -> CGImage {
        guard !text.isEmpty || bitmap != nil else { return image }
        let size = CGSize(width: image.width, height: image.height)
        let renderer = ImageRenderer(content: ZStack {
            Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
            SubtitleArtwork(text: text, bitmap: bitmap, style: style, renderSize: size,
                            sourceSize: size, bottomFraction: bottomFraction)
        }.frame(width: size.width, height: size.height))
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.cgImage ?? image
    }
}
