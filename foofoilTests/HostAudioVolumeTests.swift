//
//  HostAudioVolumeTests.swift
//  foofoilTests
//
//  Created by 董超 on 2026/9/12.
//

import CoreAudio
import Testing
@testable import foofoil

struct HostAudioVolumeTests {
    @Test func resolvesDefaultOutputAndRoundTripsVolume() throws {
        let uid = try #require(HostAudioVolume.defaultOutputUID())
        let deviceID = try #require(HostAudioVolume.deviceID(forUID: uid))
        guard HostAudioVolume.supportsVolume(deviceID: deviceID) else { return }
        let original = try #require(HostAudioVolume.volume(deviceID: deviceID))
        // 写回原值只验证读写链路，不改变用户音量。
        HostAudioVolume.setVolume(original, deviceID: deviceID)
        let readBack = try #require(HostAudioVolume.volume(deviceID: deviceID))
        #expect(abs(readBack - original) < 0.001)
    }

    @Test func unknownUIDDoesNotResolveDevice() {
        #expect(HostAudioVolume.deviceID(forUID: "foofoil.missing.device.uid") == nil)
    }
}
