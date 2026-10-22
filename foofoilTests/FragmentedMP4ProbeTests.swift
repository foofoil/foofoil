import Foundation
import AVFoundation
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

    @Test(arguments: ["m4s", "mp4", "m4v", "mov"])
    func hev1SampleEntryIsRewrittenInPlaybackCopy(ext: String) throws {
        let bytes = try fragmentedFile(handlers: ["vide"], sampleEntry: "hev1")
        let url = try writeFile(named: "hevc.\(ext)", bytes)
        let offset = Int(try #require(FragmentedMP4Probe.hev1TagOffsets(of: url).first))
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
        #expect(FragmentedMP4Probe.hev1TagOffsets(of: url).first == nil)
        #expect(FragmentedMP4PlaybackCopy.playableURL(for: url) == url)
    }

    @Test func incompleteHEVCConfigurationIsNotRetagged() throws {
        let bytes = try fragmentedFile(handlers: ["vide"], sampleEntry: "hev1", parameterTypes: [33, 34])
        let url = try writeFile(named: "incomplete.mp4", bytes)
        #expect(FragmentedMP4Probe.hev1TagOffsets(of: url).isEmpty)
        #expect(FragmentedMP4PlaybackCopy.playableURL(for: url) == url)
        #expect(try Data(contentsOf: url) == Data(bytes))
    }

    @Test func allHEVCVideoTracksAreRetagged() throws {
        let url = try writeFile(named: "multi.mp4", try fragmentedFile(handlers: ["vide", "soun", "vide"], sampleEntry: "hev1"))
        let offsets = FragmentedMP4Probe.hev1TagOffsets(of: url)
        #expect(offsets.count == 2)
        let playable = FragmentedMP4PlaybackCopy.playableURL(for: url)
        defer { if playable != url { try? FileManager.default.removeItem(at: playable) } }
        let bytes = [UInt8](try Data(contentsOf: playable))
        for offset in offsets {
            #expect(Array(bytes[Int(offset)..<(Int(offset) + 4)]) == Array("hvc1".utf8))
        }
    }

    @Test func playbackCloneCanExceedDefaultCacheLimit() throws {
        let url = try writeFile(named: "large.mp4", try fragmentedFile(handlers: ["vide"], sampleEntry: "hev1"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let size = UInt64(ContentCache.defaultLimit) + 4096
        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: size)
        try handle.close()
        let playable = FragmentedMP4PlaybackCopy.playableURL(for: url)
        defer { if playable != url { try? FileManager.default.removeItem(at: playable) } }
        #expect(playable != url)
        #expect(try playable.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(size))
        #expect(FragmentedMP4PlaybackCopy.playableURL(for: url) == playable)
        // 源文件变化后不复用旧副本。
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: url.path)
        #expect(FragmentedMP4PlaybackCopy.copyURL(for: url) != playable)
    }

    @Test func malformedBoxSizesAreRejectedWithoutOverflow() throws {
        var bytes = box("ftyp", payload: Array("iso5".utf8) + [0, 0, 0, 0])
        bytes += [0, 0, 0, 1] + Array("moov".utf8) + [UInt8](repeating: 255, count: 8)
        let url = try writeFile(named: "overflow.mp4", bytes)
        #expect(FragmentedMP4Probe.hev1TagOffsets(of: url).isEmpty)
    }

    @Test func ordinaryMP4WithTrailingMoovUsesCompatibilityCopy() throws {
        let bytes = try fragmentedFile(handlers: ["vide"], sampleEntry: "hev1")
        let ftypSize = 16
        let moovSize = Int(bytes[16]) << 24 | Int(bytes[17]) << 16 | Int(bytes[18]) << 8 | Int(bytes[19])
        let ordinary = Array(bytes[..<ftypSize]) + box("mdat", payload: [UInt8](repeating: 0, count: 128)) + Array(bytes[ftypSize..<(ftypSize + moovSize)])
        let url = try writeFile(named: "ordinary.mp4", ordinary)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let asset = AVURLAsset.media(url: url)
        defer { if asset.url != url { try? FileManager.default.removeItem(at: asset.url) } }
        #expect(asset.url != url)
        #expect(FragmentedMP4Probe.hev1TagOffsets(of: asset.url).isEmpty)
        #expect(try Data(contentsOf: url) == Data(ordinary))
    }

    private func fragmentedFile(handlers: [String], sampleEntry: String = "avc1", parameterTypes: [UInt8] = [32, 33, 34]) throws -> [UInt8] {
        let traks = handlers.map { handler -> [UInt8] in
            let hdlrPayload: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0] + Array(handler.utf8) + [UInt8](repeating: 0, count: 13)
            var configuration: [UInt8] = [1] + [UInt8](repeating: 0, count: 21) + [UInt8(parameterTypes.count)]
            for type in parameterTypes { configuration += [type, 0, 1, 0, 2, type << 1, 1] }
            let entry = box(sampleEntry, payload: [UInt8](repeating: 0, count: 78) + box("hvcC", payload: configuration))
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
