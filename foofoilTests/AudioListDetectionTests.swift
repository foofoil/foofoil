//
//  AudioListDetectionTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/24.
//

import Testing
import Foundation
@testable import foofoil

@Suite struct AudioListDetectionTests {
    @Test func trackNameRecognizesCommonAlbumPatterns() {
        #expect(AudioListDetector.trackName(for: "01 - Song.flac") == .init(family: "track:", number: 1))
        #expect(AudioListDetector.trackName(for: "02.Song.flac") == .init(family: "track:", number: 2))
        #expect(AudioListDetector.trackName(for: "03_Song.mp3") == .init(family: "track:", number: 3))
        #expect(AudioListDetector.trackName(for: "1 Song.dsf") == .init(family: "track:", number: 1))
        #expect(AudioListDetector.trackName(for: "12.flac") == .init(family: "track:", number: 12))
        #expect(AudioListDetector.trackName(for: "Track 04 - Song.mp3") == .init(family: "track:track", number: 4))
        #expect(AudioListDetector.trackName(for: "Track05.mp3") == .init(family: "track:track", number: 5))
        #expect(AudioListDetector.trackName(for: "CD1 - 06 Song.flac") == .init(family: "track:cd1", number: 6))
        #expect(AudioListDetector.trackName(for: "Disc 1 - 07 Song.flac") == .init(family: "track:disc 1", number: 7))
        #expect(AudioListDetector.trackName(for: "Disc2 08 Song.flac") == .init(family: "track:disc2", number: 8))
        #expect(AudioListDetector.trackName(for: "CD 1 - 05 Song.flac") == .init(family: "track:cd 1", number: 5))
        #expect(AudioListDetector.trackName(for: "周杰伦 - 07 - 晴天.flac") == .init(family: "track:周杰伦", number: 7))
        // 曲名里的数字不会抢走真正的轨号。
        #expect(AudioListDetector.trackName(for: "02 - Track 02.flac") == .init(family: "track:", number: 2))
        #expect(AudioListDetector.trackName(for: "03 - Song 2.mp3") == .init(family: "track:", number: 3))
        #expect(AudioListDetector.trackName(for: "Track 04 - Part 2.mp3") == .init(family: "track:track", number: 4))
        // 碟号-轨号：家族包含碟号，跨碟的相同轨号不会互相去重。
        #expect(AudioListDetector.trackName(for: "1-08 Song.flac") == .init(family: "disc1:", number: 8))
        #expect(AudioListDetector.trackName(for: "2-08 Song.flac") == .init(family: "disc2:", number: 8))
    }

    @Test func trackNameRejectsNonAlbumNumberPrefixes() {
        #expect(AudioListDetector.trackName(for: "1979.mp3") == nil)
        #expect(AudioListDetector.trackName(for: "2021-01-01 live.mp3") == nil)
        #expect(AudioListDetector.trackName(for: "Blink-182 - Song.mp3") == nil)
        #expect(AudioListDetector.trackName(for: "01Song.mp3") == nil)
        #expect(AudioListDetector.trackName(for: "0 - Intro.mp3") == nil)
        #expect(AudioListDetector.trackName(for: "101 - Big Track.flac") == nil)
        #expect(AudioListDetector.trackName(for: "24bit test.flac") == nil)
    }

    @Test func detectFindsNumberedSiblingsInTrackOrder() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("03 - Track 03.flac", in: directory)
        try write("01 - Track 01.flac", in: directory)
        try write("02 - Track 02.flac", in: directory)
        try write("notes.txt", in: directory)
        try write("04 - Other.mp3", in: directory)
        try write("cover.jpg", in: directory)

