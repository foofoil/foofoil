import Foundation
import FoofoilExtensionKit

extension HiFiLegacyAdapter {
    /// 暂时保留旧 Runtime 以修改后的快照接收导航操作的约定。
    static func navigatorRequest(
        action navigatorAction: NavigatorAction, session: ContentSession
    ) -> (commandID: String, session: ContentSession)? {
        guard let index = session.navigatorContributions.firstIndex(where: {
            $0.id == navigatorAction.contributionID
        }) else {
            return nil
        }
        var requested = session
        let commandID: String
        switch navigatorAction.kind {
        case .activate:
            guard let selectedID = navigatorAction.itemIDs.first else { return nil }
            requested.navigatorContributions[index].selectedItemIDs = [selectedID]
            commandID = HiFiLegacyAdapter.Command.activate.rawValue
        case .move:
            requested.navigatorContributions[index].items = Self.movingItems(
                requested.navigatorContributions[index].items,
                action: navigatorAction
            )
            commandID = HiFiLegacyAdapter.Command.move.rawValue
        case .remove:
            return nil
        }
        return (commandID, requested)
    }

    private static func movingItems(
        _ items: [NavigatorItem],
        action: NavigatorAction
    ) -> [NavigatorItem] {
        guard let position = action.movePosition else { return items }
        let movingIDs = Set(action.itemIDs)
        let moving = items.filter { movingIDs.contains($0.id) }
        guard moving.count == movingIDs.count else { return items }
        var remaining = items.filter { !movingIDs.contains($0.id) }
        let insertionIndex: Int
        switch position {
        case .end:
            insertionIndex = remaining.endIndex
        case .before, .after:
            guard let destinationID = action.destinationItemID,
                  let destinationIndex = remaining.firstIndex(where: { $0.id == destinationID }) else {
                return items
            }
            insertionIndex = position == .before
                ? destinationIndex
                : remaining.index(after: destinationIndex)
        }
        remaining.insert(contentsOf: moving, at: insertionIndex)
        return remaining
    }
}
