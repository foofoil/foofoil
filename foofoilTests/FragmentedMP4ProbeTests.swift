import Foundation
import Testing
@testable import foofoil

@Suite
struct FragmentedMP4ProbeTests {
    @Test func audioInitializationSegmentIsAudio() throws {
        let url = try writeFile(named: "audio.m4s", try fragmentedFile(handlers: ["soun"]))
        #expect(FragmentedMP4Probe.trackKind(of: url) == .audio)
        #expect(AppState.externalMediaDisplayName(for: url) == "audio.m4a")
        #expect(FileListGrouper.classify(url: url) == .listable(.audio))
    }

    @Test func videoInitializationSegmentIsVideo() throws {
        let url = try writeFile(named: "video.m4s", try fragmentedFile(handlers: ["vide"]))
        #expect(FragmentedMP4Probe.trackKind(of: url) == .video)
        #expect(AppState.externalMediaDisplayName(for: url) == "video.mp4")
        #expect(FileListGrouper.classify(url: url) == .listable(.video))
        #expect(FileListGrouper.dropKind(url: url) == .video)
    }

    @Test func videoWinsWhenAudioTrackIsAlsoPresent() throws {
        let url = try writeFile(named: "mixed.m4s", try fragmentedFile(handlers: ["soun", "vide"]))
        #expect(FragmentedMP4Probe.trackKind(of: url) == .video)
    }

    @Test func mediaSegmentWithoutInitializationIsUnknown() throws {
        var data = box("ftyp", payload: Array("iso5".utf8) + [0, 0, 0, 0])
        data += box("styp", payload: Array("msdh".utf8) + [0, 0, 0, 0])
        data += box("moof", payload: box("mfhd", payload: [0, 0, 0, 0, 0, 0, 0, 1]))
        data += box("mdat", payload: [UInt8](repeating: 0, count: 64))
        let url = try writeFile(named: "segment.m4s", data)
        #expect(FragmentedMP4Probe.trackKind(of: url) == nil)
        #expect(AppState.externalMediaDisplayName(for: url) == "segment.m4s")
        #expect(!AppState.isExternalMediaFile(url: url))
    }

    @Test func nonBoxedFileIsUnknown() throws {
        let url = try writeFile(named: "broken.m4s", Array("not an mp4 file at all".utf8))
        #expect(FragmentedMP4Probe.trackKind(of: url) == nil)
    }

    @Test func otherExtensionsAreNotProbed() throws {
        let url = try writeFile(named: "clip.mp4", try fragmentedFile(handlers: ["vide"]))
        #expect(AppState.fragmentedMediaTrackKind(of: url) == nil)
        #expect(AppState.externalMediaDisplayName(for: url) == "clip.mp4")
    }

    @Test func hev1SampleEntryIsRewrittenInPlaybackCopy() throws {
        let bytes = try fragmentedFile(handlers: ["vide"], sampleEntry: "hev1")
        let url = try writeFile(named: "hevc.m4s", bytes)
        let offset = Int(try #require(FragmentedMP4Probe.hev1TagOffset(of: url)))
        #expect(Array(bytes[offset..<(offset + 4)]) == Array("hev1".utf8))

        let playable = FragmentedMP4PlaybackCopy.playableURL(for: url)
        defer { if playable != url { try? FileManager.default.removeItem(at: playable) } }
        #expect(playable != url)
        #expect(playable.lastPathComponent.hasPrefix(FragmentedMP4PlaybackCopy.filePrefix))

        var expected = bytes
        expected.replaceSubrange(offset..<(offset + 4), with: Array("hvc1".utf8))
        #expect([UInt8](try Data(contentsOf: playable)) == expected)
        #expect(try Data(contentsOf: url) == Data(bytes))
    }

    @Test func nonHEVCSegmentsArePlayedDirectly() throws {
        let url = try writeFile(named: "avc.m4s", try fragmentedFile(handlers: ["vide"], sampleEntry: "avc1"))
        #expect(FragmentedMP4Probe.hev1TagOffset(of: url) == nil)
        #expect(FragmentedMP4PlaybackCopy.playableURL(for: url) == url)
    }

    private func fragmentedFile(handlers: [String], sampleEntry: String = "avc1") throws -> [UInt8] {
        let traks = handlers.map { handler -> [UInt8] in
            let hdlrPayload: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0] + Array(handler.utf8) + [UInt8](repeating: 0, count: 13)
            let entry = box(sampleEntry, payload: [UInt8](repeating: 0, count: 78))
            let stsd = box("stsd", payload: [0, 0, 0, 0, 0, 0, 0, 1] + entry)
            let minf = box("minf", payload: box("stbl", payload: stsd))
            return box("trak", payload: box("mdia", payload: box("hdlr", payload: hdlrPayload) + minf))
        }.flatMap { $0 }
        var data = box("ftyp", payload: Array("iso5".utf8) + [0, 0, 0, 0])
        data += box("moov", payload: box("mvhd", payload: [UInt8](repeating: 0, count: 100)) + traks)
        data += box("moof", payload: box("mfhd", payload: [0, 0, 0, 0, 0, 0, 0, 1]))
        data += box("mdat", payload: [UInt8](repeating: 0, count: 64))
        return data
    }

    private func box(_ type: String, payload: [UInt8]) -> [UInt8] {
        let size = UInt32(payload.count + 8)
        let header = [UInt8(size >> 24), UInt8((size >> 16) & 0xff), UInt8((size >> 8) & 0xff), UInt8(size & 0xff)]
        return header + Array(type.utf8) + payload
    }

    private func writeFile(named name: String, _ bytes: [UInt8]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-m4s-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }
}