        let match = try #require(AudioListDetector.detect(for: directory.appendingPathComponent("02 - Track 02.flac")))
        #expect(match == .files([
            directory.appendingPathComponent("01 - Track 01.flac"),
            directory.appendingPathComponent("02 - Track 02.flac"),
            directory.appendingPathComponent("03 - Track 03.flac")
        ]))
    }

    @Test func detectRequiresTheOpenedFileToBelongToTheList() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("01 - A.flac", in: directory)
        try write("02 - B.flac", in: directory)
        try write("random.flac", in: directory)

        #expect(AudioListDetector.detect(for: directory.appendingPathComponent("random.flac")) == nil)
    }

    @Test func detectRejectsDuplicateTrackNumbers() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("01 - A.flac", in: directory)
        try write("01 - B.flac", in: directory)

        #expect(AudioListDetector.detect(for: directory.appendingPathComponent("01 - A.flac")) == nil)
    }

    @Test func detectPrefersSameNameCue() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try write("album.flac", in: directory)
        let cue = try writeCue(
            named: "album.cue",
            in: directory,
            fileName: "album.flac",
            trackCount: 2
        )

        #expect(AudioListDetector.detect(for: audio) == .cue(cue))
    }

    @Test func detectFindsCueReferencingTheOpenedTrack() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try write("01.flac", in: directory)
        let second = try write("02.flac", in: directory)
        let cue = try writeCue(
            named: "album.cue",
            in: directory,
            fileNames: ["01.flac", "02.flac"],
            trackCount: 2
        )

        #expect(AudioListDetector.detect(for: first) == .cue(cue))
        #expect(AudioListDetector.detect(for: second) == .cue(cue))
    }

    @Test func detectIgnoresCueThatDoesNotReferenceTheFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("other.flac", in: directory)
        let bonus = try write("bonus.flac", in: directory)
        _ = try writeCue(
            named: "album.cue",
            in: directory,
            fileName: "other.flac",
            trackCount: 2
        )

        #expect(AudioListDetector.detect(for: bonus) == nil)
    }

    @Test func detectIgnoresSingleTrackCue() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try write("album.flac", in: directory)
        _ = try writeCue(
            named: "album.cue",
            in: directory,
            fileName: "album.flac",
            trackCount: 1
        )

        #expect(AudioListDetector.detect(for: audio) == nil)
    }

    @Test func preferredItemIDMatchesByPath() {
        let items = [
            FileListItem(id: "a", path: "/tmp/01 - A.flac", displayName: "01 - A.flac"),
            FileListItem(id: "b", path: "/tmp/02 - B.flac", displayName: "02 - B.flac")
        ]
        #expect(AppState.fileListItemID(in: items, matching: URL(fileURLWithPath: "/tmp/02 - B.flac")) == "b")
        #expect(AppState.fileListItemID(in: items, matching: URL(fileURLWithPath: "/tmp/03 - C.flac")) == nil)
        #expect(AppState.fileListItemID(in: items, matching: nil) == nil)
    }

    @Test @MainActor func detectedAudioListKeepsTheOpenedTrackSelected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try write("01 - A.mp3", in: directory)
        let second = try write("02 - B.mp3", in: directory)

        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        state.openAudio(url: second)
        let originalID = state.id

        state.installDetectedAudioList(.files([first, second]), preferredURL: second)

        #expect(state.id == originalID)
        #expect(state.fileList?.items.map(\.path) == [first.path, second.path])
        #expect(state.fileList?.currentItem?.path == second.path)
        #expect(state.imageURL?.path == second.path)
    }

    // MARK: - Helpers

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-audio-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("fake audio".utf8).write(to: url)
        return url
    }

    /// 单文件 CUE：同一音频文件上切分多段曲目。
    @discardableResult
    private func writeCue(
        named name: String,
        in directory: URL,
        fileName: String,
        trackCount: Int
    ) throws -> URL {
        try writeCue(named: name, in: directory, fileNames: [fileName], trackCount: trackCount)
    }

    /// 多文件 CUE：每个 FILE 一段，曲目时间在各文件内独立累计。
    @discardableResult
    private func writeCue(
        named name: String,
        in directory: URL,
        fileNames: [String],
        trackCount: Int
    ) throws -> URL {
        var lines = ["TITLE \"Album\"", "PERFORMER \"Artist\""]
        var trackNumber = 1
        for fileName in fileNames {
            lines.append("FILE \"\(fileName)\" WAVE")
            for index in 0..<trackCount {
                lines.append("  TRACK \(String(format: "%02d", trackNumber)) AUDIO")
                lines.append("    TITLE \"Track \(trackNumber)\"")
                lines.append("    INDEX 01 \(String(format: "%02d", index)):00:00")
                trackNumber += 1
            }
        }
        let url = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
