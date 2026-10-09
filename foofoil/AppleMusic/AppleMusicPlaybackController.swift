import AppKit
import Combine
import MusicKit
import FoofoilExtensionKit

/// MusicKit 只提供一个应用播放器；全部音乐箔观察同一状态，关闭其中一扇不会误停其它箔。
@MainActor
final class AppleMusicPlaybackController: ObservableObject, MediaTransportControlling {
    static let shared = AppleMusicPlaybackController()
    private static weak var live: AppleMusicPlaybackController?
    static func stopIfActive() { live?.stop() }
    private let player = ApplicationMusicPlayer.shared
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var info = AudioTrackInfo.fallback(fileName: "Apple Music")
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published private(set) var navigator: NavigatorContribution?
    var isScrubbing = false
    let isMuted = false
    let volume: Float = 1
    let volumeIconName = "speaker.wave.2"
    let supportsVolumeControl = false
    let supportsPlaybackModeControl = true
    private var timer: Timer?
    private var loadingTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var displayedEntryID: String?
    private var isQueueReady = false

    private init() {
        Self.live = self
    }

    private func startObserving() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func load(_ item: AppleMusicLibraryItem, startingAt track: Track? = nil, playbackMode: MediaPlaybackMode = .sequentialLoop) {
        startObserving()
        loadingTask?.cancel()
        error = nil
        isLoading = true
        isQueueReady = false
        navigator = nil
        loadingTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.isLoading = false } }
            do {
                AppleMusicLibrary.shared.refreshAuthorization()
                guard AppleMusicLibrary.shared.isAuthorized else {
                    self.error = NSLocalizedString("Music Authorization Required", comment: "")
                    return
                }
                let tracks = try await AppleMusicLibrary.shared.tracks(in: item)
                try Task.checkCancellation()
                guard !tracks.isEmpty else {
                    self.error = NSLocalizedString("Music No Playable Tracks", comment: "")
                    return
                }
                // 本地导入曲目不依赖订阅；订阅歌曲的资格由 MusicKit 在播放时检查。
                self.player.queue = ApplicationMusicPlayer.Queue(for: tracks, startingAt: track)
                self.applyPlaybackMode(playbackMode)
                // MusicKit 异步替换队列；准备完成前读取 entries 可能仍是上一张专辑。
                try await self.player.prepareToPlay()
                try Task.checkCancellation()
                self.isQueueReady = true
                self.refresh()
                try await self.player.play()
                if !Task.isCancelled {
                    MediaRemoteCommandCoordinator.shared.activate(self, title: item.title)
                    self.refresh()
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func refresh() {
        let playing = player.state.playbackStatus == .playing
        if isPlaying != playing { isPlaying = playing }
        if !isScrubbing { currentTime = player.playbackTime }
        let entry = player.queue.currentEntry
        if case .song(let song) = entry?.item {
            duration = song.duration ?? 0
        } else { duration = 0 }
        if isQueueReady {
            let updated = AppleMusicNavigator.synchronizing(
                entries: Array(player.queue.entries), currentEntryID: entry?.id, with: navigator
            )
            if updated != navigator { navigator = updated }
        }
        guard displayedEntryID != entry?.id else { return }
        displayedEntryID = entry?.id
        artworkTask?.cancel()
        info = AudioTrackInfo.fallback(fileName: entry?.title ?? "Apple Music")
        info.artist = entry?.subtitle
        if case .song(let song) = entry?.item { info.album = song.albumTitle }
        MediaRemoteCommandCoordinator.shared.update(self, title: info.title)
        guard let url = entry?.artwork?.url(width: 800, height: 800) else { return }
        artworkTask = Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, let self else { return }
                self.info.artwork = NSImage(data: data)
            } catch { /* 封面失败不影响播放，继续显示音乐占位图。 */ }
        }
    }

    func play() {
        startObserving()
        Task {
            do { try await player.play(); error = nil; refresh() }
            catch { self.error = error.localizedDescription }
        }
        MediaRemoteCommandCoordinator.shared.activate(self, title: info.title)
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        loadingTask?.cancel()
        artworkTask?.cancel()
        isLoading = false
        player.stop()
        refresh()
        MediaRemoteCommandCoordinator.shared.deactivate(self)
    }
    func pause() { player.pause(); refresh() }
    func togglePlayPause() { isPlaying ? pause() : play() }
    func seek(to time: Double) { player.playbackTime = max(0, min(time, duration)); refresh() }
    func adjustTime(by delta: Double) { seek(to: player.playbackTime + delta) }
    func toggleMute() {}
    func setVolume(_ newValue: Float) {}
    func adjustVolume(by delta: Float) {}
    func playPreviousItem() -> Bool { skip(forward: false); return true }
    func playNextItem() -> Bool { skip(forward: true); return true }
    private func skip(forward: Bool) {
        Task {
            do {
                if forward { try await player.skipToNextEntry() }
                else { try await player.skipToPreviousEntry() }
                refresh()
            } catch { self.error = error.localizedDescription }
        }
    }
    /// 直接选择已有队列项，保留队列身份和重复歌曲的位置。
    func selectEntry(id: String) {
        guard let entry = player.queue.entries.first(where: { $0.id == id }) else { return }
        player.queue.currentEntry = entry
        refresh()
        play()
    }

    static func playbackSettings(for mode: MediaPlaybackMode) -> (repeatMode: MusicKit.MusicPlayer.RepeatMode, shuffleMode: MusicKit.MusicPlayer.ShuffleMode) {
        switch mode {
        case .sequential: (.none, .off)
        case .sequentialLoop: (.all, .off)
        case .shuffle: (.all, .songs)
        case .singleLoop: (.one, .off)
        }
    }

    func applyPlaybackMode(_ mode: MediaPlaybackMode) {
        let settings = Self.playbackSettings(for: mode)
        player.state.repeatMode = settings.repeatMode
        player.state.shuffleMode = settings.shuffleMode
    }
}
