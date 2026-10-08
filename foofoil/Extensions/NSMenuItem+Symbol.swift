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
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
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
        for item in items {
            if item.image != nil {
                item.preferredImageVisibility = .visible
            }
            item.submenu?.restoreItemImageVisibility()
        }
    }
}
