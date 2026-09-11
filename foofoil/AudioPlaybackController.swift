//
//  AudioPlaybackController.swift
//  foofoil
//
//  Created by tolg on 2026/8/28.
//

import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import FoofoilExtensionKit

/// 音频按采样点播一段：CUE+FLAC 不能靠 AVPlayer seek，要用 scheduleSegment。
@MainActor
final class AudioPlaybackController: ObservableObject, MediaTransportControlling {
    private static let liveControllers = NSHashTable<AudioPlaybackController>.weakObjects()

    static func stopAllOutputsForTermination() {
        for controller in liveControllers.allObjects { controller.closeOutput() }
    }

    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published private(set) var isMuted = false
    @Published private(set) var volume: Float = 1.0
    @Published private(set) var deviceServiceSnapshot: AudioDeviceServiceSnapshot?
    @Published private(set) var deviceFailureMessage: String?
    var isScrubbing = false
    var isLooping: Bool

    private let appStateID: UUID
    private var engineStorage: AVAudioEngine?
    private var engine: AVAudioEngine {
        if let engineStorage { return engineStorage }
        let created = AVAudioEngine()
        created.attach(playerNode)
        engineStorage = created
        // 首次播放也必须接通节点；仅 attach 不会建立到输出的连接。
        if let format = audioFile?.processingFormat {
            created.connect(playerNode, to: created.mainMixerNode, format: format)
            applyVolume()
        }
        return created
    }
    private var engineStartError: Error?
    private let playerNode = AVAudioPlayerNode()
    private let deviceServiceClientID = UUID()
    private var activeLeaseClientID: UUID?
    private var selectedOutputDeviceID: String?
    private var hasLoadedOutputPreference = false
    private var audioFile: AVAudioFile?
    private var currentFileAccess: PlaybackFileAccess?
    private var currentFileURL: URL?
    private var loadedContentIdentity: PlaybackContentIdentity?
    private var startFrame: AVAudioFramePosition = 0
    private var segmentFrames: AVAudioFrameCount = 0
    private var sampleRate: Double = 44100
    private var sourceChannelCount = 2
    /// 无缝衔接时 playerTime 不会因 stop 归零，用原点把下一曲进度从 0 算起。
    private var playerTimeOrigin: Double = 0
    private var scheduledRemainingFrames: AVAudioFrameCount = 0
    private var queuedSuccessor: QueuedSuccessor?
    private var preparedDeviceID: String?
    /// 引擎输出 AudioUnit 是否被钉到独占设备；租约释放后钉住仍在，重建后才清除。
    private var enginePinnedToExclusiveDevice = false
    private var preparedSourceSampleRate: Double?
    private var routeGeneration: UInt64 = 0
    private var scheduledDisplayStart: Double = 0
    private var scheduleGeneration: UInt64 = 0
    /// 播放卡住看门狗的代次；暂停/重排后旧检查自动失效，只重试一次。
    private var stallWatchdogGeneration: UInt64 = 0
    /// 独占设备心跳监听：DAC 重枚举会杀死 ioProc，抖动后只重建 ioProc，不碰 hog 与格式。
    private var exclusiveDeviceListener: AudioObjectPropertyListenerBlock?
    private var exclusiveObservedDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var exclusiveIORefreshGeneration: UInt64 = 0
    /// 同控制器发往设备服务的命令尾链，保证暂停释放先于获取到达扩展侧。
    private var deviceCommandTail: Task<Void, Never>?
    private var progressTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var systemDevicesListener: AudioObjectPropertyListenerBlock?
    private var systemDefaultListener: AudioObjectPropertyListenerBlock?
    private var mediaTitle: String
    private let previousItemAction: @MainActor () -> Bool
    private let nextItemAction: @MainActor () -> Bool
    private let nextGaplessItemProvider: @MainActor () -> (URL, MediaPlaybackRange?)?
    private let playbackIntentHandler: (@MainActor (Bool) -> Void)?

