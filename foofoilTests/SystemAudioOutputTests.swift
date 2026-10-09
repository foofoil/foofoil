import CoreAudio
import Testing
@testable import foofoil

struct SystemAudioOutputTests {
    @Test func discreteRatesDoNotOfferUnsupportedChoices() {
        let ranges = [AudioValueRange(mMinimum: 44100, mMaximum: 44100),
                      AudioValueRange(mMinimum: 96000, mMaximum: 96000)]
        #expect(SystemAudioOutputController.sampleRateOptions(ranges: ranges, current: 48000) == [44100, 96000])
    }

    @Test func continuousRangesIncludeBoundariesAndCurrentRate() {
        let ranges = [AudioValueRange(mMinimum: 40000, mMaximum: 50000)]
        #expect(SystemAudioOutputController.sampleRateOptions(ranges: ranges, current: 46000) == [40000, 44100, 46000, 48000, 50000])
        #expect(SystemAudioOutputController.sampleRateOptions(ranges: [], current: 48000).isEmpty)
    }

    @Test @MainActor func readsSystemOutputWithoutChangingIt() {
        let output = SystemAudioOutputController()
        output.start()
        defer { output.stop() }
        #expect(Set(output.devices.map(\.id)).count == output.devices.count)
        if let selected = output.selectedDevice {
            #expect(selected.id == HostAudioVolume.defaultOutputUID())
            #expect(selected.sampleRate.map { $0 > 0 } ?? true)
        }
        #expect(output.error == nil)
    }
}
