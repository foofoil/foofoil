import SwiftUI
import Combine
import FoofoilExtensionKit
import IOSurface
import CoreImage

/// 宿主只读取共享画面，不链接任何视频解码库。帧读取与历史保存分开，避免逐帧写数据库。
struct ExtensionVideoModeView: View {
    @ObservedObject var appState: AppState
    let shouldHideBorder: Bool
    @StateObject private var controller: ExtensionAudioPlaybackController
    @State private var frame: VideoPresentationSnapshot?
    @State private var image: CGImage?
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(appState: AppState, session: ContentSession, shouldHideBorder: Bool) {
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
            WindowDragArea()
            if appState.isMediaPlaybackControlsVisible {
                VStack {
                    HStack {
                        Spacer()
                        Menu {
                            ForEach(appState.extensionSession?.commands ?? []) { command in
                                Button {
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
                        .padding(appState.navigatorPanelSide == .left ? .leading : .trailing,
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
        .task(id: appState.extensionSession?.id) {
            guard let session = appState.extensionSession else { return }
            var lastStateRefresh = Date.distantPast
            while !Task.isCancelled {
                do {
                    let current = try await ExtensionHost.shared.perform(mediaAction: .refresh, in: session)
                    guard !Task.isCancelled, appState.extensionSession?.id == session.id else { return }
                    controller.apply(session: current)
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