    init(
        appStateID: UUID,
        url: URL,
        isLooping: Bool,
        range: MediaPlaybackRange? = nil,
        previousItemAction: @escaping @MainActor () -> Bool = { false },
        nextItemAction: @escaping @MainActor () -> Bool = { false },
        nextGaplessItemProvider: @escaping @MainActor () -> (URL, MediaPlaybackRange?)? = { nil },
        playbackIntentHandler: (@MainActor (Bool) -> Void)? = nil
    ) {
        self.appStateID = appStateID
        self.isLooping = isLooping
        self.mediaTitle = url.deletingPathExtension().lastPathComponent
        self.previousItemAction = previousItemAction
        self.nextItemAction = nextItemAction
        self.nextGaplessItemProvider = nextGaplessItemProvider
        self.playbackIntentHandler = playbackIntentHandler
        _ = engine
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .shouldToggleVideoPlayback,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.userInfo?["id"] as? UUID == self.appStateID else { return }
                    self.togglePlayPause()
                }
            }
        )
        Self.liveControllers.add(self)
        load(url: url, range: range)
        startProgressTimer()
        Task { await refreshDeviceService() }
        startSystemDeviceObservation()
    }

    deinit {
        progressTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        // deinit 为非隔离上下文，不能调用 MainActor 方法；此处内联移除监听。
        if let exclusiveListener = exclusiveDeviceListener,
           exclusiveObservedDeviceID != kAudioObjectUnknown {
            var aliveAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                exclusiveObservedDeviceID,
                &aliveAddress,
                DispatchQueue.main,
                exclusiveListener
            )
            var rateAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                exclusiveObservedDeviceID,
                &rateAddress,
                DispatchQueue.main,
                exclusiveListener
            )
        }
        if let devicesListener = systemDevicesListener {
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                DispatchQueue.main,
                devicesListener
            )
        }
        if let defaultListener = systemDefaultListener {
            var defaultAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultAddress,
                DispatchQueue.main,
                defaultListener
            )
        }
        engineStorage?.stop()
        let clientID = activeLeaseClientID ?? deviceServiceClientID
        Task {
            _ = try? await ExtensionHost.shared.performAudioDeviceCommand(.init(
                command: .releasePCM,
                clientID: clientID
            ))
        }
    }

    func play() {
        playbackIntentHandler?(true)
        guard audioFile != nil, segmentFrames > 0 else { return }
        NSLog(
            "AudioPlaybackController play resumed=%d selected=%@ lease=%@ sr=%.0f",
            isPlaying, selectedOutputDeviceID ?? "-",
            activeLeaseClientID?.uuidString ?? "-", sampleRate
        )
        if ExtensionHost.shared.isAudioDeviceServiceAvailable {
            routeGeneration &+= 1
            let generation = routeGeneration
            Task { await preparePreferredRouteAndPlay(generation: generation) }
            return
        }
        startPlaybackNow()
    }

    private func startPlaybackNow() {
        MediaRemoteCommandCoordinator.shared.activate(self, title: mediaTitle)
        if duration > 0, currentTime >= duration - 0.05 {
            schedule(from: 0, play: true)
            return
        }
        // 系统默认路由下引擎仍钉在已释放的独占设备时，先重建为跟随系统默认；
        // 否则渲染继续送往旧设备，表现为进度走但无声。
        if activeLeaseClientID == nil, enginePinnedToExclusiveDevice {
            rebuildEngineForSystemDefault()
        }
        // 每次播放都按当前位置重排段，不依赖 load 时预排的队列；
        // 预排队列可能已被路由切换的 stop 清空，空队列 play 会表现为开始后进度不动。
        schedule(from: currentTime, play: true)
    }

    func pause() {
        playbackIntentHandler?(false)
        routeGeneration &+= 1
        stopOutput()
    }

    /// 暂停或自然播完时停排播，不改写用户的播放/暂停意图。
    /// 暂停完全释放独占租约：hog 归还系统，DAC 格式恢复原值（切换格式可能让设备
    /// 短暂重枚举，恢复播放时的重启/重钉/心跳逻辑会接住）。自然播完连播时保留租约，
    /// 同速率无需任何 HAL 操作。独占下连引擎一起停掉，恢复时重建 ioProc。
    func stopOutput(releaseLease: Bool = true) {
        refreshCurrentTime()
        // stop/reset 会触发旧段完成回调，必须先失效，避免暂停被误判为播完并自动切歌。
        scheduleGeneration &+= 1
        stallWatchdogGeneration &+= 1
        queuedSuccessor = nil
        playerNode.pause()
        isPlaying = false
        if releaseLease, enginePinnedToExclusiveDevice {
            // 仅 stop 仍保留绑定 DAC 的 AUHAL；先销毁旧引擎，再允许扩展改回设备格式。
            discardOutputEngine()
        } else if activeLeaseClientID != nil {
            engine.stop()
        }
        if releaseLease, let clientID = activeLeaseClientID {
            NSLog("AudioPlaybackController pause releasing lease")
            // 同步先清本地状态，并发再播走全新获取；尾链保证释放先于获取到达扩展侧。
            activeLeaseClientID = nil
            preparedDeviceID = nil
            preparedSourceSampleRate = nil
            stopExclusiveDeviceObservation()
            enqueuePCMRelease(clientID: clientID)
        }
        MediaRemoteCommandCoordinator.shared.update(self)
    }

    /// 已交出的租约必须完成释放，不依赖控制器存活或播放代次；新的获取等待同一尾链。
    @discardableResult
    func enqueuePCMRelease(
        clientID: UUID,
        release: @escaping @MainActor (UUID) async -> Void = { clientID in
            _ = try? await ExtensionHost.shared.performAudioDeviceCommand(.init(
                command: .releasePCM, clientID: clientID
            ))
        }
    ) -> Task<Void, Never> {
        let tail = deviceCommandTail
        let task = Task {
            await tail?.value
            await release(clientID)
        }
        deviceCommandTail = task
        return task
    }

    func closeOutput() {
        refreshCurrentTime()
        scheduleGeneration &+= 1
        queuedSuccessor = nil
        playerNode.stop()
        engineStorage?.stop()
        isPlaying = false
        if enginePinnedToExclusiveDevice { discardOutputEngine() }
        stopExclusiveDeviceObservation()
        preparedDeviceID = nil
        preparedSourceSampleRate = nil
        routeGeneration &+= 1
        let clientID = activeLeaseClientID ?? deviceServiceClientID
        activeLeaseClientID = nil
        let ownerID = deviceServiceClientID
        // 旧持有者记录只在释放成功后移除；失败时保留，供后续同设备获取重试。
        enqueuePCMRelease(clientID: clientID) { clientID in
            do {
                _ = try await ExtensionHost.shared.performAudioDeviceCommand(.init(
                    command: .releasePCM, clientID: clientID
                ))
                ExclusivePlaybackCoordinator.shared.release(ownerID: ownerID)
            } catch {
                NSLog("AudioPlaybackController close release failed: \(error.localizedDescription)")
            }
        }
    }

    func selectSystemDefaultOutput() {
        selectedOutputDeviceID = nil
        hasLoadedOutputPreference = true
        routeGeneration &+= 1
        let generation = routeGeneration
        Task { await applySystemDefaultRoute(generation: generation) }
    }

    func selectExclusiveOutput(deviceID: String) {
        routeGeneration &+= 1
        let generation = routeGeneration
        selectedOutputDeviceID = deviceID
        hasLoadedOutputPreference = true
        Task { await applyExclusiveRoute(deviceID: deviceID, generation: generation, resumesPlayback: isPlaying) }
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func toggleMute() {
        isMuted.toggle()
        applyVolume()
    }

    func setVolume(_ newValue: Float) {
        volume = max(0, min(1, newValue))
        if volume > 0, isMuted {
            isMuted = false
        }
        applyVolume()
    }

    var volumeIconName: String {
        if isMuted || volume <= 0 { return "speaker.slash.fill" }
        if volume < 1.0 / 3.0 { return "speaker.fill" }
        if volume < 2.0 / 3.0 { return "speaker.wave.1.fill" }
        if volume < 1.0 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    func seek(to time: Double) {
        let clamped = min(duration, max(0, time))
        currentTime = clamped
        schedule(from: clamped, play: isPlaying || playerNode.isPlaying)
        MediaRemoteCommandCoordinator.shared.update(self)
    }

    func adjustTime(by delta: Double) {
        guard duration > 0 else { return }
        seek(to: min(duration, max(0, currentTime + delta)))
    }

    func adjustVolume(by delta: Float) {
        setVolume(volume + delta)
    }

    func playPreviousItem() -> Bool {
        previousItemAction()
    }

    func playNextItem() -> Bool {
        nextItemAction()
    }

    func load(url: URL, range: MediaPlaybackRange? = nil, autoplay: Bool = false) {
        mediaTitle = url.deletingPathExtension().lastPathComponent
        let identity = PlaybackContentIdentity(url: url, range: range)
        // 无缝衔接已把下一曲排进节点：列表切项到来时不要停引擎，否则 DAC 采样率会闪、曲间会留缝。
        if loadedContentIdentity == identity, isPlaying || queuedSuccessor != nil {
            MediaRemoteCommandCoordinator.shared.activate(self, title: mediaTitle)
            return
        }
        scheduleGeneration &+= 1
        queuedSuccessor = nil
        playerNode.stop()
        isPlaying = false
        do {
            let access = PlaybackFileAccess(url: url)
            let file = try AVAudioFile(forReading: url)
            guard Self.isPlayable(format: file.processingFormat) else {
                NSLog("AudioPlaybackController rejected invalid format for \(url.path): \(file.processingFormat)")
                audioFile = nil
                currentFileURL = nil
                loadedContentIdentity = nil
                duration = 0
                currentTime = 0
                return
            }
            let nextRate = file.processingFormat.sampleRate > 0
                ? file.processingFormat.sampleRate
                : file.fileFormat.sampleRate
            let nextChannels = Int(file.processingFormat.channelCount)
            let formatChanged = abs(nextRate - sampleRate) > 0.5 || nextChannels != sourceChannelCount
            audioFile = file
            currentFileAccess = access
            currentFileURL = url
            loadedContentIdentity = identity
            sampleRate = nextRate
            sourceChannelCount = nextChannels
            // 切歌后仍要能复用独占租约：仅在采样率或声道变化时才作废。
            if formatChanged {
                preparedSourceSampleRate = nil
            }
            if formatChanged {
                engineStorage?.stop()
                if engineStorage != nil {
                    reconnect(format: file.processingFormat)
                }
            } else if let existing = engineStorage,
                      existing.outputConnectionPoints(for: playerNode, outputBus: 0).isEmpty {
                // attach 后 engine 非 nil，但可能还未连 mixer；首曲为默认 44.1kHz/双声道时
                // formatChanged 为 false，必须按实际连线判断，不能用节点是否已 attach 代替。
                reconnect(format: file.processingFormat)
            }

            let total = file.length
            let start = range.map { CueTime.sampleFrame(cueFrames: $0.startCueFrames, sampleRate: sampleRate) } ?? 0
            let end: Int64
            if let endFrames = range?.endCueFrames {
                end = CueTime.sampleFrame(cueFrames: endFrames, sampleRate: sampleRate)
            } else {
                end = total
            }
            startFrame = max(0, min(start, total))
            let last = max(startFrame, min(end, total))
            segmentFrames = AVAudioFrameCount(max(0, last - startFrame))
            duration = sampleRate > 0 ? Double(segmentFrames) / sampleRate : 0
            currentTime = 0
            NSLog(
                "AudioPlaybackController loaded %@ sr=%.0f ch=%d length=%lld start=%lld frames=%u",
                url.lastPathComponent, sampleRate, sourceChannelCount,
                file.length, startFrame, segmentFrames
            )
            MediaRemoteCommandCoordinator.shared.activate(self, title: mediaTitle)
            schedule(from: 0, play: false)
            if autoplay { play() }
        } catch {
            NSLog("AudioPlaybackController failed to open \(url.path): \(error.localizedDescription)")
            audioFile = nil
            duration = 0
            currentTime = 0
        }
    }

    private func reconnect(format: AVAudioFormat) {
        // AVAudioEngine 不支持运行中改图；历史恢复和 CUE 切轨前先完整停止并重置。
        playerNode.stop()
        engine.stop()
        engine.disconnectNodeOutput(playerNode)
        engine.reset()
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        applyVolume()
    }

    private func refreshDeviceService() async {
        guard ExtensionHost.shared.isAudioDeviceServiceAvailable else {
            deviceServiceSnapshot = nil
            return
        }
        do {
            var snapshot = try await ExtensionHost.shared.performAudioDeviceCommand(.init(
                command: .snapshot,
                clientID: activeLeaseClientID ?? deviceServiceClientID
            ))
            if !hasLoadedOutputPreference {
                selectedOutputDeviceID = snapshot.selectedPCMDeviceID
                hasLoadedOutputPreference = true
            }
            // 全局偏好只用于首次选择；其他箔改路由不改变本箔的系统默认/独占选择。
            if let uid = selectedOutputDeviceID,
               !snapshot.devices.contains(where: { $0.id == uid && $0.isConnected }) {
                selectedOutputDeviceID = nil
            }
            snapshot.selectedPCMDeviceID = selectedOutputDeviceID
            snapshot.pcmRouteMode = selectedOutputDeviceID == nil ? .systemDefault : .exclusiveDevice
            deviceServiceSnapshot = snapshot
            deviceFailureMessage = nil
        } catch {
            deviceServiceSnapshot = nil
            deviceFailureMessage = error.localizedDescription
        }
    }

    /// 监听系统设备插拔与默认设备切换；独占设备离线时立刻暂停并切回跟随系统默认。
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
            Task { @MainActor [weak self] in await self?.handleSystemDevicesChanged() }
        }
        let defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in await self?.handleSystemDevicesChanged() }
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

    private func handleSystemDevicesChanged() async {
        guard ExtensionHost.shared.isAudioDeviceServiceAvailable else { return }
        let previousMode = deviceServiceSnapshot?.pcmRouteMode
        let previousPrepared = preparedDeviceID
        let previousSelected = deviceServiceSnapshot?.selectedPCMDeviceID
        await refreshDeviceService()
        guard let snapshot = deviceServiceSnapshot else { return }
        // 服务端离线后已自动切回系统默认；宿主侧把仍指向旧设备的引擎重建为系统默认并暂停。
        let preparedGone = previousPrepared.flatMap { id in
            snapshot.devices.first(where: { $0.id == id && $0.isConnected })
        } == nil && previousPrepared != nil
        let selectedGone = previousSelected.flatMap { id in
            snapshot.devices.first(where: { $0.id == id })
        } == nil && previousSelected != nil
        let fellBackToDefault = previousMode == .exclusiveDevice && snapshot.pcmRouteMode == .systemDefault
        let exclusiveStillInvalid = snapshot.pcmRouteMode == .exclusiveDevice
            && snapshot.selectedPCMDeviceID.flatMap({ id in snapshot.devices.first(where: { $0.id == id }) }) == nil
        guard preparedGone || selectedGone || fellBackToDefault || exclusiveStillInvalid else { return }
        playbackIntentHandler?(false)
        routeGeneration &+= 1
        refreshCurrentTime()
        scheduleGeneration &+= 1
        playerNode.stop()
        engineStorage?.stop()
        isPlaying = false
        stopExclusiveDeviceObservation()
        preparedDeviceID = nil
        preparedSourceSampleRate = nil
        activeLeaseClientID = nil
        ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
        rebuildEngineForSystemDefault()
        schedule(from: currentTime, play: false)
        MediaRemoteCommandCoordinator.shared.update(self)
        // 刷新一次快照，确保右上角立刻显示跟随系统默认而非已不存在的设备。
        await refreshDeviceService()
    }

    private func preparePreferredRouteAndPlay(generation: UInt64) async {
        if deviceServiceSnapshot == nil { await refreshDeviceService() }
        guard generation == routeGeneration else { return }
        guard let deviceID = selectedOutputDeviceID else {
            startPlaybackNow()
            return
        }
        await applyExclusiveRoute(deviceID: deviceID, generation: generation, resumesPlayback: true)
    }

    private func applyExclusiveRoute(
        deviceID: String,
        generation: UInt64,
        resumesPlayback: Bool
    ) async {
        if !resumesPlayback {
            if isLeaseReusable(deviceID: deviceID) {
                // 同设备复选且租约仍在：只刷新展示，不碰 HAL 与排播。
                await refreshDeviceService()
                return
            }
            do {
                try await pauseForExclusiveHandoff()
            } catch {
                // 释放失败：保留 owner 记录阻止同设备新获取，并显示可本地化提示。
                deviceFailureMessage = error.localizedDescription
                return
            }
            ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
            await refreshDeviceService()
            return
        }
        // 租约复用与全新获取都走 prepareExclusiveRoute（内部按租约状态分支），
        // 仲裁统一走 coordinator，避免与别的箔抢设备。
        do {
            try await ExclusivePlaybackCoordinator.shared.perform(
                deviceID: deviceID, ownerID: deviceServiceClientID,
                pause: { [weak self] in try await self?.pauseForExclusiveHandoff() },
                isCurrent: { [weak self] in self?.routeGeneration == generation },
                start: { [weak self] in
                    guard let self, generation == self.routeGeneration else { throw CancellationError() }
                    try await self.prepareExclusiveRoute(deviceID: deviceID, generation: generation, resumesPlayback: resumesPlayback)
                    guard generation == self.routeGeneration else { throw CancellationError() }
                }
            )
        } catch is CancellationError {
            // 过期/取消不是释放失败，不提示。
        } catch {
            deviceFailureMessage = error.localizedDescription
        }
    }

    /// 暂停保留的租约可直接复用：同设备、同源采样率且租约未交出去。
    /// 离线/被抢走时会经 pauseForExclusiveHandoff 或设备变化路径清空 activeLease，不会误复用。
    private func isLeaseReusable(deviceID: String) -> Bool {
        activeLeaseClientID != nil
            && preparedDeviceID == deviceID
            && preparedSourceSampleRate == sampleRate
    }

    private func pauseForExclusiveHandoff() async throws {
        playbackIntentHandler?(false)
        routeGeneration &+= 1
        stopEngineForRouteChange()
        if enginePinnedToExclusiveDevice { discardOutputEngine() }
        stopExclusiveDeviceObservation()
        let clientID = activeLeaseClientID
        guard let clientID else {
            preparedDeviceID = nil
            preparedSourceSampleRate = nil
            MediaRemoteCommandCoordinator.shared.update(self)
            return
        }
        do {
            _ = try await ExtensionHost.shared.performAudioDeviceCommand(.init(command: .releasePCM, clientID: clientID))
            activeLeaseClientID = nil
            preparedDeviceID = nil
            preparedSourceSampleRate = nil
        } catch {
            // 释放失败：保留 activeLeaseClientID 作为待释放记录，交由协调器重试，不能静默清空。
            MediaRemoteCommandCoordinator.shared.update(self)
            throw error
        }
        MediaRemoteCommandCoordinator.shared.update(self)
    }

    private func prepareExclusiveRoute(deviceID: String, generation: UInt64, resumesPlayback: Bool) async throws {
        let shouldResume = resumesPlayback
        // 租约仍在（自然播完连播等）：沿用原 clientID，扩展侧直接复用，不碰 HAL；
        // 全新获取才停引擎、清旧租约。
        let reusingLease = isLeaseReusable(deviceID: deviceID)
        let leaseClientID = activeLeaseClientID ?? UUID()
        NSLog(
            "AudioPlaybackController prepare reuse=%d uid=%@",
            reusingLease, deviceID
        )
        if !reusingLease {
            stopEngineForRouteChange()
            discardOutputEngine()
            ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
            if let old = activeLeaseClientID {
                _ = try? await ExtensionHost.shared.performAudioDeviceCommand(.init(command: .releasePCM, clientID: old))
                activeLeaseClientID = nil
            }
        }
        guard generation == routeGeneration else { return }
        // 自己的格式设置会触发旧监听：先摘掉，成功后再挂新实例。
        stopExclusiveDeviceObservation()
        // 等待同控制器的释放先到达扩展侧，再获取，避免交错。
        await deviceCommandTail?.value
        guard generation == routeGeneration else { return }
        do {
            let snapshot = try await ExtensionHost.shared.performAudioDeviceCommand(.init(
                command: .prepareExclusivePCM,
                clientID: leaseClientID,
                selectedDeviceID: deviceID,
                sourceSampleRate: sampleRate,
                channelCount: sourceChannelCount
            ))
            guard generation == routeGeneration else {
                _ = try? await ExtensionHost.shared.performAudioDeviceCommand(.init(
                    command: .releasePCM,
                    clientID: leaseClientID
                ))
                ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
                return
            }
            // hog/格式切换会使已有 AUHAL 连接失效；必须在设备准备完成后新建引擎，
            // 不能复用暂停或切歌期间按旧设备状态创建的图。租约未变时才允许沿用。
            activeLeaseClientID = leaseClientID
            preparedDeviceID = deviceID
            preparedSourceSampleRate = sampleRate
            deviceServiceSnapshot = snapshot
            deviceFailureMessage = nil
            if !reusingLease || engineStorage == nil {
                try await startExclusiveEngine(deviceUID: deviceID, generation: generation, play: shouldResume)
            } else {
                schedule(from: currentTime, play: shouldResume)
            }
            if shouldResume, !isPlaying {
                throw engineStartError ?? NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError))
            }
            startExclusiveDeviceObservation(deviceUID: deviceID)
            NSLog(
                "AudioPlaybackController exclusive prepared uid=%@ resolved=%u pinned=%@ sr=%.0f ch=%d frames=%u",
                deviceID, (try? Self.resolveDeviceID(uid: deviceID)) ?? 0,
                String(describing: currentEngineDeviceID()),
                sampleRate, sourceChannelCount, segmentFrames
            )
            // 引擎启动时可能跟随系统默认漂走：回读钉住的设备，对不上就重钉一次。
            if shouldResume {
                ensurePinnedToExclusive(deviceID: deviceID, generation: generation)
                if !isPlaying {
                    throw engineStartError ?? NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError))
                }
            }
            if let refreshed = try? await ExtensionHost.shared.performAudioDeviceCommand(.init(
                command: .snapshot,
                clientID: leaseClientID
            )) {
                var local = refreshed
                local.selectedPCMDeviceID = selectedOutputDeviceID
                local.pcmRouteMode = selectedOutputDeviceID == nil ? .systemDefault : .exclusiveDevice
                deviceServiceSnapshot = local
            }
        } catch {
            // 启动失败也必须先拆除输出，再恢复格式/归还 hog，避免留下“暂停但仍独占”。
            if generation == routeGeneration {
                stopEngineForRouteChange()
                stopExclusiveDeviceObservation()
                activeLeaseClientID = nil
                discardOutputEngine()
            }
            await enqueuePCMRelease(clientID: leaseClientID).value
            guard generation == routeGeneration else { return }
            NSLog("AudioPlaybackController exclusive prepare failed: \(error.localizedDescription)")
            stopExclusiveDeviceObservation()
            activeLeaseClientID = nil
            preparedDeviceID = nil
            preparedSourceSampleRate = nil
            ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
            deviceFailureMessage = error.localizedDescription
            throw error
        }
    }

    private func applySystemDefaultRoute(generation: UInt64) async {
        let shouldResume = isPlaying
        ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
        stopExclusiveDeviceObservation()
        stopEngineForRouteChange()
        do {
            let snapshot = try await ExtensionHost.shared.performAudioDeviceCommand(.init(
                command: .selectSystemDefault,
                clientID: activeLeaseClientID ?? deviceServiceClientID
            ))
            guard generation == routeGeneration else { return }
            rebuildEngineForSystemDefault()
            activeLeaseClientID = nil
            ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
            deviceServiceSnapshot = snapshot
            deviceFailureMessage = nil
            schedule(from: currentTime, play: shouldResume)
        } catch {
            guard generation == routeGeneration else { return }
            ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
            deviceFailureMessage = error.localizedDescription
            rebuildEngineForSystemDefault()
            schedule(from: currentTime, play: shouldResume)
        }
    }

    private func stopEngineForRouteChange() {
        refreshCurrentTime()
        // stop() 可能触发旧 scheduleSegment 的完成回调；先使它失效，避免把切换误判为自然播完。
        scheduleGeneration &+= 1
        queuedSuccessor = nil
        playerNode.stop()
        engineStorage?.stop()
        isPlaying = false
    }

    /// 格式刚切完时 AUHAL 启动常返回忙；先不归还 hog，拆掉引擎等设备稳定后再建。
    private func startExclusiveEngine(deviceUID: String, generation: UInt64, play: Bool) async throws {
        var lastError: Error?
        for attempt in 0..<3 {
            guard generation == routeGeneration else { throw CancellationError() }
            tearDownOutputEngine()
            do {
                try routeEngine(to: deviceUID)
                schedule(from: currentTime, play: play)
                if !play || isPlaying { return }
                lastError = engineStartError ?? NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError))
            } catch {
                lastError = error
            }
            NSLog(
                "AudioPlaybackController exclusive engine start retry %d: %@",
                attempt + 1, lastError?.localizedDescription ?? "-"
            )
            tearDownOutputEngine()
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw lastError ?? NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError))
    }

    private func routeEngine(to deviceUID: String) throws {
        let deviceID = try Self.resolveDeviceID(uid: deviceUID)
        guard let audioUnit = engine.outputNode.audioUnit else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError))
        }
        var target = deviceID
        let result = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &target,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        enginePinnedToExclusiveDevice = true
        if let format = audioFile?.processingFormat { reconnect(format: format) }
    }

    /// 回读引擎实际绑定的输出设备；跟丢时返回 nil。
    private func currentEngineDeviceID() -> AudioDeviceID? {
        guard let audioUnit = engine.outputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let result = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard result == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// 启动后确认还在独占设备上；被系统默认漂移带走时重钉并重排，避免进度走但无声。
    private func ensurePinnedToExclusive(deviceID: String, generation: UInt64) {
        guard generation == routeGeneration,
              let expected = try? Self.resolveDeviceID(uid: deviceID) else { return }
        guard currentEngineDeviceID() != expected else { return }
        NSLog(
            "AudioPlaybackController engine drifted from %u, re-pinning",
            expected
        )
        engine.stop()
        do {
            try routeEngine(to: deviceID)
        } catch {
            NSLog("AudioPlaybackController re-pin failed: \(error.localizedDescription)")
            isPlaying = false
            return
        }
        guard generation == routeGeneration else { return }
        schedule(from: currentTime, play: true)
    }

    /// 格式/hog 切换期间不保留 AUHAL；下一次实际路由时才惰性创建引擎。
    private func discardOutputEngine() {
        tearDownOutputEngine()
        enginePinnedToExclusiveDevice = false
        preparedDeviceID = nil
        preparedSourceSampleRate = nil
    }

    private func tearDownOutputEngine() {
        playerNode.stop()
        engineStorage?.stop()
        if let audioUnit = engineStorage?.outputNode.audioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
        }
        engineStorage?.reset()
        engineStorage?.detach(playerNode)
        engineStorage = nil
        enginePinnedToExclusiveDevice = false
    }

    private func rebuildEngineForSystemDefault() {
        discardOutputEngine()
        if let format = audioFile?.processingFormat { reconnect(format: format) }
    }

    /// 监听独占设备的心跳与采样率：DAC 重枚举/外部改格式会杀死 ioProc，
    /// 此时只重建 ioProc，不碰 hog 与设备格式。
    private func startExclusiveDeviceObservation(deviceUID: String) {
        stopExclusiveDeviceObservation()
        guard let deviceID = try? Self.resolveDeviceID(uid: deviceUID) else { return }
        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in await self?.handleExclusiveDeviceChanged() }
        }
        guard AudioObjectAddPropertyListenerBlock(deviceID, &aliveAddress, DispatchQueue.main, listener) == noErr,
              AudioObjectAddPropertyListenerBlock(deviceID, &rateAddress, DispatchQueue.main, listener) == noErr else {
            NSLog("AudioPlaybackController cannot observe exclusive device")
            return
        }
        exclusiveDeviceListener = listener
        exclusiveObservedDeviceID = deviceID
    }

    private func stopExclusiveDeviceObservation() {
        exclusiveIORefreshGeneration &+= 1
        guard let listener = exclusiveDeviceListener,
              exclusiveObservedDeviceID != kAudioObjectUnknown else {
            exclusiveDeviceListener = nil
            return
        }
        let deviceID = exclusiveObservedDeviceID
        exclusiveDeviceListener = nil
        exclusiveObservedDeviceID = AudioDeviceID(kAudioObjectUnknown)
        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(deviceID, &aliveAddress, DispatchQueue.main, listener)
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(deviceID, &rateAddress, DispatchQueue.main, listener)
    }

    /// 设备抖动后防抖重建 ioProc；暂停态只更新观察的实例，不重排。
    private func handleExclusiveDeviceChanged() async {
        exclusiveIORefreshGeneration &+= 1
        let generation = exclusiveIORefreshGeneration
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard generation == exclusiveIORefreshGeneration,
              let uid = preparedDeviceID,
              activeLeaseClientID != nil else { return }
        // 重枚举可能换实例：跟到新实例上；设备消失则摘掉监听，等显式播放时如实报错。
        guard let currentID = try? Self.resolveDeviceID(uid: uid) else {
            stopExclusiveDeviceObservation()
            return
        }
        if currentID != exclusiveObservedDeviceID {
            startExclusiveDeviceObservation(deviceUID: uid)
            // 实例换了：重钉到新实例再重建 ioProc。
            try? routeEngine(to: uid)
        }
        let wasPlaying = isPlaying
        guard wasPlaying else { return }
        NSLog("AudioPlaybackController exclusive device disturbed, rebuilding ioProc")
        refreshCurrentTime()
        // 旧段完成回调失效，避免误判自然播完。
        scheduleGeneration &+= 1
        playerNode.stop()
        engine.stop()
        schedule(from: currentTime, play: true)
    }

    private static func resolveDeviceID(uid: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidValue: CFString = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        let result = withUnsafeMutablePointer(to: &uidValue) { uidPointer in
            withUnsafeMutablePointer(to: &deviceID) { devicePointer in
                var translation = AudioValueTranslation(
                    mInputData: uidPointer,
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: devicePointer,
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &size,
                    &translation
                )
            }
        }
        guard result == noErr, deviceID != kAudioObjectUnknown else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
        return deviceID
    }

    private func schedule(from displayTime: Double, play: Bool, watchdogAttempt: Int = 0) {
        guard let file = audioFile, segmentFrames > 0, sampleRate > 0 else { return }
        scheduleGeneration &+= 1
        queuedSuccessor = nil
        let generation = scheduleGeneration
        let offset = AVAudioFramePosition((max(0, displayTime) * sampleRate).rounded())
        let localStart = min(max(0, offset), AVAudioFramePosition(segmentFrames))
        let remaining = AVAudioFrameCount(max(0, AVAudioFramePosition(segmentFrames) - localStart))
        playerNode.stop()
        playerTimeOrigin = 0
        scheduledRemainingFrames = remaining
        scheduledDisplayStart = Double(localStart) / sampleRate
        currentTime = scheduledDisplayStart
        guard remaining > 0 else {
            handleSegmentEnd()
            return
        }
        enqueueSegment(file, startingFrame: startFrame + localStart, frameCount: remaining, generation: generation)
        if play {
            if !ensureEngineRunning(), activeLeaseClientID == nil {
                // 引擎启动偶发失败（如独占交接后设备忙）：系统默认路由下重建一次再试，
                // 独占路由的重建由 prepareExclusiveRoute 的失败路径负责，这里不碰钉住的设备。
                rebuildEngineForSystemDefault()
                guard ensureEngineRunning() else {
                    isPlaying = false
                    return
                }
            } else if !engine.isRunning {
                isPlaying = false
                return
            }
            playerNode.play()
            isPlaying = true
            MediaRemoteCommandCoordinator.shared.update(self)
            armStallWatchdog(attempt: watchdogAttempt)
            enqueueGaplessSuccessor(generation: generation)
        }
    }

    private func enqueueSegment(
        _ file: AVAudioFile,
        startingFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        generation: UInt64
    ) {
        playerNode.scheduleSegment(
            file,
            startingFrame: startingFrame,
            frameCount: frameCount,
            at: nil,
            // consumed 可能在实际出声前触发，不能用来推进列表或停止尾曲。
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.scheduleGeneration == generation else { return }
                self.handleSegmentEnd()
            }
        }
    }

    /// 当前段还在播时就把下一首排进同一节点；同格式则引擎与 DAC 都不动。
    private func enqueueGaplessSuccessor(generation: UInt64) {
        guard generation == scheduleGeneration, !isLooping, queuedSuccessor == nil else { return }
        guard let next = nextGaplessItemProvider(),
              let prepared = prepareSuccessor(url: next.0, range: next.1),
              canContinue(with: prepared) else { return }
        let origin = playerTimeOrigin + Double(scheduledRemainingFrames) / sampleRate
        enqueueSegment(
            prepared.file,
            startingFrame: prepared.startFrame,
            frameCount: prepared.segmentFrames,
            generation: generation
        )
        queuedSuccessor = QueuedSuccessor(
            file: prepared.file,
            access: prepared.access,
            url: prepared.url,
            identity: prepared.identity,
            startFrame: prepared.startFrame,
            segmentFrames: prepared.segmentFrames,
            sampleRate: prepared.sampleRate,
            channelCount: prepared.channelCount,
            playerTimeOrigin: origin
        )
        NSLog(
            "AudioPlaybackController queued gapless successor %@ frames=%u",
            prepared.url.lastPathComponent, prepared.segmentFrames
        )
    }

    private func prepareSuccessor(url: URL, range: MediaPlaybackRange?) -> PreparedSuccessor? {
        let identity = PlaybackContentIdentity(url: url, range: range)
        // 下一文件尚未成为当前列表项，预排时自行持有书签 URL 的访问权。
        let access = PlaybackFileAccess(url: url)
        let file: AVAudioFile
        if let current = audioFile, currentFileURL?.standardizedFileURL.path == url.standardizedFileURL.path {
            file = current
        } else {
            guard let opened = try? AVAudioFile(forReading: url),
                  Self.isPlayable(format: opened.processingFormat) else { return nil }
            file = opened
        }
        let rate = file.processingFormat.sampleRate > 0
            ? file.processingFormat.sampleRate
            : file.fileFormat.sampleRate
        guard rate > 0 else { return nil }
        let total = file.length
        let start = range.map { CueTime.sampleFrame(cueFrames: $0.startCueFrames, sampleRate: rate) } ?? 0
        let end: Int64
        if let endFrames = range?.endCueFrames {
            end = CueTime.sampleFrame(cueFrames: endFrames, sampleRate: rate)
        } else {
            end = total
        }
        let startFrame = max(0, min(start, total))
        let last = max(startFrame, min(end, total))
        let frames = AVAudioFrameCount(max(0, last - startFrame))
        guard frames > 0 else { return nil }
        return PreparedSuccessor(
            file: file,
            access: access,
            url: url,
            identity: identity,
            startFrame: startFrame,
            segmentFrames: frames,
            sampleRate: rate,
            channelCount: Int(file.processingFormat.channelCount)
        )
    }

    private func canContinue(with successor: PreparedSuccessor) -> Bool {
        abs(successor.sampleRate - sampleRate) < 0.5 && successor.channelCount == sourceChannelCount
    }

    private func adoptQueuedSuccessor(_ successor: QueuedSuccessor) {
        adoptPreparedSuccessor(
            PreparedSuccessor(
                file: successor.file,
                access: successor.access,
                url: successor.url,
                identity: successor.identity,
                startFrame: successor.startFrame,
                segmentFrames: successor.segmentFrames,
                sampleRate: successor.sampleRate,
                channelCount: successor.channelCount
            ),
            playerTimeOrigin: successor.playerTimeOrigin
        )
    }

    private func adoptPreparedSuccessor(_ successor: PreparedSuccessor, playerTimeOrigin: Double) {
        audioFile = successor.file
        currentFileAccess = successor.access
        currentFileURL = successor.url
        loadedContentIdentity = successor.identity
        startFrame = successor.startFrame
        segmentFrames = successor.segmentFrames
        sampleRate = successor.sampleRate
        sourceChannelCount = successor.channelCount
        scheduledRemainingFrames = successor.segmentFrames
        self.playerTimeOrigin = playerTimeOrigin
        scheduledDisplayStart = 0
        currentTime = 0
        duration = sampleRate > 0 ? Double(segmentFrames) / sampleRate : 0
        mediaTitle = successor.url.deletingPathExtension().lastPathComponent
        stallWatchdogGeneration &+= 1
        MediaRemoteCommandCoordinator.shared.activate(self, title: mediaTitle)
    }

    /// 播放后 1 秒仍无进度则判定卡住，重排一次；超过一次仍卡住就停下，避免无限重启引擎。
    private func armStallWatchdog(attempt: Int) {
        stallWatchdogGeneration &+= 1
        let generation = stallWatchdogGeneration
        let scheduled = scheduleGeneration
        let startTime = currentTime
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.handleStallCheck(generation: generation, scheduled: scheduled, startTime: startTime, attempt: attempt)
        }
    }

    private func handleStallCheck(generation: UInt64, scheduled: UInt64, startTime: Double, attempt: Int) {
        guard generation == stallWatchdogGeneration,
              scheduled == scheduleGeneration,
              isPlaying, duration > 0,
              currentTime < duration - 0.05 else { return }
        refreshCurrentTime()
        guard currentTime < duration - 0.05, currentTime - startTime < 0.25 else { return }
        if attempt >= 1 {
            // 重试后依然无渲染：如实停下，不再假装播放。
            NSLog("AudioPlaybackController stalled twice, giving up")
            stopOutput()
            return
        }
        NSLog("AudioPlaybackController detected stalled playback, retrying")
        if activeLeaseClientID == nil {
            rebuildEngineForSystemDefault()
        }
        schedule(from: currentTime, play: true, watchdogAttempt: attempt + 1)
    }

    private func handleSegmentEnd() {
        if isLooping {
            schedule(from: 0, play: true)
            return
        }
        let generation = scheduleGeneration
        if let successor = queuedSuccessor {
            queuedSuccessor = nil
            adoptQueuedSuccessor(successor)
            notifyPlaybackFinished()
            enqueueGaplessSuccessor(generation: generation)
            return
        }
        // 预排失败时仍保持引擎运转，避免同速率切歌让 DAC 掉锁闪采样率。
        if let next = nextGaplessItemProvider(),
           let prepared = prepareSuccessor(url: next.0, range: next.1),
           canContinue(with: prepared) {
            adoptPreparedSuccessor(prepared, playerTimeOrigin: playerTimeOrigin + Double(scheduledRemainingFrames) / sampleRate)
            enqueueSegment(
                prepared.file,
                startingFrame: prepared.startFrame,
                frameCount: prepared.segmentFrames,
                generation: generation
            )
            if ensureEngineRunning() {
                playerNode.play()
                isPlaying = true
            }
            notifyPlaybackFinished()
            enqueueGaplessSuccessor(generation: generation)
            return
        }
        // 自然播完保留租约：自动切歌同速率可零 HAL 操作直接续播。
        stopOutput(releaseLease: false)
        currentTime = duration
        notifyPlaybackFinished()
    }

    private func notifyPlaybackFinished() {
        NotificationCenter.default.post(
            name: .mediaPlaybackDidFinish,
            object: nil,
            userInfo: ["id": appStateID]
        )
    }

    @discardableResult
    private func ensureEngineRunning() -> Bool {
        engineStartError = nil
        guard !engine.isRunning else { return true }
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        guard Self.isPlayable(format: outputFormat) else {
            NSLog("AudioPlaybackController cannot start with invalid output format: \(outputFormat)")
            return false
        }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            engineStartError = error
            NSLog("AudioPlaybackController engine start failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func isPlayable(format: AVAudioFormat) -> Bool {
        format.sampleRate.isFinite
            && format.sampleRate > 0
            && format.channelCount > 0
    }

    private func applyVolume() {
        playerNode.volume = isMuted ? 0 : volume
    }

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshCurrentTime()
            }
        }
    }

    private func refreshCurrentTime() {
        guard isPlaying, sampleRate > 0 else { return }
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return }
        let elapsed = Double(playerTime.sampleTime) / sampleRate - playerTimeOrigin
        currentTime = min(duration, max(0, scheduledDisplayStart + elapsed))
    }
}

