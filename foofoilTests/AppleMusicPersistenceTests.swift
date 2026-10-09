import Foundation
import MusicKit
import SQLite3
import Testing
@testable import foofoil

@MainActor
@Suite(.serialized)
struct AppleMusicPersistenceTests {
    private func item(_ kind: AppleMusicReference.Kind, id: String = UUID().uuidString) throws -> AppleMusicLibraryItem {
        let types: [AppleMusicReference.Kind: String] = [.song: "library-songs", .album: "library-albums", .playlist: "library-playlists"]
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "type": types[kind]!, "attributes": [
                "name": "Library \(kind.rawValue)", "artistName": "Artist", "curatorName": "Curator", "albumName": "Album"
            ]
        ])
        switch kind {
        case .song: return .song(try JSONDecoder().decode(Song.self, from: data))
        case .album: return .album(try JSONDecoder().decode(Album.self, from: data))
        case .playlist: return .playlist(try JSONDecoder().decode(Playlist.self, from: data))
        }
    }

    @Test func musicFoilsDefaultToBorderlessAndPersistBorderChoice() throws {
        let song = try item(.song)
        let state = AppState()
        state.prepareAppleMusic(song)
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        #expect(!state.showBorder)
        #expect(state.isAudioDocument && !state.isBlank)
        state.saveState()
        let first = try #require(HistoryRepository.shared.config(id: state.id))
        #expect(HistoryRepository.shared.recent(limit: 30).contains { $0.id == state.id })
        #expect(first.appleMusicReference == song.reference)
        #expect(first.contentKind == .audio)
        #expect(first.historyMenuSymbolName == "music.pages.fill")
        #expect(first.historyMenuDisplayName == song.title)
        #expect(!first.showBorder)

        state.showBorder = true
        let bordered = try #require(HistoryRepository.shared.config(id: state.id))
        #expect(bordered.showBorder)
        let restored = AppState(config: bordered)
        #expect(restored.appleMusicReference == song.reference)
        #expect(restored.isAudioDocument && !restored.isBlank && restored.showBorder)
        #expect(restored.appleMusicItem == nil)
        restored.loadConfig(first)
        #expect(restored.appleMusicReference == song.reference && !restored.showBorder)
        state.showBorder = true
        let identity = state.id
        state.prepareAppleMusic(song)
        #expect(state.id == identity && state.showBorder)
        state.isBatchUpdating = true
        state.prepareAppleMusic(try item(.album))
        #expect(state.id != identity && !state.showBorder)
        #expect(state.sourceFingerprint == state.appleMusicReference?.sourceFingerprint)
        // 未保存的新专辑不进入用户历史；清理此前保存的歌曲。
        HistoryManager.shared.removeFromHistory(bordered)
    }

    @Test func allLibraryKindsRoundTripThroughConfigAndDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try HistoryDatabase(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        for kind in [AppleMusicReference.Kind.song, .album, .playlist] {
            let music = try item(kind)
            let config = WindowConfig(id: UUID(), originalImageName: music.title, showBorder: false,
                                      sourceFingerprint: music.reference.sourceFingerprint, appleMusicReference: music.reference)
            let decoded = try JSONDecoder().decode(WindowConfig.self, from: JSONEncoder().encode(config))
            #expect(decoded.appleMusicReference == music.reference)
            #expect(HistoryContentKind.infer(from: decoded) == .audio)
            try database.upsert(decoded)
            let loaded = try #require(try database.config(id: config.id))
            #expect(loaded.appleMusicReference == music.reference && loaded.contentKind == .audio)
            #expect(!loaded.showBorder && loaded.originalImageName == music.title)
            let duplicate = WindowConfig(id: UUID(), originalImageName: music.title,
                                         sourceFingerprint: music.reference.sourceFingerprint, appleMusicReference: music.reference)
            try database.upsert(duplicate)
            #expect(try database.config(id: config.id) == nil)
            #expect(try database.config(id: duplicate.id)?.appleMusicReference == music.reference)
        }
        #expect(try database.recent(limit: 10).count == 3)
    }

    @Test func existingDatabaseGainsLibraryReferenceColumn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite3")
        let database = try HistoryDatabase(databaseURL: url)
        let note = WindowConfig(id: UUID(), text: "Existing note")
        try database.upsert(note)
        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        #expect(sqlite3_exec(connection, "ALTER TABLE history_items DROP COLUMN apple_music_reference", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(connection, "PRAGMA user_version = 17", nil, nil, nil) == SQLITE_OK)
        let migrated = try HistoryDatabase(databaseURL: url)
        #expect(try migrated.config(id: note.id)?.text == note.text)
        let music = try item(.album)
        let config = WindowConfig(id: UUID(), originalImageName: music.title, appleMusicReference: music.reference)
        try migrated.upsert(config)
        #expect(try migrated.config(id: config.id)?.appleMusicReference == music.reference)
    }

    @Test func restorationRetainsIdentityAndRejectsLateResponseAfterContentChanges() async throws {
        let music = try item(.album)
        let config = WindowConfig(id: UUID(), originalImageName: music.title, showBorder: true,
                                  sourceFingerprint: music.reference.sourceFingerprint, appleMusicReference: music.reference)
        let state = AppState(config: config)
        state.isBatchUpdating = true
        await state.restoreAppleMusicItem { reference in
            #expect(reference == music.reference)
            return music
        }
        #expect(state.appleMusicItem?.id == music.id && state.id == config.id && state.showBorder)
        state.appleMusicItem = nil
        state.appleMusicReference = music.reference
        var continuation: CheckedContinuation<AppleMusicLibraryItem, Never>?
        let task = Task {
            await state.restoreAppleMusicItem { _ in
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        state.text = "New content"
        continuation?.resume(returning: music)
        await task.value
        #expect(state.appleMusicItem == nil && state.appleMusicReference == nil)
        #expect(state.text == "New content")
    }

    @Test func missingLibraryContentKeepsReferenceAndCanRetry() async throws {
        let music = try item(.playlist)
        let state = AppState(config: WindowConfig(id: UUID(), showBorder: false, appleMusicReference: music.reference))
        state.isBatchUpdating = true
        struct Missing: LocalizedError { var errorDescription: String? { "Missing test item" } }
        await state.restoreAppleMusicItem { _ in throw Missing() }
        #expect(state.appleMusicReference == music.reference && state.appleMusicItem == nil)
        #expect(state.appleMusicRestoreError == "Missing test item" && !state.isBlank)
        await state.restoreAppleMusicItem { _ in music }
        #expect(state.appleMusicItem?.id == music.id && state.appleMusicRestoreError == nil)
        #expect(!state.showBorder)
    }
}
