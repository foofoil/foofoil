//
//  MIDIPlaybackTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/11/28.
//

import Foundation
import Testing
@testable import foofoil

@Suite(.serialized)
struct MIDIPlaybackTests {
    @Test func detectionRecognizesStandardMIDIButNotPCM() {
        #expect(AudioMetadataLoader.isMIDI(URL(fileURLWithPath: "/tmp/song.mid")))
        #expect(AudioMetadataLoader.isMIDI(URL(fileURLWithPath: "/tmp/song.midi")))
        #expect(AudioMetadataLoader.isMIDI(URL(fileURLWithPath: "/tmp/song.kar")))
        #expect(!AudioMetadataLoader.isMIDI(URL(fileURLWithPath: "/tmp/song.mp3")))
        #expect(!AudioMetadataLoader.isMIDI(URL(fileURLWithPath: "/tmp/song.flac")))
    }

    @Test func durationUsesTempoMapRatherThanFixedTempo() throws {
        let url = try makeMIDIFile(tempoMicroseconds: 500_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let duration = try #require(AudioMetadataLoader.midiDuration(for: url))
        #expect(abs(duration - 0.5) < 0.01)
    }

    @Test func metadataReadsSequenceName() async throws {
        let url = try makeMIDIFile(trackTitles: ["My MIDI Song"])
        defer { try? FileManager.default.removeItem(at: url) }

        let info = await AudioMetadataLoader.load(from: url, includeArtwork: false)
        #expect(info.title == "My MIDI Song")
        #expect(info.taggedTitle == "My MIDI Song")
        #expect(info.instrumentName == nil)
        #expect(info.formatName == "MIDI")
        #expect(info.artwork == nil)
    }

    @Test func metadataUsesFirstTrackNameInsteadOfInstrumentTrack() async throws {
        let url = try makeMIDIFile(trackTitles: ["Real Title", "Piano"], fileName: "some-file")
        defer { try? FileManager.default.removeItem(at: url) }

        let info = await AudioMetadataLoader.load(from: url, includeArtwork: false)
        #expect(info.title == "Real Title")
        #expect(info.taggedTitle == "Real Title")
        #expect(info.instrumentName == "Piano")
    }

    @Test func metadataFallsBackToFileNameWhenOnlyInstrumentTrackIsNamed() async throws {
        let url = try makeMIDIFile(
            trackTitles: [nil, "SmartMusic SoftSynth", "SmartMusic SoftSynth 1"],
            fileName: "New Super Mario Bros - Athletic"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let info = await AudioMetadataLoader.load(from: url, includeArtwork: false)
        #expect(info.title == "New Super Mario Bros - Athletic")
        #expect(info.taggedTitle == nil)
        #expect(info.instrumentName == "SmartMusic SoftSynth")
    }

    @Test func metadataRejectsSynthNameInFirstTrack() async throws {
        let url = try makeMIDIFile(trackTitles: ["SmartMusic SoftSynth"], fileName: "Prelude")
        defer { try? FileManager.default.removeItem(at: url) }

        let info = await AudioMetadataLoader.load(from: url, includeArtwork: false)
        #expect(info.title == "Prelude")
        #expect(info.taggedTitle == nil)
        #expect(info.instrumentName == "SmartMusic SoftSynth")
    }

    @Test func listDurationLoaderHandlesMIDI() async throws {
        let url = try makeMIDIFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let seconds = try #require(await MediaDurationLoader.duration(for: url, kind: .audio))
        #expect(abs(seconds - 0.5) < 0.01)
    }

    @MainActor
    @Test func controllerUsesMIDIPlayerWithoutVolumeChrome() throws {
        let url = try makeMIDIFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let state = AppState()
        let controller = AudioPlaybackController(appStateID: state.id, url: url, isLooping: false)
        defer { controller.closeOutput() }

        #expect(controller.isMIDIPlayback)
        #expect(abs(controller.duration - 0.5) < 0.01)
        #expect(!controller.supportsVolumeControl)
        #expect(controller.deviceServiceSnapshot == nil)

        controller.seek(to: 0.25)
        #expect(abs(controller.currentTime - 0.25) < 0.001)
    }

    @MainActor
    @Test func directFileOpenAcceptsMIDI() async throws {
        let url = try makeMIDIFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let state = AppState()
        state.openFile(url: url)
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        let deadline = Date().addingTimeInterval(10)
        while state.pendingContentOpenCount > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(state.pendingContentOpenCount == 0)
        #expect(state.isAudioDocument)
        #expect(TestFileIdentity.equals(state.imageURL, url))
    }

    // MARK: - Fixture

    /// 生成 960 PPQ、单轨、单音符的 SMF 0；音符长度为一个四分音符。
    private func makeMIDIFile(
        trackTitles: [String?] = ["MIDI Test"],
        tempoMicroseconds: UInt32 = 500_000,
        fileName: String? = nil
    ) throws -> URL {
        precondition(!trackTitles.isEmpty)
        let format = trackTitles.count > 1 ? UInt16(1) : UInt16(0)
        var tracks: [Data] = []

        for (index, title) in trackTitles.enumerated() {
            var track = Data()
            if let title {
                track.append(contentsOf: metaEvent(type: 0x03, text: title))
            }
            if index == 0 {
                track.append(contentsOf: tempoEvent(tempoMicroseconds))
            }
            if index == trackTitles.count - 1 {
                track.append(contentsOf: noteEvents())
            }
            track.append(contentsOf: [0x00, 0xFF, 0x2F, 0x00])
            tracks.append(track)
        }

        var data = Data("MThd".utf8)
        data.append(contentsOf: bigEndian(UInt32(6)))
        data.append(contentsOf: bigEndian(format))
        data.append(contentsOf: bigEndian(UInt16(tracks.count)))
        data.append(contentsOf: bigEndian(UInt16(960)))
        for track in tracks {
            data.append(contentsOf: Data("MTrk".utf8))
            data.append(contentsOf: bigEndian(UInt32(track.count)))
            data.append(track)
        }

        let name = fileName ?? "midi-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name.hasSuffix(".mid") ? name : "\(name).mid")
        try data.write(to: url)
        return url
    }

    /// 960 PPQ、120 BPM 下的一个四分音符。
    private func noteEvents() -> [UInt8] {
        [0x00, 0x90, 0x3C, 0x64] + variableLength(960) + [0x80, 0x3C, 0x40]
    }

    private func tempoEvent(_ microsecondsPerQuarter: UInt32) -> [UInt8] {
        [
            0x00, 0xFF, 0x51, 0x03,
            UInt8((microsecondsPerQuarter >> 16) & 0xFF),
            UInt8((microsecondsPerQuarter >> 8) & 0xFF),
            UInt8(microsecondsPerQuarter & 0xFF)
        ]
    }

    private func metaEvent(type: UInt8, text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return [0x00, 0xFF, type] + variableLength(bytes.count) + bytes
    }

    private func variableLength(_ value: Int) -> [UInt8] {
        var value = value
        var bytes = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            bytes.append(UInt8((value & 0x7F) | 0x80))
            value >>= 7
        }
        return bytes.reversed()
    }

    private func bigEndian(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }
}
