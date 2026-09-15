//  KeyboardShortcutStore.swift
//  foofoil
//
//  Created by tolg on 2026/9/15.
//

import AppKit

/// 单条命令的持久化覆盖值：自定义键位或显式清除（无快捷键）。
nonisolated enum KeyboardShortcutOverride: Codable, Equatable {
    case custom(KeyboardShortcut)
    case disabled
}

/// 快捷键覆盖值仓库：只保存用户改动过的定义，未改动时回退到目录默认值（可能为空）。
/// 变更后发出通知，菜单与全局热键据此立即生效。
final class KeyboardShortcutStore {
    static let shared = KeyboardShortcutStore()

    private let userDefaults = UserDefaults.standard
    private let storageKey = "keyboardShortcutOverrides"
    /// 按键匹配会在每次键盘事件里频繁读取；缓存解码结果，写入时更新。
    private var cachedOverrides: [String: KeyboardShortcutOverride]?

    private init() {}

    /// 当前生效的快捷键；nil 表示该命令没有快捷键。
    func shortcut(for definition: KeyboardShortcutDefinition) -> KeyboardShortcut? {
        switch overrides[definition.id] {
        case .custom(let shortcut): return shortcut
        case .disabled: return nil
        case nil: return definition.defaultShortcut
        }
    }

    func isCustomized(_ definition: KeyboardShortcutDefinition) -> Bool {
        overrides[definition.id] != nil
    }

    /// 覆盖为指定快捷键；传 nil 表示清除快捷键。
    func setShortcut(_ shortcut: KeyboardShortcut?, for definition: KeyboardShortcutDefinition) {
        var values = overrides
        if let shortcut {
            values[definition.id] = .custom(shortcut)
        } else if definition.defaultShortcut != nil {
            values[definition.id] = .disabled
        } else {
            values.removeValue(forKey: definition.id)
        }
        guard values != overrides else { return }
        persist(values)
    }

    /// 恢复默认（默认可能仍为无快捷键）。
    func reset(_ definition: KeyboardShortcutDefinition) {
        var values = overrides
        values.removeValue(forKey: definition.id)
        guard values != overrides else { return }
        persist(values)
    }

    private var overrides: [String: KeyboardShortcutOverride] {
        if let cachedOverrides { return cachedOverrides }
        let values: [String: KeyboardShortcutOverride]
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: KeyboardShortcutOverride].self, from: data) {
            values = decoded
        } else {
            values = [:]
        }
        cachedOverrides = values
        return values
    }

    private func persist(_ values: [String: KeyboardShortcutOverride]) {
        cachedOverrides = values
        if values.isEmpty {
            userDefaults.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(values) {
            userDefaults.set(data, forKey: storageKey)
        }
        NotificationCenter.default.post(name: .keyboardShortcutsDidChange, object: nil)
    }
}