private struct PlaybackContentIdentity: Equatable {
    let path: String
    let startCueFrames: Int64
    let endCueFrames: Int64?

    init(url: URL, range: MediaPlaybackRange?) {
        path = url.standardizedFileURL.path
        startCueFrames = range?.startCueFrames ?? 0
        endCueFrames = range?.endCueFrames
    }
}

/// 访问权与预排文件共同存活；取消预排、替换文件或控制器销毁时配对释放。
private final class PlaybackFileAccess {
    private let url: URL
    private let accessed: Bool

    init(url: URL) {
        self.url = url
        accessed = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if accessed { url.stopAccessingSecurityScopedResource() }
    }
}

private struct PreparedSuccessor {
    let file: AVAudioFile
    let access: PlaybackFileAccess
    let url: URL
    let identity: PlaybackContentIdentity
    let startFrame: AVAudioFramePosition
    let segmentFrames: AVAudioFrameCount
    let sampleRate: Double
    let channelCount: Int
}

private struct QueuedSuccessor {
    let file: AVAudioFile
    let access: PlaybackFileAccess
    let url: URL
    let identity: PlaybackContentIdentity
    let startFrame: AVAudioFramePosition
    let segmentFrames: AVAudioFrameCount
    let sampleRate: Double
    let channelCount: Int
    let playerTimeOrigin: Double
}

