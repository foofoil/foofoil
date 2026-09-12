//
//  AudioModeView.swift
//  foofoil
//
//  Created by tolg on 2026/8/21.
//

import SwiftUI
import Combine
import AppKit
import FoofoilExtensionKit

/// 音频模式：封面按图片方式铺为背景，叠加曲目信息，播放控件与视频一致。
struct AudioModeView: View {
    @ObservedObject var appState: AppState
    let url: URL
    let shouldHideBorder: Bool
    @StateObject private var controller: AudioPlaybackController
    @State private var info: AudioTrackInfo

    init(appState: AppState, url: URL, shouldHideBorder: Bool) {
        self.appState = appState
        self.url = url
        self.shouldHideBorder = shouldHideBorder
        _controller = StateObject(wrappedValue: AudioPlaybackController(
            appStateID: appState.id,
            url: url,
            isLooping: appState.shouldLoopCurrentItem,
            range: appState.currentPlaybackRange,
            previousItemAction: { appState.activateMediaListItem(delta: -1) },
            nextItemAction: { appState.activateMediaListItem(delta: 1) },
            nextGaplessItemProvider: { appState.peekNextPlaybackItem() },
            playbackIntentHandler: { playing in
                if playing {
                    appState.noteUserStartedMediaPlayback()
                } else {
                    appState.noteUserPausedMediaPlayback()
                }
            }
        ))
        var fallback = AudioTrackInfo.fallback(fileName: url.lastPathComponent)
        fallback.artwork = appState.customCoverImage
        _info = State(initialValue: Self.overlay(fallback, with: appState.fileList?.currentItem?.cue))
    }

    var body: some View {
        AudioPresentationView(
            appState: appState,
            controller: controller,
            info: info,
            shouldHideBorder: shouldHideBorder
        )
        .overlay(alignment: .topTrailing) {
            outputDeviceOverlay
        }
        .onAppear {
            controller.isLooping = appState.shouldLoopCurrentItem
            if appState.resumesMediaPlaybackOnActivation {
                controller.play()
            }
        }
        .onDisappear {
            controller.closeOutput()
            MediaRemoteCommandCoordinator.shared.deactivate(controller)
            appState.isMediaPlaying = false
        }
        // 播放状态桥接到 appState，导航面板据此驱动“正在播放”图标的动效。
        .onReceive(controller.$isPlaying) { appState.isMediaPlaying = $0 }
        .onChange(of: presentationID) {
            applyCurrentTrack()
        }
        .onChange(of: appState.shouldLoopCurrentItem) {
            controller.isLooping = appState.shouldLoopCurrentItem
        }
        .task(id: presentationID) {
            let loaded = await loadTrackInfo()
            guard !Task.isCancelled else { return }
            info = loaded
            NotificationCenter.default.post(
                name: .mediaPresentationSizeDidChange,
                object: nil,
                userInfo: [
                    "id": appState.id,
                    "size": AudioMetadataLoader.presentationSize(for: loaded)
                ]
            )
        }
    }

