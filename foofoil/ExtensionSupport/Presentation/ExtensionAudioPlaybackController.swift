import Combine
import CoreAudio
import FoofoilExtensionKit
import Foundation

/// 将扩展的可序列化播放快照适配到宿主通用媒体控制协议。
@MainActor
final class ExtensionAudioPlaybackController: ObservableObject, MediaTransportControlling {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isMuted = false
    @Published private(set) var volume: Float = 1
    var isScrubbing = false
    let supportsVolumeControl = false
    let supportsPlaybackModeControl = true

    private let appStateID: UUID
    private let command: @MainActor (ExtensionMediaAction) -> Void
    private let seekAction: @MainActor (TimeInterval) -> Void
    private let hasPreviousOrNext: @MainActor () -> Bool
    private var availablePrevious: Bool
    private var availableNext: Bool
    private var availablePlay: Bool
    private var availablePause: Bool
    private let navigateHostList: @MainActor (Int) -> Bool
    private let handlePlaybackCompletion: @MainActor () -> Void
    private let notePlaybackIntent: @MainActor (Bool) -> Void
    private var mediaTitle: String
    private var observer: NSObjectProtocol?
    private var systemDevicesListener: AudioObjectPropertyListenerBlock?
    private var systemDefaultListener: AudioObjectPropertyListenerBlock?

    init(appState: AppState, session: ContentSession) {
        appStateID = appState.id
        command = { appState.performExtensionMediaAction($0) }
        seekAction = { appState.seekExtensionPlayback(to: $0) }
        notePlaybackIntent = { playing in
            if playing {
                appState.noteUserStartedMediaPlayback()
            } else {
                appState.noteUserPausedMediaPlayback()
            }
        }
        hasPreviousOrNext = {
            appState.fileList?.isPresentable == true
                || (appState.extensionSession?.playbackQueue?.items.count ?? 0) > 1
        }
        navigateHostList = { appState.activateMediaListItem(delta: $0) }
        handlePlaybackCompletion = {
            if appState.shouldLoopCurrentItem {
                appState.performExtensionMediaAction(.play)
            } else {
                appState.advanceFileListAfterPlayback()
            }
        }
        availablePrevious = true
        availableNext = true
        availablePlay = true
        availablePause = false
        mediaTitle = Self.title(for: session)
        apply(session: session)
        observer = NotificationCenter.default.addObserver(
            forName: .shouldToggleVideoPlayback,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.userInfo?["id"] as? UUID == self.appStateID else { return }
                self.togglePlayPause()
            }
        }
        if ExtensionPlaybackSupport.usesDeviceService(session) {
            startSystemDeviceObservation()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        // CoreAudio 监听的移除必须与添加使用相同的 selector；此处直接重建 address 即可。
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let listener = systemDevicesListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                DispatchQueue.main,
                listener
            )
        }
        if let listener = systemDefaultListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultAddress,
                DispatchQueue.main,
                listener
            )
        }
    }

    /// 仅当会话使用设备服务时监听系统设备；DSD 拔出/hog 由扩展 DeviceLifecycleWatch 负责。
    /// 此处只刷新宿主菜单与播放快照，避免无设备能力的通用 chrome 重复监听。
    private func startSystemDeviceObservation() {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.requestDeviceRefresh() }
        }
        let defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.requestDeviceRefresh() }
        }
        systemDevicesListener = devicesListener
        systemDefaultListener = defaultListener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            devicesListener
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            DispatchQueue.main,
            defaultListener
        )
    }

    private func requestDeviceRefresh() {
        // 运行时侧会在每次命令前刷新设备列表并在独占设备离线时自动暂停回退；
        // 这里无论是否正在播放都要触发一次 status，确保菜单立刻刷新且播放状态不卡死。
        command(.refresh)
    }

    var volumeIconName: String { "speaker.wave.3.fill" }

    func apply(session: ContentSession) {
        let wasPlaying = isPlaying
        mediaTitle = Self.title(for: session)
        let queueCount = session.playbackQueue?.items.count ?? 0
        availablePlay = session.mediaPlayback?.allows(.play, queueItemCount: queueCount) ?? false
        availablePause = session.mediaPlayback?.allows(.pause, queueItemCount: queueCount) ?? false
        availablePrevious = session.mediaPlayback?.allows(.previous, queueItemCount: queueCount)
            ?? (queueCount > 1)
        availableNext = session.mediaPlayback?.allows(.next, queueItemCount: queueCount)
            ?? (queueCount > 1)
        guard let playback = session.mediaPlayback else { return }
        isPlaying = playback.state == .playing
        currentTime = playback.position
        duration = playback.duration ?? 0
        MediaRemoteCommandCoordinator.shared.update(self, title: mediaTitle)
        if wasPlaying,
           playback.state == .stopped,
           duration > 0,
           currentTime >= duration - 0.05 {
            let completion = handlePlaybackCompletion
            Task { @MainActor in completion() }
        }
    }

    func activateRemoteCommands() {
        MediaRemoteCommandCoordinator.shared.activate(self, title: mediaTitle)
    }

    func play() {
        notePlaybackIntent(true)
        guard availablePlay else { return }
        startPlayback()
    }

    func pause() {
        notePlaybackIntent(false)
        guard availablePause else {
            isPlaying = false
            return
        }
        stopOutput()
    }

    /// 视图卸载或自然播完时停输出，不改写用户的播放/暂停意图。
    func stopOutput() {
        command(.pause)
        isPlaying = false
        MediaRemoteCommandCoordinator.shared.update(self)
    }

    private func startPlayback() {
        command(.play)
        isPlaying = true
        activateRemoteCommands()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }
    func toggleMute() {}
    func setVolume(_ newValue: Float) {}
    func adjustVolume(by delta: Float) {}

    func seek(to time: Double) {
        let clamped = min(duration, max(0, time))
        currentTime = clamped
        seekAction(clamped)
        MediaRemoteCommandCoordinator.shared.update(self)
    }

    func adjustTime(by delta: Double) {
        guard duration > 0 else { return }
        seek(to: currentTime + delta)
    }

    func playPreviousItem() -> Bool {
        if navigateHostList(-1) { return true }
        guard availablePrevious || hasPreviousOrNext() else { return false }
        guard availablePrevious else { return false }
        command(.previous)
        return true
    }

    func playNextItem() -> Bool {
        if navigateHostList(1) { return true }
        guard availableNext || hasPreviousOrNext() else { return false }
        guard availableNext else { return false }
        command(.next)
        return true
    }

    private static func title(for session: ContentSession) -> String {
        if let queue = session.playbackQueue,
           let currentID = queue.currentItemID,
           let item = queue.items.first(where: { $0.id == currentID }) {
            return item.title
        }
        return session.request.primaryFileURL?.deletingPathExtension().lastPathComponent ?? ""
    }
}
