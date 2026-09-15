//  AppDelegate+KeyboardShortcuts.swift
//  foofoil
//
//  Created by tolg on 2026/9/15.
//

import AppKit

extension AppDelegate {
    /// 按当前配置刷新视图/窗口菜单的键位；菜单项以 representedObject 存稳定标识。
    func applyConfiguredKeyboardShortcuts() {
        applyKeyboardShortcuts(to: viewMenu)
        applyKeyboardShortcuts(to: windowMenu)
    }

    private func applyKeyboardShortcuts(to menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items {
            guard let identifier = item.representedObject as? String,
                  let definition = KeyboardShortcutCatalog.definition(withID: identifier) else { continue }
            let shortcut = KeyboardShortcutStore.shared.shortcut(for: definition)
            item.keyEquivalent = shortcut?.keyEquivalent ?? ""
            item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
        }
    }

    /// 指定命令是否仍在使用默认键位；用于在默认状态下保留既有的窗口直属按键处理。
    func isUsingDefaultShortcut(_ identifier: String) -> Bool {
        guard let definition = KeyboardShortcutCatalog.definition(withID: identifier) else { return false }
        return !KeyboardShortcutStore.shared.isCustomized(definition)
    }

    /// 事件是否命中任一可配置快捷键。
    /// 内容视图（尤其网页）可能先于主菜单拦截按键，窗口层据此把事件放行给主菜单。
    /// 这里只判断“可能命中”，真正的取键与歧义由主菜单按自身规则裁决，因此宁可放宽。
    func matchesConfigurableShortcut(_ event: NSEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return false }
        let keys = possibleShortcutKeys(for: characters)
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // AppKit 允许带 Shift 产生的符号（如 ⌘+ 实际按 ⇧⌘=）匹配键位表中不带 Shift 的组合。
        let modifiersWithoutShift = modifiers.subtracting(.shift)
        return KeyboardShortcutCatalog.sections.contains { section in
            section.definitions.contains { definition in
                guard let shortcut = KeyboardShortcutStore.shared.shortcut(for: definition),
                      keys.contains(shortcut.keyEquivalent) else { return false }
                return shortcut.modifiers == modifiers || shortcut.modifiers == modifiersWithoutShift
            }
        }
    }

    /// 事件字符可能的键位：原字符，以及对应的不带 Shift 的字符（如 "_" → "-"、"+" → "="）。
    private func possibleShortcutKeys(for characters: String) -> Set<String> {
        var keys: Set<String> = [KeyboardShortcut.normalizedKeyEquivalent(characters)]
        if let unshifted = Self.shiftedKeys[characters] {
            keys.insert(unshifted)
        }
        return keys
    }

    private static let shiftedKeys: [String: String] = [
        "+": "=", "_": "-", "{": "[", "}": "]", "|": "\\",
        ":": ";", "\"": "'", "~": "`", "<": ",", ">": ".", "?": "/",
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5",
        "^": "6", "&": "7", "*": "8", "(": "9", ")": "0"
    ]

    /// 快捷键配置变更：菜单键位与全局热键都立即跟随。
    @objc func handleKeyboardShortcutsDidChange() {
        applyConfiguredKeyboardShortcuts()
        FoilExposeController.shared.applyConfiguredGlobalHotKey()
    }
}
