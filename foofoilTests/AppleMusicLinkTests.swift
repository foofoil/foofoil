import Foundation
import MusicKit
import Testing
@testable import foofoil

@MainActor
@Suite(.serialized)
struct AppleMusicLinkTests {
    @Test(arguments: [
        ("https://music.apple.com/cn/album/name/123?i=456&ls=1", AppleMusicReference.Kind.song, "456"),
        ("https://music.apple.com/us/song/title/456", .song, "456"),
        ("https://music.apple.com/cn/album/%E4%B8%93%E8%BE%91/123", .album, "123"),
        ("https://music.apple.com/album/123", .album, "123"),
        ("https://music.apple.com/us/playlist/name/pl.u-abc123", .playlist, "pl.u-abc123"),
        ("https://music.apple.com/cn/playlist/name/pl.abc123?l=en", .playlist, "pl.abc123")
    ])
    func recognizesContentIdentity(value: (String, AppleMusicReference.Kind, String)) throws {
        let link = try #require(AppleMusicLink(url: URL(string: value.0)!))
        #expect(link.kind == value.1 && link.id == value.2)
        #expect(ClipboardOpenableContent.forText(declaredMarkdown: nil, plainText: value.0, html: nil)?.kind == .appleMusic)
    }

    @Test(arguments: [
        "https://music.apple.com.evil.test/cn/album/name/123",
        "https://example.com/album/name/123",
        "https://music.apple.com/cn/artist/name/123",
        "https://music.apple.com/cn/album/name/123?i=not-a-song",
        "https://music.apple.com/cn/album/name/abc",
        "https://music.apple.com/cn/playlist/name/123",
        "https://music.apple.com/cn/album/name/123/extra",
        "https://user@music.apple.com/cn/album/name/123"
    ])
    func rejectsUnrelatedOrMalformedURLs(value: String) {
        #expect(AppleMusicLink(url: URL(string: value)!) == nil)
    }

    private func catalogSong() throws -> AppleMusicLibraryItem {
        let data = Data(#"{"id":"456","type":"songs","attributes":{"name":"Shared Song","artistName":"Artist","albumName":"Album"}}"#.utf8)
        var item = AppleMusicLibraryItem.song(try JSONDecoder().decode(Song.self, from: data))
        item.source = .catalog
        return item
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func explicitLinkBypassesSearchSettingAndOpensResolvedMusic() async throws {
        let song = try catalogSong()
        var unrelatedSearches = 0
        let model = HistorySearchViewModel(historySearch: { _ in unrelatedSearches += 1; return [] },
            fileSearch: { _, done in unrelatedSearches += 1; done(.results([])) }, cameraAvailable: { false },
            musicSearch: { _ in unrelatedSearches += 1; return [] }, resolveMusicLink: { link in
                #expect(link.kind == .song && link.id == "456")
                return song
            }, musicAuthorized: { true }, musicEnabled: { false }, musicLibraryEnabled: { true })
        model.query = "https://music.apple.com/cn/album/title/123?i=456"
        try await waitUntil { !model.isSearching }
        #expect(unrelatedSearches == 0 && model.openURL == nil && model.resultCount == 1)
        #expect(model.linkedMusicItem?.reference == song.reference)
        var opened: AppleMusicReference?
        model.openMusic = { opened = $0.reference }
        model.openSelected()
        #expect(opened == song.reference)
        model.stop()
    }

    @Test func unauthorizedLinkCanBeOpenedForAuthorizationAndFailuresRemainMusic() async throws {
        let url = URL(string: "https://music.apple.com/us/song/name/456")!
        let model = HistorySearchViewModel(historySearch: { _ in [] }, fileSearch: { _, done in done(.results([])) },
            cameraAvailable: { false }, resolveMusicLink: { _ in throw CatalogLinkError.unavailable },
            musicAuthorized: { false }, musicEnabled: { false }, musicLibraryEnabled: { true })
        model.query = url.absoluteString
        #expect(model.resultCount == 1 && !model.showsOverallEmptyState && model.openURL == nil)
        var opened: URL?
        model.openMusicLink = { opened = $0 }
        model.openSelected()
        #expect(opened == url)
        model.stop()
        let authorized = HistorySearchViewModel(historySearch: { _ in [] }, fileSearch: { _, done in done(.results([])) },
            cameraAvailable: { false }, resolveMusicLink: { _ in throw CatalogLinkError.unavailable },
            musicAuthorized: { true }, musicEnabled: { false }, musicLibraryEnabled: { true })
        authorized.query = url.absoluteString
        try await waitUntil { !authorized.isSearching }
        #expect(authorized.musicLinkError != nil && authorized.openURL == nil)
        authorized.stop()
    }

    @Test func staleResolutionCannotOverwriteNewQuery() async throws {
        let song = try catalogSong()
        var continuation: CheckedContinuation<AppleMusicLibraryItem, Never>?
        let model = HistorySearchViewModel(historySearch: { _ in [] }, fileSearch: { _, done in done(.results([])) },
            cameraAvailable: { false }, resolveMusicLink: { _ in
                await withCheckedContinuation { continuation = $0 }
            }, musicAuthorized: { true }, musicEnabled: { false }, musicLibraryEnabled: { true })
        model.query = "https://music.apple.com/us/song/name/456"
        try await waitUntil { continuation != nil }
        model.query = "https://example.com"
        continuation?.resume(returning: song)
        try await waitUntil { !model.isSearching }
        #expect(model.musicLink == nil && model.linkedMusicItem == nil)
        #expect(model.openURL?.host == "example.com")
        model.stop()
    }

    @Test func catalogSourceSurvivesHistoryAndRestoration() async throws {
        let song = try catalogSong()
        let config = WindowConfig(id: UUID(), sourceFingerprint: song.reference.sourceFingerprint, appleMusicReference: song.reference)
        let decoded = try JSONDecoder().decode(WindowConfig.self, from: JSONEncoder().encode(config))
        let state = AppState(config: decoded)
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }
        await state.restoreAppleMusicItem { reference in
            #expect(reference.source == .catalog && reference.id == "456")
            return song
        }
        #expect(state.appleMusicItem?.reference == song.reference)
        #expect(state.sourceFingerprint == "apple-music:catalog:song:456")
    }
    @Test func disabledLibraryTreatsMusicLinkAsOrdinaryWebsite() async throws {
        let url = URL(string: "https://music.apple.com/us/song/name/456")!
        var resolutions = 0
        let model = HistorySearchViewModel(historySearch: { _ in [] }, fileSearch: { _, done in done(.results([])) },
            cameraAvailable: { false }, resolveMusicLink: { _ in
                resolutions += 1
                throw CatalogLinkError.unavailable
            }, musicAuthorized: { true }, musicEnabled: { false }, musicLibraryEnabled: { false })
        model.query = url.absoluteString
        try await waitUntil { !model.isSearching }
        #expect(model.musicLink == nil)
        #expect(model.linkedMusicItem == nil)
        #expect(model.openURL == url)
        #expect(resolutions == 0)
        model.stop()
        #expect(ClipboardOpenableContent.forText(declaredMarkdown: nil, plainText: url.absoluteString, html: nil,
                                               appleMusicEnabled: false)?.kind == .website)
    }

}
