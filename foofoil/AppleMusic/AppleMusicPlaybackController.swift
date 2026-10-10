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
    private var playbackTask: Task<Void, Never>?
    private var skipTask: Task<Void, Never>?
    private let playbackOwnerID = UUID()
    private var playbackGeneration: UInt64 = 0
    private var loadedSelection: (item: AppleMusicLibraryItem, track: Track?, mode: MediaPlaybackMode)?
    private var artworkTask: Task<Void, Never>?
    private var qualityTask: Task<Void, Never>?
    private var availableAudioVariants: [AudioVariant]?
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
        playbackGeneration &+= 1
        let generation = playbackGeneration
        let requestToken = AudioPlaybackCoordinator.shared.request(ownerID: playbackOwnerID)
        loadedSelection = (item, track, playbackMode)
        let precedingLoad = loadingTask
        let precedingPlayback = playbackTask
        let precedingSkip = skipTask
        loadingTask?.cancel()
        playbackTask?.cancel()
        skipTask?.cancel()
        player.pause()
        artworkTask?.cancel()
        qualityTask?.cancel()
        availableAudioVariants = nil
        displayedEntryID = nil
        info = AudioTrackInfo.fallback(fileName: item.title)
        info.artist = item.subtitle
        error = nil
        isLoading = true
        isQueueReady = false
        navigator = nil
        loadingTask = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.isLoading = false } }
            // MusicKit 的 prepare/play/skip 按调用顺序执行，避免同一应用播放器并发替换队列。
            await precedingLoad?.value
            await precedingPlayback?.value
            await precedingSkip?.value
            do {
                try Task.checkCancellation()
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
                let token = try await self.acquirePlayback(generation: generation, requestToken: requestToken)
                try Task.checkCancellation()
                // 先完成其它音频的暂停/设备释放，再让 MusicKit 准备系统输出。
                // 本地导入曲目不依赖订阅；订阅歌曲的资格由 MusicKit 在播放时检查。
                self.player.queue = ApplicationMusicPlayer.Queue(for: tracks, startingAt: track)
                self.applyPlaybackMode(playbackMode)
                // MusicKit 异步替换队列；准备完成前读取 entries 可能仍是上一张专辑。
                try await self.player.prepareToPlay()
                try Task.checkCancellation()
                guard generation == self.playbackGeneration,
                      AudioPlaybackCoordinator.shared.isCurrent(ownerID: self.playbackOwnerID, token: token) else { return }
                self.isQueueReady = true
                self.refresh()
                try await self.startPlayback(generation: generation, token: token)
            } catch is CancellationError {
                // 新输出或用户暂停已取代本次准备。
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func refresh() {
        var playing = player.state.playbackStatus == .playing
        if playing, !AudioPlaybackCoordinator.shared.isOwner(playbackOwnerID) {
            player.pause()
            playing = false
        }
        if isPlaying != playing { isPlaying = playing }
        if !isScrubbing { currentTime = player.playbackTime }
        guard isQueueReady else { return }
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
        let entryChanged = displayedEntryID != entry?.id
        if entryChanged { availableAudioVariants = nil }
        let quality = AppleMusicAudioQuality.summary(current: player.state.audioVariant, available: availableAudioVariants)
        if info.qualitySummary != quality { info.qualitySummary = quality }
        let isLossless = AppleMusicAudioQuality.isLossless(current: player.state.audioVariant, available: availableAudioVariants)
        if info.qualityIsLossless != isLossless { info.qualityIsLossless = isLossless }
        guard entryChanged else { return }
        displayedEntryID = entry?.id
        artworkTask?.cancel()
        info = AudioTrackInfo.fallback(fileName: entry?.title ?? "Apple Music")
        info.artist = entry?.subtitle
        info.qualitySummary = quality
        info.qualityIsLossless = isLossless
        fetchAvailableAudioVariants(for: entry)
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

    /// 每次换曲只补查一次扩展元数据；失败不影响播放，迟到响应不能覆盖新曲目。
    private func fetchAvailableAudioVariants(for entry: MusicKit.MusicPlayer.Queue.Entry?) {
        qualityTask?.cancel()
        guard let entry, case .song(let song) = entry.item else { return }
        if let variants = song.audioVariants { availableAudioVariants = variants }
        qualityTask = Task { [weak self] in
            do {
                let detailed = try await song.with([.audioVariants])
                guard !Task.isCancelled, let self, self.displayedEntryID == entry.id, self.isQueueReady else { return }
                self.availableAudioVariants = detailed.audioVariants
                #if DEBUG
                NSLog("Apple Music audio metadata: playing=%@; available=%@", self.player.state.audioVariant?.description ?? "unavailable", detailed.audioVariants?.map(\.description).joined(separator: ", ") ?? "unavailable")
                #endif
                self.refresh()
            } catch {
                #if DEBUG
                if !Task.isCancelled {
                    NSLog("Apple Music audio metadata: extended attributes unavailable; playing=%@", self?.player.state.audioVariant?.description ?? "unavailable")
                }
                #endif
                // 曲目未提供音质元数据时保留播放器标签，不推测音源规格。
            }
        }
    }

    private func acquirePlayback(generation: UInt64, requestToken: UInt64) async throws -> UInt64 {
        try await AudioPlaybackCoordinator.shared.acquire(
            ownerID: playbackOwnerID, requestToken: requestToken,
            pause: { [weak self] in self?.pause() },
            isCurrent: { [weak self] in self?.playbackGeneration == generation }
        )
    }

    private func startPlayback(generation: UInt64, token: UInt64) async throws {
        guard generation == playbackGeneration,
              AudioPlaybackCoordinator.shared.isCurrent(ownerID: playbackOwnerID, token: token) else { throw CancellationError() }
        try Task.checkCancellation()
        try await player.play()
        // MusicKit 可能在取消后才返回；失去播放权时不能让迟到请求重新发声。
        guard !Task.isCancelled, generation == playbackGeneration,
              AudioPlaybackCoordinator.shared.isCurrent(ownerID: playbackOwnerID, token: token) else {
            if !AudioPlaybackCoordinator.shared.isOwner(playbackOwnerID) { player.pause() }
            refresh()
            return
        }
        error = nil
        MediaRemoteCommandCoordinator.shared.activate(self, title: info.title)
        refresh()
    }

    func play() {
        if !isQueueReady, let selection = loadedSelection {
            load(selection.item, startingAt: selection.track, playbackMode: selection.mode)
            return
        }
        startObserving()
        playbackGeneration &+= 1
        let generation = playbackGeneration
        let requestToken = AudioPlaybackCoordinator.shared.request(ownerID: playbackOwnerID)
        let precedingLoad = loadingTask
        let precedingPlayback = playbackTask
        let precedingSkip = skipTask
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            guard let self else { return }
            await precedingLoad?.value
            await precedingPlayback?.value
            await precedingSkip?.value
            do {
                try Task.checkCancellation()
                let token = try await self.acquirePlayback(generation: generation, requestToken: requestToken)
                try await self.startPlayback(generation: generation, token: token)
            } catch is CancellationError {
                // 新播放或暂停已取代此请求。
            } catch {
                if !Task.isCancelled, generation == self.playbackGeneration { self.error = error.localizedDescription }
            }
        }
    }
    func stop() {
        pause()
        timer?.invalidate()
        timer = nil
        loadingTask?.cancel()
        artworkTask?.cancel()
        qualityTask?.cancel()
        isLoading = false
        player.stop()
        refresh()
        MediaRemoteCommandCoordinator.shared.deactivate(self)
    }
    func pause() {
        AudioPlaybackCoordinator.shared.cancel(ownerID: playbackOwnerID)
        playbackGeneration &+= 1
        loadingTask?.cancel()
        playbackTask?.cancel()
        skipTask?.cancel()
        isLoading = false
        player.pause()
        refresh()
    }
    func togglePlayPause() { isPlaying ? pause() : play() }
    func seek(to time: Double) { player.playbackTime = max(0, min(time, duration)); refresh() }
    func adjustTime(by delta: Double) { seek(to: player.playbackTime + delta) }
    func toggleMute() {}
    func setVolume(_ newValue: Float) {}
    func adjustVolume(by delta: Float) {}
    func playPreviousItem() -> Bool { skip(forward: false); return true }
    func playNextItem() -> Bool { skip(forward: true); return true }
    private func skip(forward: Bool) {
        let generation = playbackGeneration
        let precedingLoad = loadingTask
        let precedingPlayback = playbackTask
        let precedingSkip = skipTask
        skipTask?.cancel()
        skipTask = Task { [weak self] in
            guard let self else { return }
            await precedingLoad?.value
            await precedingPlayback?.value
            await precedingSkip?.value
            do {
                try Task.checkCancellation()
                if forward { try await self.player.skipToNextEntry() }
                else { try await self.player.skipToPreviousEntry() }
                if !AudioPlaybackCoordinator.shared.isOwner(self.playbackOwnerID) { self.player.pause() }
                self.refresh()
            } catch {
                if !Task.isCancelled, generation == self.playbackGeneration { self.error = error.localizedDescription }
            }
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
