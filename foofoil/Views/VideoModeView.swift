//
//  VideoModeView.swift
//  foofoil
//
//  Created by tolg on 2026/8/20.
//

import SwiftUI
import Combine
import AVKit
import AVFoundation

/// 使用系统 AVPlayerView 渲染视频画面，关闭自带控件以使用自定义悬浮控制条。
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

/// 视频模式视图；窗口行为与图片模式一致，鼠标移入时显示播放控件。
struct VideoModeView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var navigatorHover: NavigatorHoverState
    let url: URL
    let shouldHideBorder: Bool
    @ObservedObject private var subtitles: VideoSubtitleController
    @State private var captureDisplaySize = CGSize(width: 960, height: 540)
    @State private var videoSize = CGSize(width: 16, height: 9)
    @StateObject private var controller: VideoPlayerController

    init(appState: AppState, url: URL, shouldHideBorder: Bool) {
        self.appState = appState
        self.subtitles = appState.subtitles
        self.navigatorHover = appState.navigatorHover
        self.url = url
        self.shouldHideBorder = shouldHideBorder
        _controller = StateObject(wrappedValue: VideoPlayerController(
            appStateID: appState.id,
            url: url,
            isLooping: appState.shouldLoopCurrentItem,
            previousItemAction: { appState.activateMediaListItem(delta: -1) },
            nextItemAction: { appState.activateMediaListItem(delta: 1) },
            playbackIntentHandler: { playing in
                if playing {
                    appState.noteUserStartedMediaPlayback()
                } else {
                    appState.noteUserPausedMediaPlayback()
                }
            }
        ))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            PlayerView(player: controller.player)

            // 视频画面不是交互控件，整块画面作为拖拽区域；底部控制条仍优先处理事件。
            SubtitleOverlay(controller: subtitles, time: controller.currentTime, width: videoSize.width, height: videoSize.height, native: true, controlsVisible: appState.isMediaPlaybackControlsVisible)
            WindowDragArea()

            if appState.isMediaPlaybackControlsVisible {
                // 底部控制条：播放/暂停 + 时间 + 进度条 + 静音 + 播放模式。
                // 整个控制条区域不触发窗口拖动，控制条以外区域拖拽仍可移动窗口。
                MediaPlaybackBar(appState: appState, controller: controller)
                    // 只收窄控制条，视频画面保持原有全屏尺寸。
                    // 始终显示模式下内容区已整体被面板挤占，这里只补覆盖模式的增量。
                    .padding(appState.presentationWindowState.navigatorPanelSide == .left ? .leading : .trailing,
                             appState.fullScreenNavigatorControlBarInset)
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }

            if appState.isMediaPlaybackControlsVisible {
                VStack {
                    HStack {
                        Spacer()
                        Menu { SubtitleMenuItems(controller: subtitles) } label: { Image(systemName: "captions.bubble") }
                            .menuStyle(.borderlessButton).fixedSize().padding(10)
                            .background(.black.opacity(0.5), in: Capsule())
                            .accessibilityLabel(Text("Audio and Subtitles"))
                    }
                    Spacer()
                }
            }
            // 箔底常显的细进度线；与控制条显隐无关，设置中可关闭。
            VStack {
                Spacer(minLength: 0)
                MediaBottomProgressLine(controller: controller)
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 仅移动控制条自身高度，并裁剪窗口外的过渡内容。
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: appState.isMediaPlaybackControlsVisible)
        .animation(.easeInOut(duration: 0.25), value: appState.fullScreenNavigatorControlBarInset)
        // 与图片有边框模式保持一致的 8pt 内容边距
        .onGeometryChange(for: CGSize.self) { $0.size } action: { captureDisplaySize = $0 }
        .padding(shouldHideBorder ? 0 : 8)
        .onReceive(NotificationCenter.default.publisher(for: VideoFrameCapture.notification(for: appState.id))) { _ in
            VideoFrameCapture.capture(player: controller.player, state: appState, displaySize: captureDisplaySize, sourceSize: videoSize)
        }
        .task(id: url) { [appState] in
            subtitles.onChange = { [weak appState] in appState?.saveState() }
            await subtitles.prepare(video: url)
            await subtitles.bindNative(controller.player)
            let asset = AVURLAsset.media(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let transformed = size.applying(transform)
                videoSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            }
        }
        .onAppear {
            controller.isLooping = appState.shouldLoopCurrentItem
            controller.activateRemoteCommands()
            if appState.resumesMediaPlaybackOnActivation && !controller.isPlaying {
                controller.play()
            }
        }
        .onDisappear {
            // AppKit 全屏重挂载期间继续播放，真正离开内容时仍释放输出。
            guard !appState.presentationWindowState.isTransitioningFullScreen else { return }
            controller.stopOutput()
            MediaRemoteCommandCoordinator.shared.deactivate(controller)
            appState.isMediaPlaying = false
        }
        // 播放状态桥接到 appState，导航面板据此驱动“正在播放”图标的动效。
        .onReceive(controller.$isPlaying) { appState.isMediaPlaying = $0 }
        .onChange(of: url) {
            controller.load(url: url, autoplay: appState.resumesMediaPlaybackOnActivation)
        }
        .onChange(of: appState.shouldLoopCurrentItem) {
            controller.isLooping = appState.shouldLoopCurrentItem
        }
    }
}
