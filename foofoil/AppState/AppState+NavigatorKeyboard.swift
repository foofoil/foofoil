import AppKit
import FoofoilExtensionKit

extension AppState {
    /// 目录键只处理已展开的可见行，不因上下移动读取尚未展开的内层包。
    func visibleNavigatorItems(in contribution: NavigatorContribution) -> [NavigatorItem] {
        guard contribution.style == .outline else { return contribution.items }
        let children = Dictionary(grouping: contribution.items, by: \.parentID)
        var result: [NavigatorItem] = []
        var stack = Array((children[nil] ?? []).reversed())
        var seen = Set<String>()
        while let item = stack.popLast(), seen.insert(item.id).inserted {
            result.append(item)
            if expandedNavigatorItemIDs.contains(item.id) {
                stack.append(contentsOf: (children[item.id] ?? []).reversed())
            }
        }
        return result
    }

    @discardableResult
    func handleNavigatorKeyDown(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, isNavigatorFocused else { return false }
        if handleNavigatorSearchKey(event) { return true }
        guard !isNavigatorSearchActive,
              KeyboardShortcut.effectiveModifiers(for: event).isEmpty,
              [123, 124, 125, 126, 36, 76, 49].contains(event.keyCode),
              !((NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable ?? false),
              let contribution = activeNavigatorContribution else { return false }
        if archiveSession(forNavigatorID: contribution.id) != nil {
            let handled = handleArchiveTreeKeyDown(event)
            navigatorFocusedItemID = activeNavigatorContribution?.selectedItemIDs.first
            return handled
        }
        let rows = visibleNavigatorItems(in: contribution)
        guard !rows.isEmpty else { return false }
        let selected = navigatorFocusedItemID.flatMap { id in rows.first { $0.id == id } }
            ?? rows.first { contribution.selectedItemIDs.contains($0.id) }
        let children = Dictionary(grouping: contribution.items, by: \.parentID)
        func activate(_ item: NavigatorItem) {
            navigatorFocusedItemID = item.id
            guard item.isEnabled, contribution.allowedActions.contains(.activate) else { return }
            // 文件列表分组行只移动树游标，不能把分组 ID 当作一个文件打开。
            if contribution.id == Self.fileListNavigatorID, children[item.id] != nil { return }
            performNavigatorAction(.init(contributionID: contribution.id, kind: .activate, itemIDs: [item.id]))
        }
        switch event.keyCode {
        case 125, 126:
            let index = selected.flatMap { selected in rows.firstIndex { $0.id == selected.id } }
            let next = index.map { $0 + (event.keyCode == 125 ? 1 : -1) } ?? (event.keyCode == 125 ? 0 : rows.count - 1)
            if rows.indices.contains(next) { activate(rows[next]) }
        case 123:
            if let selected {
                if expandedNavigatorItemIDs.contains(selected.id) { expandedNavigatorItemIDs.remove(selected.id) }
                else if let parent = rows.first(where: { $0.id == selected.parentID }) { activate(parent) }
            }
        case 124, 36, 76:
            if let selected {
                if let first = children[selected.id]?.first {
                    if expandedNavigatorItemIDs.contains(selected.id) { activate(first) }
                    else { expandedNavigatorItemIDs.insert(selected.id) }
                } else if event.keyCode != 124 { activate(selected) }
            }
        default:
            if let selected { activate(selected) }
        }
        return true
    }
}
