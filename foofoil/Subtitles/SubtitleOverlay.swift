import SwiftUI
import AVFoundation
import CoreImage
import IOSurface
import FoofoilExtensionKit

struct SubtitleOverlay: View {
    @ObservedObject var controller: VideoSubtitleController
    @ObservedObject private var settings = SubtitleStyleStore.shared
    let time: Double
    let width: Double
    let height: Double
    var embedded: VideoSubtitleSnapshot?
    var native = false
    var controlsVisible = false
    private let context = CIContext(options: [.cacheIntermediates: false])
    @State private var bitmap: CGImage?
    private var activeEmbedded: VideoSubtitleSnapshot? {
        guard !controller.isHidden, controller.association.selectedPath == nil,
              let embedded, embedded.start <= time - settings.style.delay, time - settings.style.delay < embedded.end else { return nil }
        return embedded
    }
    private var text: String {
        if controller.association.selectedPath != nil { return controller.text(at: time) }
        if controller.isHidden { return "" }
        return native ? controller.nativeText(at: time) : activeEmbedded?.text ?? ""
    }
    var body: some View {
        GeometryReader { geo in
            let ratio = max(1, width) / max(1, height)
            let fitWidth = min(geo.size.width, geo.size.height * ratio)
            let fitHeight = fitWidth / ratio
            SubtitleArtwork(text: text, bitmap: bitmap, style: settings.style,
                            renderSize: CGSize(width: fitWidth, height: fitHeight),
                            sourceSize: CGSize(width: width, height: height),
                            bottomFraction: max(settings.style.bottom / 100, controlsVisible ? 72 / max(1, fitHeight) : 0))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
        .onChange(of: activeEmbedded?.surfaceID, initial: true) { _, id in
            bitmap = nil
            guard let id, let surface = IOSurfaceLookup(id) else { return }
            IOSurfaceLock(surface, .readOnly, nil)
            let source = CIImage(ioSurface: surface)
            bitmap = context.createCGImage(source, from: source.extent)
            IOSurfaceUnlock(surface, .readOnly, nil)
        }
    }
}
struct SubtitleMenuItems: View {
    @ObservedObject var controller: VideoSubtitleController
    var body: some View {
        Button("Load Subtitle File") { controller.pickFile() }
        SubtitleVisibilityToggle(controller: controller)
        ForEach(controller.association.files, id: \.path) { file in
            Button { controller.selectFile(file) } label: {
                Label(URL(fileURLWithPath: file.path).lastPathComponent,
                      systemImage: controller.association.selectedPath == file.path && !controller.isHidden ? "checkmark" : "captions.bubble")
            }
        }
        if controller.failure != nil {
            Button("Locate Subtitle File") { controller.pickFile() }
        }
        ForEach(Array(controller.nativeOptions.enumerated()), id: \.offset) { index, option in
            Button(option.displayName) { controller.selectNative(index) }
        }
    }
}

/// 显隐仅影响当前播放，不改动字幕文件关联或历史。
struct SubtitleVisibilityToggle: View {
    @ObservedObject var controller: VideoSubtitleController
    var body: some View {
        if controller.hasLoadedSubtitle {
            Toggle("Show Subtitles", isOn: Binding(get: { !controller.isHidden }, set: { controller.setVisible($0) }))
        }
    }
}

/// 播放叠层与图片导出共用相同的排版，避免两套样式逐渐偏离。
struct SubtitleArtwork: View {
    let text: String
    let bitmap: CGImage?
    let style: SubtitleStyle
    let renderSize: CGSize
    let sourceSize: CGSize
    let bottomFraction: Double
    var body: some View {
        let scale = renderSize.height / 1080
        VStack {
            Spacer(minLength: 0)
            if let bitmap {
                Image(decorative: bitmap, scale: 1).resizable()
                    .frame(width: CGFloat(bitmap.width) * renderSize.width / max(1, sourceSize.width),
                           height: CGFloat(bitmap.height) * renderSize.height / max(1, sourceSize.height))
            } else if !text.isEmpty {
                Text(text)
                    .font(style.font.isEmpty ? .system(size: max(8, style.size * scale), weight: .semibold) : .custom(style.font, size: max(8, style.size * scale)))
                    .foregroundStyle(SubtitleStyleStore.color(style.color))
                    .multilineTextAlignment(.center)
                    .shadow(color: SubtitleStyleStore.color(style.shadow), radius: max(1, scale * 3), x: 0, y: max(1, scale * 2))
                    .padding(max(3, scale * 8))
                    .background(SubtitleStyleStore.color(style.background), in: RoundedRectangle(cornerRadius: 4))
                    .frame(maxWidth: renderSize.width * 0.9)
            }
        }
        .padding(.bottom, renderSize.height * bottomFraction)
        .frame(width: renderSize.width, height: renderSize.height)
    }
}
