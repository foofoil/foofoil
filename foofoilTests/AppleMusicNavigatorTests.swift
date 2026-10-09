import Foundation
import FoofoilExtensionKit
import MusicKit
import Testing
@testable import foofoil

@MainActor
struct AppleMusicNavigatorTests {
    private func song(_ id: String, title: String) throws -> Song {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "type": "library-songs", "attributes": [
                "name": title, "artistName": "Artist", "albumName": "Album", "durationInMillis": 180000
            ]
        ])
        return try JSONDecoder().decode(Song.self, from: data)
    }

    @Test func duplicateSongsHaveSeparateQueueRowsAndSelections() throws {
        let song = try song("same-song", title: "Repeated Song")
        let entries = [MusicKit.MusicPlayer.Queue.Entry(song), MusicKit.MusicPlayer.Queue.Entry(song)]
        let first = try #require(AppleMusicNavigator.contribution(entries: entries, currentEntryID: entries[0].id))
        #expect(first.items.count == 2)
        #expect(first.items[0].id != first.items[1].id)
        #expect(first.items.allSatisfy { $0.title == song.title && $0.subtitle == "Artist" && $0.badge == "3:00" })
        try NavigatorContributionValidator.validate(first)
        let next = AppleMusicNavigator.selecting(entries[1].id, in: first)
        #expect(next.items.map(\.id) == first.items.map(\.id))
        #expect(next.selectedItemIDs == [entries[1].id])
        #expect(next.items.map(\.isCurrent) == [false, true])
        try NavigatorContributionValidator.validate(next)
    }

    @Test func commonNavigationRoutesByQueueIDAndClearsOnContentChange() throws {
        let song = try song("same-song", title: "Repeated Song")
        let entries = [MusicKit.MusicPlayer.Queue.Entry(song), MusicKit.MusicPlayer.Queue.Entry(song)]
        let contribution = try #require(AppleMusicNavigator.contribution(entries: entries, currentEntryID: entries[0].id))
        let state = AppState()
        state.appleMusicItem = .song(song)
        var activated: [String] = []
        state.synchronizeAppleMusicNavigator(contribution) { activated.append($0) }
        #expect(state.supportsItemNavigation)
        state.activateAdjacentFileListItem(delta: -1)
        #expect(activated.isEmpty)
        state.activateAdjacentFileListItem(delta: 1)
        #expect(activated == [entries[1].id])
        state.activateAdjacentFileListItem(delta: -1, wraps: true)
        #expect(activated == [entries[1].id, entries[1].id])
        // 当前项切换只刷新选择，不改变面板位置、显示模式或曲目身份。
        state.isNavigatorPanelExplicitlyVisible = true
        state.synchronizeAppleMusicNavigator(AppleMusicNavigator.selecting(entries[1].id, in: contribution)) { activated.append($0) }
        #expect(state.isNavigatorPanelExplicitlyVisible)
        #expect(state.activeNavigatorContribution?.selectedItemIDs == [entries[1].id])
        state.appleMusicItem = nil
        #expect(state.navigatorContributions.isEmpty)
        #expect(!state.supportsItemNavigation)
        state.performNavigatorAction(.init(contributionID: contribution.id, kind: .activate, itemIDs: [entries[0].id]))
        #expect(activated.count == 2)
    }

    @Test func emptyAndSingleQueuesUseValidNavigationContracts() throws {
        #expect(AppleMusicNavigator.contribution(entries: [], currentEntryID: nil) == nil)
        let song = try song("single", title: "One Song")
        let entry = MusicKit.MusicPlayer.Queue.Entry(song)
        let contribution = try #require(AppleMusicNavigator.contribution(entries: [entry], currentEntryID: "missing"))
        #expect(contribution.selectedItemIDs.isEmpty)
        #expect(contribution.allowedActions == [.activate])
        try NavigatorContributionValidator.validate(contribution)
        let state = AppState()
        state.appleMusicItem = .song(song)
        state.synchronizeAppleMusicNavigator(contribution) { _ in }
        #expect(!state.supportsItemNavigation)
        #expect(!state.canSearchActiveNavigator)
    }

    @Test func allCommonPlaybackModesMapToMusicKit() {
        let sequential = AppleMusicPlaybackController.playbackSettings(for: .sequential)
        #expect(sequential.repeatMode == .none && sequential.shuffleMode == .off)
        let loop = AppleMusicPlaybackController.playbackSettings(for: .sequentialLoop)
        #expect(loop.repeatMode == .all && loop.shuffleMode == .off)
        let shuffle = AppleMusicPlaybackController.playbackSettings(for: .shuffle)
        #expect(shuffle.repeatMode == .all && shuffle.shuffleMode == .songs)
        let one = AppleMusicPlaybackController.playbackSettings(for: .singleLoop)
        #expect(one.repeatMode == .one && one.shuffleMode == .off)
    }

    @Test func preparedQueueReplacesPreviousAlbumAndTracksLateArrival() throws {
        let previous = MusicKit.MusicPlayer.Queue.Entry(try song("previous", title: "Previous Album"))
        let first = MusicKit.MusicPlayer.Queue.Entry(try song("first", title: "New Album One"))
        let second = MusicKit.MusicPlayer.Queue.Entry(try song("second", title: "New Album Two"))
        let old = try #require(AppleMusicNavigator.contribution(entries: [previous], currentEntryID: previous.id))
        let ready = try #require(AppleMusicNavigator.synchronizing(entries: [first, second], currentEntryID: first.id, with: old))
        #expect(ready.items.map(\.id) == [first.id, second.id])
        #expect(ready.selectedItemIDs == [first.id])
        #expect(AppleMusicNavigator.synchronizing(entries: [first, second], currentEntryID: first.id, with: ready) == ready)
        let advanced = try #require(AppleMusicNavigator.synchronizing(entries: [first, second], currentEntryID: second.id, with: ready))
        #expect(advanced.selectedItemIDs == [second.id])
        #expect(AppleMusicNavigator.synchronizing(entries: [], currentEntryID: nil, with: ready) == nil)
        #expect(AppleMusicNavigator.synchronizing(entries: [first, second], currentEntryID: first.id, with: nil) == ready)
    }
}
