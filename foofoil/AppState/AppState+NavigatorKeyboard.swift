import AppKit
import FoofoilExtensionKit

extension AppState {
    func isCurrentNavigatorMedia(contributionID: String, itemID: String) -> Bool {
        if let archive = archiveSession(forNavigatorID: contributionID) {
            return archive.selectedID == itemID && archive.isMediaEntry(itemID)
        }
        if contributionID == AppleMusicNavigator.contributionID {
            return activeNavigatorContribution?.selectedItemIDs.contains(itemID) == true
        }
        guard let list = readingState.fileList, list.kind == .audio || list.kind == .video,
              let item = navigatorFileItem(contributionID: contributionID, itemID: itemID) else { return false }
        return list.currentID == item.id
    }

    /// 对媒体行统一路由播放请求；切换到其他文件时先恢复自动播放意图。
    @discardableResult
    func performNavigatorMediaPlayback(contributionID: String, itemID: String, toggle: Bool) -> Bool {
        if let archive = archiveSession(forNavigatorID: contributionID) {
            guard archive.isMediaEntry(itemID) else { return false }
            if archive.selectedID != itemID || (archive.preview == nil && !archive.busy) {
                archive.selectNavigatorItem(itemID)
                return true
            }
            if archive.preview == nil && archive.busy {
                archive.requestPendingMediaPlayback(toggle: toggle)
                return true
            }
            guard let preview = archive.preview?.readingState else { return true }
            if !preview.isExternalMediaDocument {
                setPendingNavigatorPlayback(on: preview, toggle: toggle)
                return true
            }
            requestNavigatorPlayback(on: preview, toggle: toggle)
            return true
        }
        if contributionID == AppleMusicNavigator.contributionID,
           let contribution = navigatorContributions.first(where: { $0.id == contributionID }),
           contribution.items.contains(where: { $0.id == itemID }) {
            if contribution.selectedItemIDs.contains(itemID) {
                let state = readingState
                if toggle || !state.isMediaPlaying {
                    NotificationCenter.default.post(name: .shouldToggleVideoPlayback, object: nil, userInfo: ["id": state.id])
                }
            } else {
                performNavigatorAction(.init(contributionID: contributionID, kind: .activate, itemIDs: [itemID]))
            }
            return true
        }
        guard let list = readingState.fileList, list.kind == .audio || list.kind == .video,
              let item = navigatorFileItem(contributionID: contributionID, itemID: itemID) else { return false }
        let state = readingState
        if list.currentID != item.id {
            state.noteUserStartedMediaPlayback()
            performNavigatorAction(.init(contributionID: contributionID, kind: .activate, itemIDs: [itemID]))
        } else {
            requestNavigatorPlayback(on: state, toggle: toggle)
        }
        return true
    }

    private func requestNavigatorPlayback(on state: AppState, toggle: Bool) {
        if state.isLoading {
            setPendingNavigatorPlayback(on: state, toggle: toggle)
            return
        }
        if !toggle {
            state.noteUserStartedMediaPlayback()
        }
        if toggle || !state.isMediaPlaying {
            NotificationCenter.default.post(name: .shouldToggleVideoPlayback, object: nil, userInfo: ["id": state.id])
        }
    }

    private func setPendingNavigatorPlayback(on state: AppState, toggle: Bool) {
        if toggle && state.resumesMediaPlaybackOnActivation { state.noteUserPausedMediaPlayback() }
        else { state.noteUserStartedMediaPlayback() }
    }

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
        if !isNavigatorSearchActive, let contribution = activeNavigatorContribution,
           contribution.id == PDFNavigator.pagesID,
           !((NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable ?? false) {
            return handlePDFThumbnailKeyDown(event, contribution: contribution)
        }
        guard !isNavigatorSearchActive,
              KeyboardShortcut.effectiveModifiers(for: event).isEmpty,
              [123, 124, 125, 126, 36, 76, 49].contains(event.keyCode),
              !((NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable ?? false),
              let contribution = activeNavigatorContribution else { return false }
        if [36, 76, 49].contains(event.keyCode),
           let id = navigatorFocusedItemID ?? contribution.selectedItemIDs.first,
           contribution.items.contains(where: { $0.id == id && $0.isEnabled }) {
            if event.isARepeat {
                let kind = readingState.fileList?.kind
                if contribution.id == AppleMusicNavigator.contributionID || archiveSession(forNavigatorID: contribution.id)?.isMediaEntry(id) == true ||
                    ((kind == .audio || kind == .video) && navigatorFileItem(contributionID: contribution.id, itemID: id) != nil) { return true }
            } else if performNavigatorMediaPlayback(contributionID: contribution.id, itemID: id, toggle: true) {
                return true
            }
        }
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

    private func handlePDFThumbnailKeyDown(_ event: NSEvent, contribution: NavigatorContribution) -> Bool {
        let modifiers = KeyboardShortcut.effectiveModifiers(for: event)
        let key: UInt16
        if modifiers.isEmpty { key = event.keyCode }
        else if modifiers == .control {
            switch event.keyCode {
            case 3: key = 124  // Ctrl-F
            case 11: key = 123 // Ctrl-B
            case 35: key = 126 // Ctrl-P
            case 45: key = 125 // Ctrl-N
            default: return false
            }
        } else { return false }
        let items = contribution.items
        guard !items.isEmpty else { return false }
        let selectedID = navigatorFocusedItemID ?? contribution.selectedItemIDs.first
        let index = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        if [36, 76, 49].contains(key) {
            let item = items[index]
            if item.isEnabled, contribution.allowedActions.contains(.activate) {
                performNavigatorAction(.init(contributionID: contribution.id, kind: .activate, itemIDs: [item.id]))
            }
            return true
        }
        let next: Int
        switch key {
        case 123: next = index - 1
        case 124: next = index + 1
        case 126: next = index - max(1, pdfThumbnailColumnCount)
        case 125: next = index + max(1, pdfThumbnailColumnCount)
        default: return false
        }
        if items.indices.contains(next) {
            let item = items[next]
            navigatorFocusedItemID = item.id
            if item.isEnabled, contribution.allowedActions.contains(.activate) {
                performNavigatorAction(.init(contributionID: contribution.id, kind: .activate, itemIDs: [item.id]))
            }
        }
        return true
    }
}
