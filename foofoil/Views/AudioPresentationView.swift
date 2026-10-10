import AppKit
import SwiftUI

/// 宿主统一的音频呈现层。内置解码器和扩展播放器只提供传输状态，封面、元数据与控件均走这里。
struct AudioPresentationView<Controller: MediaTransportControlling>: View {
    @ObservedObject var appState: AppState
    @ObservedObject var controller: Controller
    let info: AudioTrackInfo
    let shouldHideBorder: Bool

    var body: some View {
        ZStack {
            backgroundLayer

            // 封面与曲目信息不是交互控件，整块内容作为拖拽区域；底部播放条仍优先处理事件。
            WindowDragArea()

            metadataBlock
                .padding(.horizontal, shouldHideBorder ? 20 : 16)
                .padding(.top, 12)
                .padding(.bottom, appState.isMediaPlaybackControlsVisible ? MediaPlaybackBarMetrics.overlayBottomInset : 12)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: info.artwork == nil ? .center : .bottomLeading
                )
                .clipped()
                .allowsHitTesting(false)

            if let quality = info.qualitySummary {
                VStack {
                    HStack {
                        HStack(spacing: 5) {
                            if info.qualityIsLossless {
                                LosslessAudioSymbol()
                                    .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                    .frame(width: 20, height: 13)
                                    .accessibilityHidden(true)
                            }
                            Text(quality)
                        }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(info.artwork == nil ? Color.primary : .white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background {
                                Capsule().fill(info.artwork == nil ? Color.primary.opacity(0.08) : .black.opacity(0.45))
                            }
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                    }
                    Spacer()
                }
                .padding(12)
                .allowsHitTesting(false)
            }

            if appState.isMediaPlaybackControlsVisible {
                VStack {
                    Spacer(minLength: 0)
                    MediaPlaybackBar(appState: appState, controller: controller)
                }
                .transition(.opacity)
            }

            VStack {
                Spacer(minLength: 0)
                MediaBottomProgressLine(controller: controller, lightContent: info.artwork != nil)
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.15), value: appState.isMediaPlaybackControlsVisible)
        .padding(shouldHideBorder ? 0 : 8)
        .onChange(of: info.artwork, initial: true) {
            // 与箔片使用同一张最终封面，包含内嵌、目录封面及用户替换图。
            MediaRemoteCommandCoordinator.shared.updateArtwork(info.artwork, for: controller)
        }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if let artwork = info.artwork {
            ZStack {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: shouldHideBorder ? .fill : .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .allowsHitTesting(false)

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.18), location: 0),
                        .init(color: .black.opacity(0.08), location: 0.42),
                        .init(color: .black.opacity(0.72), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 280, height: 280)
                    .blur(radius: 40)
                    .offset(x: -40, y: -80)
            }
        }
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if info.artwork == nil {
                artworkPlaceholder
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
            }

            Text(info.title)
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(info.artwork == nil ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: info.artwork == nil ? .center : .leading)

            if let artist = info.artist, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: 15, weight: .medium))
                    .opacity(0.92)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: info.artwork == nil ? .center : .leading)
            }

            if let tertiaryLine {
                Text(tertiaryLine)
                    .font(.system(size: 13))
                    .opacity(0.78)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: info.artwork == nil ? .center : .leading)
            }

            if let technicalLine {
                Text(technicalLine)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.68)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: info.artwork == nil ? .center : .leading)
                    .padding(.top, 4)
            }
        }
        .foregroundStyle(info.artwork == nil ? Color.primary : Color.white)
        .shadow(color: info.artwork == nil ? .clear : .black.opacity(0.35), radius: 6, y: 1)
    }

    private var artworkPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.quaternary)
                .frame(width: 148, height: 148)
            Image(systemName: "music.note")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    private var tertiaryLine: String? {
        joined([info.album, info.year, info.trackNumber.map(AudioMetadataLoader.formatTrackNumber), info.genre])
    }

    private var technicalLine: String? {
        joined([
            info.formatName,
            info.bitRate.map(AudioMetadataLoader.formatBitRate),
            info.sampleRate.map(AudioMetadataLoader.formatSampleRate),
            info.bitDepth.map(AudioMetadataLoader.formatBitDepth),
            info.channelCount.map(AudioMetadataLoader.formatChannels),
            AudioMetadataLoader.formatDuration(controller.duration)
        ])
    }

    private func joined(_ parts: [String?]) -> String? {
        let values = parts
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: "  ·  ")
    }
}

/// Apple Music 无损标记的三条平滑波形；使用矢量路径保持小尺寸与缩放时清晰。
private struct LosslessAudioSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 3, y: 33))
        path.addCurve(to: CGPoint(x: 15, y: 7), control1: CGPoint(x: 6, y: 14), control2: CGPoint(x: 10, y: 7))
        path.addCurve(to: CGPoint(x: 33, y: 44), control1: CGPoint(x: 23, y: 7), control2: CGPoint(x: 28, y: 27))
        path.addCurve(to: CGPoint(x: 51, y: 59), control1: CGPoint(x: 38, y: 61), control2: CGPoint(x: 44, y: 64))
        path.move(to: CGPoint(x: 21, y: 8))
        path.addCurve(to: CGPoint(x: 33, y: 5), control1: CGPoint(x: 25, y: 3), control2: CGPoint(x: 29, y: 3))
        path.addCurve(to: CGPoint(x: 51, y: 44), control1: CGPoint(x: 41, y: 9), control2: CGPoint(x: 46, y: 30))
        path.addCurve(to: CGPoint(x: 69, y: 54), control1: CGPoint(x: 56, y: 60), control2: CGPoint(x: 63, y: 63))
        path.addCurve(to: CGPoint(x: 79, y: 26), control1: CGPoint(x: 76, y: 44), control2: CGPoint(x: 77, y: 33))
        path.move(to: CGPoint(x: 41, y: 4))
        path.addCurve(to: CGPoint(x: 58, y: 13), control1: CGPoint(x: 47, y: 1), control2: CGPoint(x: 53, y: 4))
        path.addCurve(to: CGPoint(x: 67, y: 44), control1: CGPoint(x: 63, y: 23), control2: CGPoint(x: 64, y: 34))
        path.addCurve(to: CGPoint(x: 94, y: 26), control1: CGPoint(x: 75, y: 65), control2: CGPoint(x: 88, y: 61))
        return path.applying(CGAffineTransform(scaleX: rect.width / 100, y: rect.height / 65))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
