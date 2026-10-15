import SwiftUI
import Combine
import FoofoilExtensionKit
import IOSurface
import CoreImage

/// 宿主只读取共享画面，不链接任何视频解码库。帧读取与历史保存分开，避免逐帧写数据库。
struct ExtensionVideoModeView: View {
    @ObservedObject var appState: AppState
    let shouldHideBorder: Bool
    @ObservedObject private var subtitles: VideoSubtitleController
    @ObservedObject private var subtitleStyle = SubtitleStyleStore.shared
    @State private var captureDisplaySize = CGSize(width: 960, height: 540)
    @State private var subtitleTime = 0.0
    @StateObject private var controller: ExtensionAudioPlaybackController
    @State private var frame: VideoPresentationSnapshot?
    @State private var image: CGImage?
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(appState: AppState, session: ContentSession, shouldHideBorder: Bool) {
        self.subtitles = appState.subtitles
        self.appState = appState; self.shouldHideBorder = shouldHideBorder
        _controller = StateObject(wrappedValue: ExtensionAudioPlaybackController(appState: appState, session: session))
    }
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            SubtitleOverlay(controller: subtitles, time: subtitleTime,
                            width: Double(frame?.width ?? 16), height: Double(frame?.height ?? 9), embedded: frame?.subtitle, controlsVisible: appState.isMediaPlaybackControlsVisible)
            WindowDragArea()
            if appState.isMediaPlaybackControlsVisible {
                VStack {
                    HStack {
                        Spacer()
                        Menu {
                            SubtitleMenuItems(controller: subtitles)
                            ForEach((appState.extensionSession?.commands ?? []).filter { $0.id != "video.subtitle.-1" }) { command in
                                Button {
                                    if command.id.hasPrefix("video.subtitle.") { subtitles.useEmbedded(command.id) }
                                    appState.performExtensionCommand(command.id)
                                } label: {
                                    Label(command.displayTitle ?? NSLocalizedString(command.titleLocalizationKey, comment: ""),
                                          systemImage: command.isChecked ? "checkmark" : (command.symbolName ?? "circle"))
                                }.disabled(!command.isEnabled)
                            }
                        } label: { Image(systemName: "captions.bubble") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel(Text("Audio and Subtitles"))
                        .padding(10)
                        .background(.black.opacity(0.5), in: Capsule())
                    }
                    Spacer()
                    MediaPlaybackBar(appState: appState, controller: controller)
                        .padding(appState.presentationWindowState.navigatorPanelSide == .left ? .leading : .trailing,
                                 appState.fullScreenNavigatorControlBarInset)
                }
            }
            MediaBottomProgressLine(controller: controller).allowsHitTesting(false)
            if let failure = appState.extensionSession?.mediaPlayback?.failureMessage {
                Text(failure).foregroundStyle(.white).padding().background(.black.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped().padding(shouldHideBorder ? 0 : 8)
        .onChange(of: subtitleStyle.style.delay) { _, delay in
            appState.performExtensionMediaAction(.setSubtitleDelay(delay))
        }
        .onAppear {
            controller.activateRemoteCommands()
            if appState.resumesMediaPlaybackOnActivation { controller.play() }
        }
        .onDisappear {
            controller.stopOutput()
            MediaRemoteCommandCoordinator.shared.deactivate(controller)
            appState.isMediaPlaying = false
        }
        .onReceive(controller.$isPlaying) { appState.isMediaPlaying = $0 }
        .onReceive(appState.$extensionSession.compactMap { $0 }) { session in controller.apply(session: session) }
        .onReceive(NotificationCenter.default.publisher(for: VideoFrameCapture.notification(for: appState.id))) { _ in
            if let image {
                let snapshot = SubtitleCaptureSnapshot(controller: subtitles, time: subtitleTime, embedded: frame?.subtitle,
                    displaySize: captureDisplaySize, sourceSize: CGSize(width: image.width, height: image.height),
                    controlsVisible: appState.isMediaPlaybackControlsVisible)
                VideoFrameCapture.finish(snapshot.composite(on: image), state: appState)
            }
        }
        .task(id: appState.extensionSession?.id) { [appState] in
            guard let session = appState.extensionSession else { return }
            subtitles.onChange = { [weak appState] in appState?.saveState() }
            if let url = session.request.primaryFileURL { await subtitles.prepare(video: url) }
            subtitles.hasEmbeddedSubtitles = session.commands.contains { $0.id.hasPrefix("video.subtitle.") && $0.id != "video.subtitle.-1" }
            if let selected = subtitles.association.embeddedID,
               session.commands.contains(where: { $0.id == selected }) { appState.performExtensionCommand(selected) }
            appState.performExtensionMediaAction(.setSubtitleDelay(subtitleStyle.style.delay))
            var lastStateRefresh = Date.distantPast
            while !Task.isCancelled {
                do {
                    let current = try await ExtensionHost.shared.perform(mediaAction: .refresh, in: session)
                    guard !Task.isCancelled, appState.extensionSession?.id == session.id else { return }
                    controller.apply(session: current)
                    subtitleTime = current.mediaPlayback?.position ?? 0
                    if case .video(let next) = current.presentation, next != frame {
                        if let surface = IOSurfaceLookup(next.surfaceID) {
                            IOSurfaceLock(surface, .readOnly, nil)
                            let content = CIImage(ioSurface: surface)
                            image = context.createCGImage(content, from: CGRect(x: 0, y: 0, width: next.width, height: next.height))
                            IOSurfaceUnlock(surface, .readOnly, nil)
                        }
                        if frame?.width != next.width || frame?.height != next.height {
                            NotificationCenter.default.post(name: .mediaPresentationSizeDidChange, object: nil,
                                userInfo: ["id": appState.id, "size": CGSize(width: next.width, height: next.height)])
                        }
                        frame = next
                    }
                    if Date().timeIntervalSince(lastStateRefresh) > 1 {
                        appState.performExtensionMediaAction(.refresh)
                        lastStateRefresh = Date()
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    NSLog("Video frame refresh failed: %@", error.localizedDescription)
                    return
                }
                try? await Task.sleep(for: .milliseconds(controller.isPlaying ? 16 : 150))
            }
        }
    }
}
