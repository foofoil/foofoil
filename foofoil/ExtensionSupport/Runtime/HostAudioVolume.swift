//
//  HostAudioVolume.swift
//  foofoil
//
//  Created by 董超 on 2026/9/12.
//

import CoreAudio
import Foundation

/// 扩展独占输出（DoP / APE PCM）不经过宿主 AVAudioEngine mixer，音量只能直接读写设备硬件标量。
/// 硬件音量不修改采样数据，DoP 标记与位精确路径都不受影响；设备没有硬件音量时不提供软件降级。
enum HostAudioVolume {
    /// USB DAC 常见只在 1/2 声道暴露音量，主元素可为空，因此按优先级尝试。
    private static let candidateElements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return uid(for: deviceID)
    }

    static func supportsVolume(deviceID: AudioDeviceID) -> Bool {
        !writableElements(deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar).isEmpty
    }

    static func volume(deviceID: AudioDeviceID) -> Float? {
        let elements = writableElements(deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar)
        guard !elements.isEmpty else { return nil }
        if elements.contains(kAudioObjectPropertyElementMain) {
            return readScalar(deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain)
        }
        return elements.compactMap {
            readScalar(deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar, element: $0)
        }.first
    }

    static func setVolume(_ value: Float, deviceID: AudioDeviceID) {
        let clamped = max(0, min(1, value))
        let elements = writableElements(deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar)
        guard !elements.isEmpty else { return }
        if elements.contains(kAudioObjectPropertyElementMain) {
            writeScalar(deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar,
                        element: kAudioObjectPropertyElementMain, value: clamped)
            return
        }
        for element in elements {
            writeScalar(deviceID: deviceID, selector: kAudioDevicePropertyVolumeScalar,
                        element: element, value: clamped)
        }
    }

    static func supportsMute(deviceID: AudioDeviceID) -> Bool {
        !writableElements(deviceID: deviceID, selector: kAudioDevicePropertyMute).isEmpty
    }

    static func isMuted(deviceID: AudioDeviceID) -> Bool? {
        let elements = writableElements(deviceID: deviceID, selector: kAudioDevicePropertyMute)
        guard let element = elements.first else { return nil }
        return readMute(deviceID: deviceID, element: element)
    }

    static func setMuted(_ muted: Bool, deviceID: AudioDeviceID) {
        for element in writableElements(deviceID: deviceID, selector: kAudioDevicePropertyMute) {
            writeMute(deviceID: deviceID, element: element, muted: muted)
        }
    }

    private static func uid(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private static func writableElements(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> [UInt32] {
        candidateElements.filter { element in
            var address = controlAddress(selector: selector, element: element)
            var settable = DarwinBoolean(false)
            return AudioObjectHasProperty(deviceID, &address)
                && AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr
                && settable.boolValue
        }
    }

    private static func readScalar(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        element: UInt32
    ) -> Float? {
        var address = controlAddress(selector: selector, element: element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private static func writeScalar(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        element: UInt32,
        value: Float
    ) {
        var address = controlAddress(selector: selector, element: element)
        var value = value
        _ = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    private static func readMute(deviceID: AudioDeviceID, element: UInt32) -> Bool? {
        var address = controlAddress(selector: kAudioDevicePropertyMute, element: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value != 0 : nil
    }

    private static func writeMute(deviceID: AudioDeviceID, element: UInt32, muted: Bool) {
        var address = controlAddress(selector: kAudioDevicePropertyMute, element: element)
        var value: UInt32 = muted ? 1 : 0
        _ = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private static func controlAddress(
        selector: AudioObjectPropertySelector,
        element: UInt32
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }
}
