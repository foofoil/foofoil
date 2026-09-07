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
    private var engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let deviceServiceClientID = UUID()
    private var activeLeaseClientID: UUID?
    private var selectedOutputDeviceID: String?
    private var hasLoadedOutputPreference = false
    private var audioFile: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var segmentFrames: AVAudioFrameCount = 0
    private var sampleRate: Double = 44100
    private var sourceChannelCount = 2
    private var preparedDeviceID: String?
    private var preparedSourceSampleRate: Double?
    private var routeGeneration: UInt64 = 0
    private var scheduledDisplayStart: Double = 0
    private var scheduleGeneration: UInt64 = 0
    private var progressTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var systemDevicesListener: AudioObjectPropertyListenerBlock?
    private var systemDefaultListener: AudioObjectPropertyListenerBlock?
    private var mediaTitle: String
    private let previousItemAction: @MainActor () -> Bool
    private let nextItemAction: @MainActor () -> Bool
    private let playbackIntentHandler: (@MainActor (Bool) -> Void)?

    init(
        appStateID: UUID,
        url: URL,
        isLooping: Bool,
        range: MediaPlaybackRange? = nil,
        previousItemAction: @escaping @MainActor () -> Bool = { false },
        nextItemAction: @escaping @MainActor () -> Bool = { false },
        playbackIntentHandler: (@MainActor (Bool) -> Void)? = nil
    ) {
        self.appStateID = appStateID
        self.isLooping = isLooping
        self.mediaTitle = url.deletingPathExtension().lastPathComponent
        self.previousItemAction = previousItemAction
        self.nextItemAction = nextItemAction
        self.playbackIntentHandler = playbackIntentHandler
        engine.attach(playerNode)
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
        load(url: url, range: range)
        startProgressTimer()
        Task { await refreshDeviceService() }
        startSystemDeviceObservation()
    }

    deinit {
        progressTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        // deinit 为非隔离上下文，不能调用 MainActor 方法；此处内联移除监听。
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
        engine.stop()
        let clientID = activeLeaseClientID ?? deviceServiceClientID
        Task {
            _ = try? await ExtensionHost.shared.performHiFiDeviceCommand(.init(
                command: .releasePCM,
                clientID: clientID
            ))
        }
    }

    func play() {
        playbackIntentHandler?(true)
        guard audioFile != nil, segmentFrames > 0 else { return }
        if ExtensionHost.shared.isHiFiDeviceServiceAvailable {
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
        if !playerNode.isPlaying {
            if currentTime > 0 {
                schedule(from: currentTime, play: true)
            } else {
                guard ensureEngineRunning() else { return }
                playerNode.play()
                isPlaying = true
                MediaRemoteCommandCoordinator.shared.update(self)
            }
        }
    }

    func pause() {
        playbackIntentHandler?(false)
        routeGeneration &+= 1
        stopOutput()
    }

    /// 视图卸载或自然播完时停输出，不改写用户的播放/暂停意图。
    func stopOutput() {
        refreshCurrentTime()
        playerNode.pause()
        isPlaying = false
        if let clientID = activeLeaseClientID {
            engine.stop()
            activeLeaseClientID = nil
            preparedDeviceID = nil
            preparedSourceSampleRate = nil
            ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
            Task {
                _ = try? await ExtensionHost.shared.performHiFiDeviceCommand(.init(command: .releasePCM, clientID: clientID))
            }
        }
        MediaRemoteCommandCoordinator.shared.update(self)
    }

    func closeOutput() {
        refreshCurrentTime()
        scheduleGeneration &+= 1
        playerNode.stop()
        engine.stop()
        isPlaying = false
        preparedDeviceID = nil
        preparedSourceSampleRate = nil
        routeGeneration &+= 1
        let clientID = activeLeaseClientID ?? deviceServiceClientID
        activeLeaseClientID = nil
        ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
        Task {
            _ = try? await ExtensionHost.shared.performHiFiDeviceCommand(.init(
                command: .releasePCM,
                clientID: clientID
            ))
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
        scheduleGeneration &+= 1
        playerNode.stop()
        engine.stop()
        isPlaying = false
        do {
            let file = try AVAudioFile(forReading: url)
            guard Self.isPlayable(format: file.processingFormat) else {
                NSLog("AudioPlaybackController rejected invalid format for \(url.path): \(file.processingFormat)")
                audioFile = nil
                duration = 0
                currentTime = 0
                return
            }
            audioFile = file
            sampleRate = file.processingFormat.sampleRate > 0
                ? file.processingFormat.sampleRate
                : file.fileFormat.sampleRate
            sourceChannelCount = Int(file.processingFormat.channelCount)
            preparedSourceSampleRate = nil
            reconnect(format: file.processingFormat)

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
        guard ExtensionHost.shared.isHiFiDeviceServiceAvailable else {
            deviceServiceSnapshot = nil
            return
        }
        do {
            var snapshot = try await ExtensionHost.shared.performHiFiDeviceCommand(.init(
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
        guard ExtensionHost.shared.isHiFiDeviceServiceAvailable else { return }
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
        engine.stop()
        isPlaying = false
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
            await pauseForExclusiveHandoff()
            ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
            await refreshDeviceService()
            return
        }
        do {
            try await ExclusivePlaybackCoordinator.shared.perform(
                deviceID: deviceID, ownerID: deviceServiceClientID,
                pause: { [weak self] in await self?.pauseForExclusiveHandoff() },
                isCurrent: { [weak self] in self?.routeGeneration == generation },
                start: { [weak self] in
                    guard let self, generation == self.routeGeneration else { throw CancellationError() }
                    try await self.prepareExclusiveRoute(deviceID: deviceID, generation: generation, resumesPlayback: resumesPlayback)
                    guard generation == self.routeGeneration else { throw CancellationError() }
                }
            )
        } catch { }
    }

    private func pauseForExclusiveHandoff() async {
        playbackIntentHandler?(false)
        routeGeneration &+= 1
        stopEngineForRouteChange()
        let clientID = activeLeaseClientID
        activeLeaseClientID = nil
        preparedDeviceID = nil
        preparedSourceSampleRate = nil
        if let clientID {
            _ = try? await ExtensionHost.shared.performHiFiDeviceCommand(.init(command: .releasePCM, clientID: clientID))
        }
        MediaRemoteCommandCoordinator.shared.update(self)
    }

    private func prepareExclusiveRoute(deviceID: String, generation: UInt64, resumesPlayback: Bool) async throws {
        let shouldResume = resumesPlayback
        let leaseClientID = UUID()
        stopEngineForRouteChange()
        ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
        if let old = activeLeaseClientID {
            _ = try? await ExtensionHost.shared.performHiFiDeviceCommand(.init(command: .releasePCM, clientID: old))
            activeLeaseClientID = nil
        }
        guard generation == routeGeneration else { return }
        do {
            let snapshot = try await ExtensionHost.shared.performHiFiDeviceCommand(.init(
                command: .prepareExclusivePCM,
                clientID: leaseClientID,
                selectedDeviceID: deviceID,
                sourceSampleRate: sampleRate,
                channelCount: sourceChannelCount
            ))
            guard generation == routeGeneration else {
                _ = try? await ExtensionHost.shared.performHiFiDeviceCommand(.init(
                    command: .releasePCM,
                    clientID: leaseClientID
                ))
                ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
                return
            }
            try routeEngine(to: deviceID)
            activeLeaseClientID = leaseClientID
            preparedDeviceID = deviceID
            preparedSourceSampleRate = sampleRate
            deviceServiceSnapshot = snapshot
            deviceFailureMessage = nil
            schedule(from: currentTime, play: shouldResume)
            if let refreshed = try? await ExtensionHost.shared.performHiFiDeviceCommand(.init(
                command: .snapshot,
                clientID: leaseClientID
            )) {
                var local = refreshed
                local.selectedPCMDeviceID = selectedOutputDeviceID
                local.pcmRouteMode = selectedOutputDeviceID == nil ? .systemDefault : .exclusiveDevice
                deviceServiceSnapshot = local
            }
        } catch {
            _ = try? await ExtensionHost.shared.performHiFiDeviceCommand(.init(
                command: .releasePCM,
                clientID: leaseClientID
            ))
            guard generation == routeGeneration else { return }
            activeLeaseClientID = nil
            preparedDeviceID = nil
            preparedSourceSampleRate = nil
            ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
            deviceFailureMessage = error.localizedDescription
            rebuildEngineForSystemDefault()
            schedule(from: currentTime, play: false)
            throw error
        }
    }

    private func applySystemDefaultRoute(generation: UInt64) async {
        let shouldResume = isPlaying
        ExclusivePlaybackCoordinator.shared.release(ownerID: deviceServiceClientID)
        stopEngineForRouteChange()
        do {
            let snapshot = try await ExtensionHost.shared.performHiFiDeviceCommand(.init(
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
        playerNode.stop()
        engine.stop()
        isPlaying = false
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
        if let format = audioFile?.processingFormat { reconnect(format: format) }
    }

    private func rebuildEngineForSystemDefault() {
        playerNode.stop()
        engine.stop()
        engine.detach(playerNode)
        engine = AVAudioEngine()
        engine.attach(playerNode)
        preparedDeviceID = nil
        preparedSourceSampleRate = nil
        if let format = audioFile?.processingFormat { reconnect(format: format) }
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

    private func schedule(from displayTime: Double, play: Bool) {
        guard let file = audioFile, segmentFrames > 0, sampleRate > 0 else { return }
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        let offset = AVAudioFramePosition((max(0, displayTime) * sampleRate).rounded())
        let localStart = min(max(0, offset), AVAudioFramePosition(segmentFrames))
        let remaining = AVAudioFrameCount(max(0, AVAudioFramePosition(segmentFrames) - localStart))
        playerNode.stop()
        scheduledDisplayStart = Double(localStart) / sampleRate
        currentTime = scheduledDisplayStart
        guard remaining > 0 else {
            handleSegmentEnd()
            return
        }
        playerNode.scheduleSegment(
            file,
            startingFrame: startFrame + localStart,
            frameCount: remaining,
            at: nil
        ) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.scheduleGeneration == generation else { return }
                self.handleSegmentEnd()
            }
        }
        if play {
            guard ensureEngineRunning() else {
                isPlaying = false
                return
            }
            playerNode.play()
            isPlaying = true
            MediaRemoteCommandCoordinator.shared.update(self)
        }
    }

    private func handleSegmentEnd() {
        if isLooping {
            schedule(from: 0, play: true)
            return
        }
        stopOutput()
        currentTime = duration
        NotificationCenter.default.post(
            name: .mediaPlaybackDidFinish,
            object: nil,
            userInfo: ["id": appStateID]
        )
    }

    @discardableResult
    private func ensureEngineRunning() -> Bool {
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
        let elapsed = Double(playerTime.sampleTime) / sampleRate
        currentTime = min(duration, max(0, scheduledDisplayStart + elapsed))
    }
}

/// 交接按设备串行，先等待旧输出暂停和释放，再启动新输出；系统默认输出不登记。
@MainActor
final class ExclusivePlaybackCoordinator {
    static let shared = ExclusivePlaybackCoordinator()
    private struct Owner {
        let id: UUID
        let pause: @MainActor () async -> Void
    }
    private var owners: [String: Owner] = [:]
    private var tails: [String: Task<Void, Error>] = [:]

    func perform(
        deviceID: String,
        ownerID: UUID,
        pause: @escaping @MainActor () async -> Void,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        start: @escaping @MainActor () async throws -> Void
    ) async throws {
        let preceding = tails[deviceID]
        let task = Task { @MainActor in
            _ = try? await preceding?.value
            guard isCurrent() else { throw CancellationError() }
            if let old = self.owners[deviceID], old.id != ownerID {
                self.owners.removeValue(forKey: deviceID)
                await old.pause()
            }
            try await start()
            self.release(ownerID: ownerID)
            self.owners[deviceID] = Owner(id: ownerID, pause: pause)
        }
        tails[deviceID] = task
        try await task.value
    }

    func release(ownerID: UUID) {
        for uid in owners.keys.filter({ owners[$0]?.id == ownerID }) { owners.removeValue(forKey: uid) }
    }
}
