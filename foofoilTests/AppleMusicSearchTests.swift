import Foundation
import MusicKit
import Testing
@testable import foofoil

@MainActor
@Suite(.serialized)
struct AppleMusicSearchTests {
    private func song(_ id: String, title: String) throws -> AppleMusicLibraryItem {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "type": "library-songs", "attributes": [
                "name": title, "artistName": "Artist", "albumName": "Album", "durationInMillis": 180000
            ]
        ])
        return .song(try JSONDecoder().decode(Song.self, from: data))
    }
    private func history(_ title: String) -> HistorySearchResult {
        .init(id: UUID(), title: title, contentKind: .text, thumbnailPath: nil,
              matchedSnippet: nil, matchedPageNumber: nil, score: 1)
    }
    private func album(_ id: String) throws -> AppleMusicLibraryItem {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "type": "library-albums", "attributes": [
                "name": "Album \(id)", "artistName": "Artist", "trackCount": 10
            ]
        ])
        return .album(try JSONDecoder().decode(Album.self, from: data))
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func unauthorizedSearchNeverRequestsMusic() async throws {
        var requests = 0
        let model = HistorySearchViewModel(historySearch: { _ in [] }, fileSearch: { _, done in done(.results([])) },
                                          cameraAvailable: { false }, musicSearch: { _ in requests += 1; return [] },
                                          musicAuthorized: { false }, musicEnabled: { true })
        model.query = "music"
        try await waitUntil { !model.isSearching }
        #expect(requests == 0)
        #expect(!model.isMusicAuthorized)
    }

    @Test func lateMusicResultsPreserveKeyboardSelectionAndOpenMusic() async throws {
        let rows = [history("First"), history("Second")]
        let item = try song("123", title: "Song")
        let model = HistorySearchViewModel(historySearch: { _ in rows }, fileSearch: { _, done in done(.results([])) },
                                          cameraAvailable: { false }, musicSearch: { _ in
            try await Task.sleep(for: .milliseconds(120)); return [item]
        }, musicAuthorized: { true }, musicEnabled: { true })
        model.query = "Song"
        try await waitUntil { !model.results.isEmpty }
        model.moveSelection(by: 1)
        let selected = model.selectedID
        try await waitUntil { !model.isSearching }
        #expect(model.selectedID == selected)
        #expect(model.musicResults.map(\.id) == [item.id])
        var openedID: String?
        model.openMusic = { openedID = $0.id }
        model.moveSelection(by: 1)
        model.openSelected()
        #expect(openedID == item.id)
    }

    @Test func staleMusicResponseDoesNotReplaceNewQuery() async throws {
        let old = try song("old", title: "Old")
        let new = try song("new", title: "New")
        var startedOld = false
        let model = HistorySearchViewModel(historySearch: { _ in [] }, fileSearch: { _, done in done(.results([])) },
                                          cameraAvailable: { false }, musicSearch: { query in
            if query == "old" {
                startedOld = true
                // 模拟底层请求忽略取消、仍然返回旧结果。
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { continuation.resume() }
                }
                return [old]
            }
            return [new]
        }, musicAuthorized: { true }, musicEnabled: { true })
        model.query = "old"
        try await waitUntil { startedOld }
        model.query = "new"
        try await waitUntil { !model.isSearching }
        try await Task.sleep(for: .milliseconds(250))
        #expect(model.musicResults.map(\.id) == [new.id])
    }

    @Test func musicFailureDoesNotHideHistoryAndURLModeSkipsMusic() async throws {
        enum Failure: Error { case unavailable }
        let row = history("Note")
        var requests = 0
        let model = HistorySearchViewModel(historySearch: { _ in [row] }, fileSearch: { _, done in done(.results([])) },
                                          cameraAvailable: { false }, musicSearch: { _ in requests += 1; throw Failure.unavailable },
                                          musicAuthorized: { true }, musicEnabled: { true })
        model.query = "note"
        try await waitUntil { !model.isSearching }
        #expect(model.results == [row])
        #expect(model.musicError != nil)
        #expect(!model.showsOverallEmptyState)
        model.reset(mode: .url, initialQuery: "example.com")
        try await waitUntil { !model.isSearching }
        #expect(requests == 1)
        #expect(model.musicResults.isEmpty)
    }

    @Test func exposeMusicUsesCommonGridSelectionAndStableIdentity() async throws {
        let item = try song("expose", title: "Music Result")
        let model = FoilExposeModel(items: [], historyItems: [], fileSearch: { _, done in done(.results([])) },
                                    cameraAvailable: { false }, musicSearch: { _ in [item] },
                                    musicAuthorized: { true }, musicEnabled: { true })
        model.beginSearch()
        model.searchText = "Music"
        try await waitUntil { !model.isMusicSearching }
        let first = try #require(model.highlightedItem)
        #expect(first.musicItem?.id == item.id)
        #expect(!first.isNewFoil && !first.isHistoryEntry)
        model.setVisibleIDs([first.id])
        #expect(model.item(forKey: "1")?.musicItem?.id == item.id)
        var openedID: String?
        model.onSelect = { openedID = $0.musicItem?.id }
        model.onSelect(first)
        #expect(openedID == item.id)
        model.searchText = "Music Result"
        try await waitUntil { !model.isMusicSearching }
        #expect(model.highlightedItem?.id == first.id)
        model.searchText = ""
        #expect(model.musicItems.isEmpty && !model.showsMusicResults)
        model.stopFileSearch()
    }

    @Test func disablingMusicSearchCancelsBothSearchSurfacesAndRejectsLateResults() async throws {
        var enabled = true
        var requests = 0
        let item = try song("late", title: "Late Music")
        let search: @MainActor (String) async throws -> [AppleMusicLibraryItem] = { _ in
            requests += 1
            // 底层查询不响应取消时，也不能让关闭后的音乐结果重新出现。
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { continuation.resume() }
            }
            return [item]
        }
        let quick = HistorySearchViewModel(historySearch: { _ in [] }, fileSearch: { _, done in done(.results([])) },
                                          cameraAvailable: { false }, musicSearch: search,
                                          musicAuthorized: { true }, musicEnabled: { enabled })
        let expose = FoilExposeModel(items: [], historyItems: [], fileSearch: { _, done in done(.results([])) },
                                    cameraAvailable: { false }, musicSearch: search,
                                    musicAuthorized: { true }, musicEnabled: { enabled })
        quick.query = "music"
        expose.searchText = "music"
        try await waitUntil { requests == 2 }
        enabled = false
        NotificationCenter.default.post(name: .appleMusicSearchDidChange, object: nil)
        try await waitUntil { !quick.isMusicSearchEnabled && !expose.isMusicSearchEnabled }
        try await Task.sleep(for: .milliseconds(400))
        #expect(quick.musicResults.isEmpty && expose.musicItems.isEmpty)
        #expect(!quick.isMusicSearching && !expose.isMusicSearching)
        quick.query = "another"
        expose.searchText = "another"
        try await Task.sleep(for: .milliseconds(300))
        #expect(requests == 2)
        enabled = true
        NotificationCenter.default.post(name: .appleMusicSearchDidChange, object: nil)
        try await waitUntil { requests == 4 && !quick.isMusicSearching && !expose.isMusicSearching }
        #expect(quick.musicResults.map(\.id) == [item.id])
        #expect(expose.musicItems.first?.musicItem?.id == item.id)
        quick.stop()
        expose.stopFileSearch()
        NotificationCenter.default.post(name: .appleMusicSearchDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(requests == 4)
    }

    @Test func exposeSkipsUnauthorizedMusicAndRetainsFoilsWhenMusicFails() async throws {
        var authorized = false
        var requests = 0
        enum Failure: Error { case unavailable }
        let foil = FoilExposeItem(id: UUID(), controller: nil, isHistoryEntry: true, title: "Music Note",
                                 symbolName: "doc", contentKind: .text, thumbnailPath: nil)
        let model = FoilExposeModel(items: [], historyItems: [foil], fileSearch: { _, done in done(.results([])) },
                                    cameraAvailable: { false }, musicSearch: { _ in requests += 1; throw Failure.unavailable },
                                    musicAuthorized: { authorized }, musicEnabled: { true })
        model.searchText = "Music"
        #expect(!model.isMusicSearching && requests == 0)
        #expect(model.currentItems.map(\.id) == [foil.id])
        authorized = true
        NotificationCenter.default.post(name: .appleMusicSearchDidChange, object: nil)
        try await waitUntil { model.musicError != nil }
        #expect(requests == 1)
        #expect(model.currentItems.map(\.id) == [foil.id])
        model.stopFileSearch()
    }

    @Test func musicGroupsPrioritizeAlbumsLimitEachToSixAndExpandIndependently() async throws {
        let albums = try (0..<7).map { try album("album-\($0)") }
        let songs = try (0..<7).map { try song("song-\($0)", title: "Song \($0)") }
        // 服务先返回歌曲，展示层仍须把专辑放在前面；用户文件保持最前。
        let file = SpotlightFileResult(url: URL(fileURLWithPath: "/tmp/music.txt"), modifiedAt: Date())
        let quick = HistorySearchViewModel(historySearch: { _ in [] }, fileSearch: { _, done in done(.results([file])) },
                                          cameraAvailable: { false }, musicSearch: { _ in songs + albums },
                                          musicAuthorized: { true }, musicEnabled: { true })
        let expose = FoilExposeModel(items: [], historyItems: [], fileSearch: { _, done in done(.results([file])) },
                                    cameraAvailable: { false }, musicSearch: { _ in songs + albums },
                                    musicAuthorized: { true }, musicEnabled: { true })
        quick.query = "music"
        expose.searchText = "music"
        try await waitUntil { !quick.isSearching && !expose.isMusicSearching }
        #expect(quick.itemIDs.first == "file:\(file.id)")
        #expect(quick.visibleMusicResults.map(\.id) == albums.prefix(6).map(\.id) + songs.prefix(6).map(\.id))
        #expect(expose.currentItems.compactMap { $0.musicItem?.id } == quick.visibleMusicResults.map(\.id))
        #expect(!quick.itemIDs.contains("music:\(songs[6].id)"))
        // 高亮第一首歌曲后展开专辑，仍选中同一首歌曲，而非变成新加入的第七张专辑。
        quick.moveSelection(by: 7)
        expose.selectedIndex = 6
        let selected = expose.highlightedItem?.id
        quick.expandMusicResults(in: .albums)
        expose.expandMusicResults(in: .albums)
        #expect(quick.visibleMusicResults(in: .albums).count == 7)
        #expect(quick.visibleMusicResults(in: .songs).count == 6)
        #expect(quick.selectedID == "music:\(songs[0].id)")
        #expect(expose.highlightedItem?.id == selected)
        #expect(expose.highlightedItem?.musicItem?.id == songs[0].id)
        var opened: String?
        quick.openMusic = { opened = $0.id }
        quick.openSelected()
        #expect(opened == songs[0].id)
        quick.expandMusicResults(in: .songs)
        expose.expandMusicResults(in: .songs)
        #expect(quick.visibleMusicResults.count == 14 && expose.currentItems.count == 14)
        #expect(quick.itemIDs.contains("music:\(songs[6].id)"))
        quick.query = "new"
        expose.searchText = "new"
        try await waitUntil { !quick.isSearching && !expose.isMusicSearching }
        #expect(quick.expandedMusicCategories.isEmpty && expose.expandedMusicCategories.isEmpty)
        #expect(quick.visibleMusicResults.count == 12 && expose.currentItems.count == 12)
        quick.stop()
        expose.stopFileSearch()
    }

    @Test func resultBudgetCapsAllSourcesAndFiltersExpandByEighteen() async throws {
        let albums = try (0..<100).map { try album("album-\($0)") }
        let songs = try (0..<100).map { try song("song-\($0)", title: "Music Song \($0)") }
        let files = (0..<100).map { SpotlightFileResult(url: URL(fileURLWithPath: "/tmp/music-\($0).txt"), modifiedAt: Date()) }
        let notes = (0..<100).map { history("Music Note \($0)") }
        var musicRequests = 0
        let search: @MainActor (String) async throws -> [AppleMusicLibraryItem] = { _ in musicRequests += 1; return albums + songs }
        let quick = HistorySearchViewModel(historySearch: { _ in notes }, fileSearch: { _, done in done(.results(files)) },
                                          cameraAvailable: { false }, musicSearch: search,
                                          musicAuthorized: { true }, musicEnabled: { true })
        let foils = notes.map { FoilExposeItem(id: $0.id, controller: nil, isHistoryEntry: true, title: $0.title,
                                             symbolName: "doc", contentKind: .text, thumbnailPath: nil) }
        let expose = FoilExposeModel(items: [], historyItems: foils, fileSearch: { _, done in done(.results(files)) },
                                    cameraAvailable: { false }, musicSearch: search,
                                    musicAuthorized: { true }, musicEnabled: { true })
        quick.query = "music"
        expose.searchText = "music"
        try await waitUntil { !quick.isSearching && !expose.isMusicSearching }
        #expect(quick.resultCount == 60 && expose.displayedResultCount == 60)
        #expect(quick.showsResultLimitNotice && expose.showsResultLimitNotice)
        #expect(quick.files.count == 61 && expose.files.count == 61)
        #expect(quick.musicResults.count == 122 && expose.musicItems.count == 122)
        #expect(quick.visibleMusicResults(in: .albums).count == 6 && quick.visibleMusicResults(in: .songs).count == 6)
        quick.resultFilter = .albums
        expose.resultFilter = .albums
        try await waitUntil { !quick.isSearching && !expose.isMusicSearching }
        #expect(quick.resultCount == 6 && expose.displayedResultCount == 6)
        #expect(quick.visibleResults.isEmpty && quick.visibleFiles.isEmpty)
        #expect(quick.visibleMusicResults.allSatisfy { $0.searchCategory == .albums })
        for expected in [24, 42, 60] {
            quick.expandMusicResults(in: .albums)
            expose.expandMusicResults(in: .albums)
            #expect(quick.resultCount == expected && expose.displayedResultCount == expected)
        }
        #expect(quick.showsResultLimitNotice && expose.showsResultLimitNotice)
        #expect(!quick.canExpandMusicResults(in: .albums) && !expose.canExpandMusicResults(in: .albums))
        quick.expandMusicResults(in: .albums)
        expose.expandMusicResults(in: .albums)
        #expect(quick.resultCount == 60 && expose.displayedResultCount == 60)
        quick.resultFilter = .songs
        expose.resultFilter = .songs
        try await waitUntil { !quick.isSearching && !expose.isMusicSearching }
        #expect(quick.resultCount == 6 && quick.visibleMusicResults.allSatisfy { $0.searchCategory == .songs })
        let requestsBeforeFiles = musicRequests
        quick.resultFilter = .files
        expose.resultFilter = .files
        try await waitUntil { !quick.isSearching && !expose.isFileSearching }
        #expect(musicRequests == requestsBeforeFiles)
        #expect(quick.resultCount == 60 && expose.displayedResultCount == 60)
        #expect(quick.musicResults.isEmpty && expose.musicItems.isEmpty)
        quick.stop()
        expose.stopFileSearch()
    }

    @Test func exactlySixtyMatchesDoNotClaimMoreResultsExist() async throws {
        let files = (0..<60).map { SpotlightFileResult(url: URL(fileURLWithPath: "/tmp/exact-\($0).txt"), modifiedAt: Date()) }
        let albums = try (0..<60).map { try album("exact-\($0)") }
        let quick = HistorySearchViewModel(historySearch: { _ in [] }, fileSearch: { _, done in done(.results(files)) },
                                          cameraAvailable: { false }, musicSearch: { _ in albums },
                                          musicAuthorized: { true }, musicEnabled: { true })
        let expose = FoilExposeModel(items: [], historyItems: [], fileSearch: { _, done in done(.results(files)) },
                                    cameraAvailable: { false }, musicSearch: { _ in albums },
                                    musicAuthorized: { true }, musicEnabled: { true })
        quick.query = "exact"
        expose.searchText = "exact"
        quick.resultFilter = .files
        expose.resultFilter = .files
        try await waitUntil { !quick.isSearching && !expose.isFileSearching }
        #expect(quick.resultCount == 60 && expose.displayedResultCount == 60)
        #expect(!quick.showsResultLimitNotice && !expose.showsResultLimitNotice)
        quick.resultFilter = .albums
        expose.resultFilter = .albums
        try await waitUntil { !quick.isSearching && !expose.isMusicSearching }
        for _ in 0..<3 {
            quick.expandMusicResults(in: .albums)
            expose.expandMusicResults(in: .albums)
        }
        #expect(quick.resultCount == 60 && expose.displayedResultCount == 60)
        #expect(!quick.showsResultLimitNotice && !expose.showsResultLimitNotice)
        quick.stop()
        expose.stopFileSearch()
    }
}
