//
//  AppState+NavigatorSearch.swift
//  foofoil
//
//  Created by tolg on 2026/9/13.
//

import AppKit
import Foundation
import FoofoilExtensionKit

/// 导航列表的查找定位：只对当前正在展示的贡献生效，状态仅存在于当前会话。
extension AppState {
    /// 列表项超过该数量才提供查找定位；与导航面板搜索按钮显隐保持一致。
    static let navigatorSearchMinimumItemCount = 12

    /// 当前导航面板正在展示的贡献；多贡献时以选择器选择为准。
    var activeNavigatorContribution: NavigatorContribution? {
        if let id = activeNavigatorContributionID,
           let contribution = navigatorContributions.first(where: { $0.id == id }) {
            return contribution
        }
        return navigatorContributions.first
    }

    var canSearchActiveNavigator: Bool {
        isNavigatorSearchActive
            || (activeNavigatorContribution?.items.count ?? 0) > Self.navigatorSearchMinimumItemCount
    }

    /// 非空关键字在标题中的匹配（忽略大小写与变音符号）。
    nonisolated static func navigatorSearchMatches(_ title: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        return title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// 按列表展示顺序返回匹配项 ID；空关键字或没有列表时为空。
    func navigatorSearchMatchIDs() -> [String] {
        guard isNavigatorSearchActive, let contribution = activeNavigatorContribution else { return [] }
        let query = navigatorSearchQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return contribution.items
            .filter { Self.navigatorSearchMatches($0.title, query: query) }
            .map(\.id)
    }

    /// 进入搜索并聚焦输入框；没有可搜索列表时不改变状态。
    func beginNavigatorSearch() {
        guard (activeNavigatorContribution?.items.count ?? 0) > Self.navigatorSearchMinimumItemCount else { return }
        isNavigatorSearchActive = true
        navigatorSearchFocusRequest &+= 1
    }

    /// ⌘F：未进入搜索时先进入，已进入时把焦点移回输入框。
    func focusNavigatorSearch() {
        if isNavigatorSearchActive {
            navigatorSearchFocusRequest &+= 1
        } else {
            beginNavigatorSearch()
        }
    }

    func endNavigatorSearch() {
        isNavigatorSearchActive = false
        navigatorSearchQuery = ""
        navigatorSearchCurrentMatchID = nil
    }

    /// 关键字变化后清除当前定位；匹配高亮由视图按当前关键字实时计算。
    func navigatorSearchQueryDidChange() {
        guard isNavigatorSearchActive else { return }
        navigatorSearchCurrentMatchID = nil
    }

    /// 下一个/上一个匹配，按匹配列表循环；没有匹配时清空定位。
    func advanceNavigatorSearchMatch(delta: Int) {
        let matches = navigatorSearchMatchIDs()
        guard !matches.isEmpty else {
            navigatorSearchCurrentMatchID = nil
            return
        }
        let index: Int
        if let current = navigatorSearchCurrentMatchID,
           let currentIndex = matches.firstIndex(of: current) {
            index = ((currentIndex + delta) % matches.count + matches.count) % matches.count
        } else {
            index = delta >= 0 ? 0 : matches.count - 1
        }
        navigateToNavigatorSearchMatch(matches[index])
    }

    /// 折叠分段内的匹配要先展开父级，滚动定位才能命中真实行。
    private func navigateToNavigatorSearchMatch(_ id: String) {
        if let item = activeNavigatorContribution?.items.first(where: { $0.id == id }),
           let parentID = item.parentID,
           !expandedNavigatorItemIDs.contains(parentID) {
            expandedNavigatorItemIDs.insert(parentID)
        }
        navigatorSearchCurrentMatchID = id
    }

    /// 回车打开当前定位项：目录行（含子项）展开/收起，曲目与文件走各自激活行为。
    /// 尚未定位时从第一个匹配开始，行为与“下一个”一致。
    func openNavigatorSearchMatch() {
        let matches = navigatorSearchMatchIDs()
        guard !matches.isEmpty else { return }
        let target = navigatorSearchCurrentMatchID.flatMap { matches.contains($0) ? $0 : nil }
            ?? matches[0]
        if navigatorSearchCurrentMatchID != target {
            navigateToNavigatorSearchMatch(target)
        }
        openNavigatorSearchMatchItem(id: target)
    }

    private func openNavigatorSearchMatchItem(id: String) {
        guard let contribution = activeNavigatorContribution,
              let item = contribution.items.first(where: { $0.id == id }),
              item.isEnabled else { return }
        let isDirectory = contribution.items.contains(where: { $0.parentID == id })
        if isDirectory {
            if expandedNavigatorItemIDs.contains(id) {
                expandedNavigatorItemIDs.remove(id)
            } else {
                expandedNavigatorItemIDs.insert(id)
            }
            return
        }
        performNavigatorAction(
            NavigatorAction(contributionID: contribution.id, kind: .activate, itemIDs: [id])
        )
    }

    /// ⌘F 进入/聚焦搜索，⌘G 下一个，⇧⌘G 上一个；由窗口与面板在菜单匹配前调用。
    @discardableResult
    func handleNavigatorSearchKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if modifiers == .command, key == "f" {
            guard canSearchActiveNavigator else { return false }
            focusNavigatorSearch()
            return true
        }
        guard isNavigatorSearchActive else { return false }
        if modifiers == .command, key == "g" {
            advanceNavigatorSearchMatch(delta: 1)
            return true
        }
        if modifiers == [.command, .shift], key == "g" {
            advanceNavigatorSearchMatch(delta: -1)
            return true
        }
        return false
    }
}