    @ViewBuilder
    private var outputDeviceOverlay: some View {
        if let snapshot = controller.deviceServiceSnapshot {
            VStack(alignment: .trailing, spacing: 6) {
                AppKitPopupMenuButton(
                    title: pcmOutputStatus(snapshot),
                    symbolName: "hifispeaker.2",
                    items: pcmOutputMenuItems(snapshot)
                )
                .fixedSize()

                if let failure = controller.deviceFailureMessage, !failure.isEmpty {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(Color.white)
            .shadow(color: .black, radius: 2)
            .padding(14)
        }
    }

    private func pcmOutputMenuItems(_ snapshot: AudioDeviceServiceSnapshot) -> [AppKitPopupMenuButton.Item] {
        var items: [AppKitPopupMenuButton.Item] = [
            .command(
                id: "system-default",
                title: NSLocalizedString("System Default Output", comment: ""),
                selected: snapshot.pcmRouteMode == .systemDefault
            ) { [controller] in
                controller.selectSystemDefaultOutput()
            },
            .separator()
        ]
        items += snapshot.devices.map { device in
            .command(
                id: device.id,
                title: device.displayName,
                selected: snapshot.pcmRouteMode == .exclusiveDevice
                    && snapshot.selectedPCMDeviceID == device.id,
                enabled: device.isConnected && device.supportsExclusiveMode
            ) { [controller] in
                controller.selectExclusiveOutput(deviceID: device.id)
            }
        }
        return items
    }

    private func pcmOutputStatus(_ snapshot: AudioDeviceServiceSnapshot) -> String {
        if snapshot.pcmRouteMode == .systemDefault {
            let name = snapshot.devices.first(where: \.isSystemDefault)?.displayName
                ?? NSLocalizedString("System Default Output", comment: "")
            return "\(name) · \(NSLocalizedString("System Default Output", comment: ""))"
        }
        let name = snapshot.selectedPCMDeviceID.flatMap { selected in
            snapshot.devices.first(where: { $0.id == selected })?.displayName
        } ?? NSLocalizedString("Hi-Fi Output Device", comment: "")
        guard let activeRate = snapshot.activeSampleRate else {
            return "\(name) · \(NSLocalizedString("Exclusive PCM", comment: ""))"
        }
        let rate = AudioMetadataLoader.formatSampleRate(activeRate)
        if snapshot.sampleRateMatched == false, let sourceRate = snapshot.sourceSampleRate {
            return "\(name) · PCM \(AudioMetadataLoader.formatSampleRate(sourceRate))→\(rate)"
        }
        return "\(name) · \(NSLocalizedString("Exclusive PCM", comment: "")) · \(rate)"
    }

    private var presentationID: String {
        let track = appState.fileList?.currentID ?? ""
        let start = appState.currentPlaybackRange?.startCueFrames ?? 0
        let cover = appState.customCoverURL?.path ?? ""
        return "\(url.path)|\(track)|\(start)|\(cover)"
    }

    private func applyCurrentTrack() {
        controller.isLooping = appState.shouldLoopCurrentItem
        controller.load(
            url: url,
            range: appState.currentPlaybackRange,
            autoplay: appState.resumesMediaPlaybackOnActivation
        )
        var fallback = AudioTrackInfo.fallback(fileName: url.lastPathComponent)
        fallback.artwork = appState.customCoverImage
        info = Self.overlay(fallback, with: appState.fileList?.currentItem?.cue)
        // 元数据由 .task(id:) 唯一持有，切歌时自动取消上一首。
    }

    /// 读取曲目元数据；无内嵌封面且所在目录未获沙盒授权时向用户请求访问权限后重试，
    /// 成功读取同目录封面则保存文件夹书签，保证重启后仍能显示。
    private func loadTrackInfo() async -> AudioTrackInfo {
        var loaded = await AudioMetadataLoader.load(from: url)
        guard !Task.isCancelled else { return loaded }
        if appState.customCoverImage == nil {
            if loaded.artwork == nil, await appState.requestSidecarCoverAccessIfNeeded(for: url) {
                guard !Task.isCancelled else { return loaded }
                loaded = await AudioMetadataLoader.load(from: url)
                guard !Task.isCancelled else { return loaded }
                // 授权后封面才可读：补做窗口尺寸适配与历史缩略图重建
                if loaded.artwork != nil {
                    appState.sidecarCoverDidBecomeAvailable()
                }
            }
            if loaded.sidecarCoverURL != nil {
                appState.recordSidecarCoverAccess(for: url)
            }
        }
        guard !Task.isCancelled else { return loaded }
        loaded = appState.overlayCustomCover(loaded)
        appState.persistDisplayedArtworkForHistory(loaded.artwork)
        return Self.overlay(loaded, with: appState.fileList?.currentItem?.cue)
    }

    /// 箔内展示 CUE 段落元数据，封面与格式信息仍取自音频文件。
    static func overlay(_ info: AudioTrackInfo, with cue: FileListCueInfo?) -> AudioTrackInfo {
        guard let cue else { return info }
        var merged = info
        if let title = cue.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            merged.title = title
        }
        if let artist = cue.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            merged.artist = artist
        }
        if let album = cue.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            merged.album = album
        }
        if let composer = cue.composer?.trimmingCharacters(in: .whitespacesAndNewlines), !composer.isEmpty {
            merged.composer = composer
        }
        if let genre = cue.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty {
            merged.genre = genre
        }
        if let year = cue.year?.trimmingCharacters(in: .whitespacesAndNewlines), !year.isEmpty {
            merged.year = year
        }
        if let trackNumber = cue.trackNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !trackNumber.isEmpty {
            merged.trackNumber = trackNumber
        }
        return merged
    }
}