/// 交接按设备串行，先等待旧输出暂停和释放，再启动新输出；系统默认输出不登记。
/// 释放失败时保留旧持有者记录并阻止同设备新获取，最多重试一次，避免静默进入冲突的新独占会话。
@MainActor
final class ExclusivePlaybackCoordinator {
    static let shared = ExclusivePlaybackCoordinator()

    enum HandoffError: LocalizedError, Equatable {
        case releaseFailed(deviceID: String)

        var errorDescription: String? {
            switch self {
            case .releaseFailed:
                NSLocalizedString(
                    "Exclusive Output Release Failed Message",
                    comment: "Previous exclusive audio output could not release the device"
                )
            }
        }
    }

    private struct Owner {
        let id: UUID
        let pause: @MainActor () async throws -> Void
    }
    private var owners: [String: Owner] = [:]
    private var tails: [String: Task<Void, Error>] = [:]

    func perform(
        deviceID: String,
        ownerID: UUID,
        pause: @escaping @MainActor () async throws -> Void,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        start: @escaping @MainActor () async throws -> Void
    ) async throws {
        let preceding = tails[deviceID]
        let task = Task { @MainActor in
            // 前序失败只表示该设备仍需仲裁；失败时旧 owner 会被保留，下面会再次尝试释放，不能直接绕过。
            _ = try? await preceding?.value
            guard isCurrent() else { throw CancellationError() }
            try await self.releasePreviousOwnerIfNeeded(deviceID: deviceID, ownerID: ownerID)
            guard isCurrent() else { throw CancellationError() }
            try await start()
            self.owners[deviceID] = Owner(id: ownerID, pause: pause)
        }
        tails[deviceID] = task
        try await task.value
    }

    /// 只在旧持有者确认释放后移除记录；失败保留记录并抛出，最多重试一次。
    private func releasePreviousOwnerIfNeeded(deviceID: String, ownerID: UUID) async throws {
        guard let old = owners[deviceID], old.id != ownerID else { return }
        do {
            try await old.pause()
        } catch {
            do {
                try await old.pause()
            } catch {
                throw HandoffError.releaseFailed(deviceID: deviceID)
            }
        }
        owners.removeValue(forKey: deviceID)
    }

    func release(ownerID: UUID) {
        for uid in owners.keys.filter({ owners[$0]?.id == ownerID }) { owners.removeValue(forKey: uid) }
    }

    /// 诊断/测试：该设备是否仍被其他持有者占用（等价于存在未释放记录）。
    func hasOwner(deviceID: String, otherThan ownerID: UUID? = nil) -> Bool {
        guard let owner = owners[deviceID] else { return false }
        return owner.id != ownerID
    }
}
