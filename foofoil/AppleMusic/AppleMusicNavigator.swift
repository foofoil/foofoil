import Foundation
import FoofoilExtensionKit
import MusicKit

/// Apple Music 只投影到通用导航模型；曲目不是磁盘文件，不创建 FileList 的伪路径。
@MainActor
enum AppleMusicNavigator {
    static let contributionID = "builtin.apple-music-queue"

    /// 队列准备、切专辑及自然续播都以播放器的实际队列为准；未变化时不重复发布。
    static func synchronizing(entries: [MusicKit.MusicPlayer.Queue.Entry], currentEntryID: String?, with original: NavigatorContribution?) -> NavigatorContribution? {
        guard let original, original.items.map(\.id) == entries.map(\.id) else {
            return contribution(entries: entries, currentEntryID: currentEntryID)
        }
        return original.selectedItemIDs.first == currentEntryID ? original : selecting(currentEntryID, in: original)
    }

    static func contribution(entries: [MusicKit.MusicPlayer.Queue.Entry], currentEntryID: String?) -> NavigatorContribution? {
        guard !entries.isEmpty else { return nil }
        let items = entries.map { entry in
            let duration: Double?
            switch entry.item {
            case .song(let song): duration = song.duration
            case .musicVideo(let video): duration = video.duration
            case nil: duration = nil
            @unknown default: duration = nil
            }
            return NavigatorItem(
                id: entry.id,
                title: entry.title,
                subtitle: entry.subtitle,
                symbolName: "music.note",
                badge: duration.map { VideoPlayerController.formatPlaybackTime($0) },
                isCurrent: entry.id == currentEntryID
            )
        }
        return NavigatorContribution(
            id: contributionID,
            titleLocalizationKey: "Music Queue",
            style: .flat,
            items: items,
            selectedItemIDs: items.filter(\.isCurrent).map(\.id),
            allowedActions: [.activate]
        )
    }

    static func selecting(_ currentEntryID: String?, in original: NavigatorContribution) -> NavigatorContribution {
        var contribution = original
        for index in contribution.items.indices {
            contribution.items[index].isCurrent = contribution.items[index].id == currentEntryID
        }
        contribution.selectedItemIDs = contribution.items.filter(\.isCurrent).map(\.id)
        contribution.revision &+= 1
        return contribution
    }
}

extension AppState {
    func synchronizeAppleMusicNavigator(_ contribution: NavigatorContribution?, activate: @escaping (String) -> Void) {
        guard appleMusicItem != nil else { return }
        guard let contribution else {
            clearAppleMusicNavigator()
            return
        }
        builtInNavigatorContributions = [contribution]
        builtInNavigatorActionHandler = { action in
            guard action.kind == .activate, let id = action.itemIDs.first else { return }
            activate(id)
        }
        if activeNavigatorContributionID != contribution.id {
            endNavigatorSearch()
            activeNavigatorContributionID = contribution.id
        }
    }

    func clearAppleMusicNavigator() {
        guard builtInNavigatorContributions.contains(where: { $0.id == AppleMusicNavigator.contributionID }) else { return }
        builtInNavigatorContributions.removeAll { $0.id == AppleMusicNavigator.contributionID }
        builtInNavigatorActionHandler = nil
        if activeNavigatorContributionID == AppleMusicNavigator.contributionID {
            activeNavigatorContributionID = nil
            endNavigatorSearch()
        }
    }

    var hasAppleMusicItemNavigation: Bool {
        appleMusicItem != nil && (builtInNavigatorContributions.first {
            $0.id == AppleMusicNavigator.contributionID
        }?.items.count ?? 0) > 1
    }

    /// 通用上一项/下一项命令按展示顺序选曲；自然续播与随机播放仍由 MusicKit 管理。
    func activateAdjacentAppleMusicItem(delta: Int, wraps: Bool) {
        guard let contribution = builtInNavigatorContributions.first(where: { $0.id == AppleMusicNavigator.contributionID }),
              let currentID = contribution.selectedItemIDs.first,
              let index = contribution.items.firstIndex(where: { $0.id == currentID }) else { return }
        let count = contribution.items.count
        let next = wraps ? ((index + delta) % count + count) % count : index + delta
        guard contribution.items.indices.contains(next) else { return }
        performNavigatorAction(.init(contributionID: contribution.id, kind: .activate, itemIDs: [contribution.items[next].id]))
    }
}
