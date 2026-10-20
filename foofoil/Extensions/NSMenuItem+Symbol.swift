//  NSMenuItem+Symbol.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import AppKit

extension NSMenuItem {
    /// 使用系统符号统一菜单图标，同时保留 AppKit 对禁用状态的自动着色。
    @discardableResult
    func withSymbol(_ symbolName: String) -> Self {
        withImage(NSImage(systemSymbolName: symbolName, accessibilityDescription: nil))
    }

    @discardableResult
    func withImage(_ menuImage: NSImage?) -> Self {
        image = menuImage
        if #available(macOS 27.0, *) {
            preferredImageVisibility = .visible
        }
        return self
    }
}

extension NSMenu {
    /// macOS 27 默认隐藏菜单图标；也处理 SwiftUI 动态生成的右键菜单及子菜单。
    func restoreItemImageVisibility() {
        guard #available(macOS 27.0, *) else { return }
        for index in items.indices { restoreItemImageVisibility(at: index) }
    }

    /// SwiftUI 可以在开始跟踪后才插入菜单项或补上 image；仅修正变动项，避免每次更新遍历整棵菜单。
    func restoreItemImageVisibility(at index: Int) {
        guard #available(macOS 27.0, *), items.indices.contains(index) else { return }
        let item = items[index]
        // 修改可见性也可能触发菜单更新；已修正的条目不重复赋值，避免通知重入。
        if item.image != nil, item.preferredImageVisibility != .visible {
            item.preferredImageVisibility = .visible
        }
        item.submenu?.restoreItemImageVisibility()
    }
}
