import Combine
import CoreAudio
import Foundation

/// MusicKit 跟随系统输出；这里修改系统设备属性，不接管其播放引擎或独占设备。
@MainActor
final class SystemAudioOutputController: ObservableObject {
    struct Device: Identifiable {
        let id: String
        let objectID: AudioDeviceID
        let name: String
        let sampleRate: Double?
        let rates: [Double]
        let isAvailable: Bool
        let canSetRate: Bool
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var canSelectDevice = false
    @Published private(set) var error: String?
    var selectedDevice: Device? { devices.first { $0.id == selectedID } }

    private struct Observation {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let listener: AudioObjectPropertyListenerBlock
    }
    private var observations: [Observation] = []
    private var observing = false

    func start() {
        guard !observing else { return }
        observing = true
        refresh()
    }

    func stop() {
        observing = false
        removeObservers()
    }

    func selectDevice(id: String) {
        refresh()
        guard canSelectDevice, let device = devices.first(where: { $0.id == id }), device.isAvailable else {
            fail(); return
        }
        write(device.objectID, to: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    func selectSampleRate(_ rate: Double, deviceID: String) {
        refresh()
        // 菜单打开期间设备可能被拔出、换成其他默认设备或被独占；写入前重新核验。
        guard let device = selectedDevice, device.id == deviceID, device.canSetRate,
              device.rates.contains(where: { abs($0 - rate) < 0.5 }) else {
            fail(); return
        }
        write(rate, to: device.objectID, selector: kAudioDevicePropertyNominalSampleRate)
    }

    private func fail() {
        error = NSLocalizedString("Audio Output Change Unavailable", comment: "")
    }

    private func write<T>(_ value: T, to object: AudioObjectID, selector: AudioObjectPropertySelector) {
        var value = value
        var address = Self.address(selector)
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), pointer)
        }
        error = status == noErr ? nil : String(format: NSLocalizedString("Audio Output Change Failed Format", comment: ""), status)
        // 只显示实际读回的属性，异步切换完成后由 HAL 通知刷新。
        refresh()
    }

    private func refresh() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let selected = Self.read(kAudioHardwarePropertyDefaultOutputDevice, object: system, initial: AudioDeviceID(kAudioObjectUnknown))
        canSelectDevice = Self.isSettable(kAudioHardwarePropertyDefaultOutputDevice, object: system)
        devices = Self.array(kAudioHardwarePropertyDevices, object: system, initial: AudioDeviceID(0)).compactMap { object in
            guard !Self.array(kAudioDevicePropertyStreams, object: object, scope: kAudioDevicePropertyScopeOutput, initial: AudioStreamID(0)).isEmpty,
                  let uid = Self.string(kAudioDevicePropertyDeviceUID, object: object),
                  let name = Self.string(kAudioObjectPropertyName, object: object) else { return nil }
            let rate = Self.read(kAudioDevicePropertyNominalSampleRate, object: object, initial: Double(0))
            let alive = Self.read(kAudioDevicePropertyDeviceIsAlive, object: object, initial: UInt32(0)) == 1
            let hog = Self.read(kAudioDevicePropertyHogMode, object: object, initial: pid_t(-1)) ?? -1
            let available = alive && hog == -1
            let ranges = Self.array(kAudioDevicePropertyAvailableNominalSampleRates, object: object, initial: AudioValueRange())
            return Device(id: uid, objectID: object, name: name, sampleRate: rate,
                          rates: Self.sampleRateOptions(ranges: ranges, current: rate), isAvailable: available,
                          canSetRate: available && Self.isSettable(kAudioDevicePropertyNominalSampleRate, object: object))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selectedID = devices.first { $0.objectID == selected }?.id
        if observing {
            removeObservers()
            observe(system, selector: kAudioHardwarePropertyDevices)
            observe(system, selector: kAudioHardwarePropertyDefaultOutputDevice)
            // 观察所有输出设备，让已打开的菜单之外的下一次设备列表也及时反映独占状态。
            for device in devices {
                for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyAvailableNominalSampleRates,
                                 kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyHogMode] {
                    observe(device.objectID, selector: selector)
                }
            }
        }
    }

    nonisolated static func sampleRateOptions(ranges: [AudioValueRange], current: Double?) -> [Double] {
        let common: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000,
                                88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000]
        let candidates = common + ranges.flatMap { [$0.mMinimum, $0.mMaximum] } + (current.map { [$0] } ?? [])
        return Array(Set(candidates.filter { rate in
            rate.isFinite && rate > 0 && ranges.contains { $0.mMinimum <= rate && rate <= $0.mMaximum }
        })).sorted()
    }

    private func observe(_ object: AudioObjectID, selector: AudioObjectPropertySelector) {
        var address = Self.address(selector)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.observing else { return }
                self.refresh()
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, listener) == noErr {
            observations.append(Observation(object: object, address: address, listener: listener))
        }
    }

    private func removeObservers() {
        for var observation in observations {
            AudioObjectRemovePropertyListenerBlock(observation.object, &observation.address, .main, observation.listener)
        }
        observations.removeAll()
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func isSettable(_ selector: AudioObjectPropertySelector, object: AudioObjectID) -> Bool {
        var address = address(selector)
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    private static func read<T>(_ selector: AudioObjectPropertySelector, object: AudioObjectID, initial: T) -> T? {
        var address = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? value : nil
    }

    private static func string(_ selector: AudioObjectPropertySelector, object: AudioObjectID) -> String? {
        guard let value = read(selector, object: object, initial: Optional<Unmanaged<CFString>>.none) else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private static func array<T>(_ selector: AudioObjectPropertySelector, object: AudioObjectID,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = Array(repeating: initial, count: Int(size) / MemoryLayout<T>.stride)
        guard !values.isEmpty else { return [] }
        let status = values.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }
}
