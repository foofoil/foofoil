import Combine
import FoofoilExtensionKit
import SwiftUI

/// 扩展音频复用宿主音频模式；视觉、交互、封面与快捷键不进入插件。
struct ExtensionAudioModeView: View {
    @ObservedObject var appState: AppState
    let shouldHideBorder: Bool
    @StateObject private var controller: ExtensionAudioPlaybackController
    @State private var info: AudioTrackInfo

    init(appState: AppState, session: ContentSession, shouldHideBorder: Bool) {
        self.appState = appState
        self.shouldHideBorder = shouldHideBorder
        _controller = StateObject(wrappedValue: ExtensionAudioPlaybackController(appState: appState, session: session))
        let url = ExtensionPlaybackSupport.presentationURL(in: session, fileList: appState.fileList)
        var fallback = AudioTrackInfo.fallback(fileName: url?.lastPathComponent ?? "")
        fallback.artwork = appState.customCoverImage
        _info = State(initialValue: AudioModeView.overlay(
            fallback,
            with: appState.fileList?.currentItem?.cue
        ))
    }

    var body: some View {
        AudioPresentationView(
            appState: appState,
            controller: controller,
            info: info,
            shouldHideBorder: shouldHideBorder
        )
        .overlay(alignment: .topTrailing) {
            statusOverlay
        }
        .onAppear {
            appState.isMediaPlaybackControlsVisible = !appState.resumesMediaPlaybackOnActivation
                || appState.isPointerInsideWindow
            controller.activateRemoteCommands()
            if appState.resumesMediaPlaybackOnActivation {
                controller.play()
            }
        }
        .onDisappear {
            controller.stopOutput()
            MediaRemoteCommandCoordinator.shared.deactivate(controller)
            appState.isMediaPlaying = false
        }
        .onReceive(appState.$extensionSession.compactMap { $0 }) { session in
            guard ExtensionPlaybackSupport.usesHostAudioChrome(session) else { return }
            controller.apply(session: session)
        }
        .onReceive(controller.$isPlaying) { appState.isMediaPlaying = $0 }
        .task(id: presentationID) {
            if let url = appState.currentAudioPresentationURL {
                info = AudioTrackInfo.fallback(fileName: url.lastPathComponent)
            }
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
        .task(id: controller.isPlaying) {
            while controller.isPlaying, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                appState.performExtensionMediaAction(.refresh)
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let session = appState.extensionSession {
            VStack(alignment: .trailing, spacing: 6) {
                if let selection = session.audioDeviceSelection,
                   let status = selection.statusDescription,
                   !status.isEmpty {
                    AppKitPopupMenuButton(
                        title: status,
                        symbolName: "hifispeaker.2",
                        items: selection.devices.map { device in
                            .command(
                                id: device.id,
                                title: device.displayName,
                                selected: selection.selectedDeviceID == device.id,
                                enabled: device.isConnected && isDSDDeviceEnabled(device.id, in: session)
                            ) {
                                appState.performExtensionMediaAction(.selectDevice(device.id))
                            }
                        }
                    )
                    .fixedSize()
                }
                if let handoffFailure = appState.extensionHandoffFailureMessage,
                   !handoffFailure.isEmpty {
                    Label(handoffFailure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if session.mediaPlayback?.state == .failed {
                    Label(
                        NSLocalizedString(
                            session.mediaPlayback?.failureMessage ?? "Hi-Fi Playback Failed",
                            comment: ""
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                        .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(Color.white)
            .shadow(color: .black.opacity(0.9), radius: 2)
            .padding(14)
        }
    }

    private func isDSDDeviceEnabled(_ deviceID: String, in session: ContentSession) -> Bool {
        ExtensionPlaybackSupport.isOutputDeviceEnabled(deviceID, in: session)
    }

    private var presentationID: String {
        guard let session = appState.extensionSession else { return "" }
        let cover = appState.customCoverURL?.path ?? ""
        return "\(session.id.uuidString)|\(session.playbackQueue?.currentItemID ?? "")|\(cover)"
    }

    private func loadTrackInfo() async -> AudioTrackInfo {
        guard let session = appState.extensionSession,
              let url = ExtensionPlaybackSupport.presentationURL(in: session, fileList: appState.fileList) else {
            return AudioTrackInfo.fallback(fileName: "")
        }
        var loaded = await AudioMetadataLoader.load(from: url)
        if appState.customCoverImage == nil {
            if loaded.artwork == nil, await appState.requestSidecarCoverAccessIfNeeded(for: url) {
                loaded = await AudioMetadataLoader.load(from: url)
                if loaded.artwork != nil { appState.sidecarCoverDidBecomeAvailable() }
            }
            if loaded.sidecarCoverURL != nil { appState.recordSidecarCoverAccess(for: url) }
        }
        loaded = appState.overlayCustomCover(loaded)
        appState.persistDisplayedArtworkForHistory(loaded.artwork)
        return AudioModeView.overlay(loaded, with: appState.fileList?.currentItem?.cue)
    }
}
