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
        guard !controller.association.isHidden, controller.association.selectedPath == nil,
              let embedded, embedded.start <= time - settings.style.delay, time - settings.style.delay < embedded.end else { return nil }
        return embedded
    }
    private var text: String {
        if controller.association.selectedPath != nil { return controller.text(at: time) }
        if controller.association.isHidden { return "" }
        return native ? controller.nativeText(at: time) : activeEmbedded?.text ?? ""
    }
    var body: some View {
        GeometryReader { geo in
            let ratio = max(1, width) / max(1, height)
            let fitWidth = min(geo.size.width, geo.size.height * ratio)
            let fitHeight = fitWidth / ratio
            let scale = fitHeight / 1080
            VStack {
                Spacer(minLength: 0)
                if let active = activeEmbedded, active.surfaceID != nil, let bitmap {
                    Image(decorative: bitmap, scale: 1).resizable()
                        .frame(width: CGFloat(active.width ?? 0) * fitWidth / max(1, width),
                               height: CGFloat(active.height ?? 0) * fitHeight / max(1, height))
                } else if !text.isEmpty {
                    Text(text)
                        .font(settings.style.font.isEmpty ? .system(size: max(8, settings.style.size * scale), weight: .semibold) : .custom(settings.style.font, size: max(8, settings.style.size * scale)))
                        .foregroundStyle(SubtitleStyleStore.color(settings.style.color))
                        .multilineTextAlignment(.center)
                        .shadow(color: SubtitleStyleStore.color(settings.style.shadow), radius: max(1, scale * 3), x: 0, y: max(1, scale * 2))
                        .padding(max(3, scale * 8))
                        .background(SubtitleStyleStore.color(settings.style.background), in: RoundedRectangle(cornerRadius: 4))
                        .frame(maxWidth: fitWidth * 0.9)
                }
            }
            .padding(.bottom, max(fitHeight * settings.style.bottom / 100, controlsVisible ? 72 : 0))
            .frame(width: fitWidth, height: fitHeight)
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
        Button("Subtitles Off") { controller.hide() }
        ForEach(controller.association.files, id: \.path) { file in
            Button { controller.selectFile(file) } label: {
                Label(URL(fileURLWithPath: file.path).lastPathComponent,
                      systemImage: controller.association.selectedPath == file.path && !controller.association.isHidden ? "checkmark" : "captions.bubble")
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
