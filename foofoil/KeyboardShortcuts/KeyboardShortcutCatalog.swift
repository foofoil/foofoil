//  KeyboardShortcutCatalog.swift
//  foofoil
//
//  Created by tolg on 2026/9/15.
//

import AppKit

/// 一条可配置快捷键的稳定描述：标识、本地化标题、默认快捷键（可为空），以及可选的适用范围说明。
/// 标识用于持久化，必须保持稳定；以后新增分组或命令时只追加定义，不改动既有 id。
nonisolated struct KeyboardShortcutDefinition: Identifiable, Hashable {
    let id: String
    let titleKey: String
    /// nil 表示默认没有快捷键，由用户按需设置。
    let defaultShortcut: KeyboardShortcut?
    /// 仅对部分内容类型有效的命令在此给出说明键；nil 表示对所有箔片都有效。
    let noteKey: String?

    var displayName: String {
        NSLocalizedString(titleKey, comment: "")
    }

    var note: String? {
        noteKey.map { NSLocalizedString($0, comment: "") }
    }
}

/// 快捷键配置分组；新增其他快捷键时在此追加 section，设置界面按分组渲染。
/// 声明顺序即设置界面的分组顺序。
nonisolated enum KeyboardShortcutSection: String, CaseIterable, Identifiable {
    case view
    case window

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .view: return "View"
        case .window: return "Window"
        }
    }

    var definitions: [KeyboardShortcutDefinition] {
        switch self {
        case .view: return KeyboardShortcutCatalog.view
        case .window: return KeyboardShortcutCatalog.window
        }
    }
}

nonisolated enum KeyboardShortcutCatalog {
    static var sections: [KeyboardShortcutSection] { KeyboardShortcutSection.allCases }

    /// 视图菜单的全部命令；顺序与菜单一致。默认值与菜单首次建立时保持一致。
    static let view: [KeyboardShortcutDefinition] = [
        definition("view.togglePin", "Toggle Pin", "t", [.command]),
        definition("view.toggleBorder", "Border", "b", [.command], "Shortcut Scope Images and Web"),
        definition("view.slideshow", "Slideshow", nil, [], "Shortcut Scope Image Lists"),
        definition("view.toggleFullScreen", "Enter Full Screen", "f", [.command, .control]),
        definition("view.toggleNavigator", "Always Show Navigator", "l", [.command, .shift], "Shortcut Scope Navigator"),
        definition("view.moveNavigatorSide", "Move Navigator to Right Side", "l", [.command, .option], "Shortcut Scope Navigator"),
        definition("view.reloadPage", "Reload Page", "r", [.command], "Shortcut Scope Web"),
        definition("view.captureImage", "Capture Image foofoil", nil, [], "Shortcut Scope Web"),
        definition("view.selectColor", "Select Color", nil, [], "Shortcut Scope SVG"),
        definition("view.zoomInContent", "Zoom In Content", "+", [.command]),
        definition("view.zoomOutContent", "Zoom Out Content", "-", [.command]),
        definition("view.actualSize", "Actual Size", "0", [.command]),
        definition("view.fitWindowToImage", "Fit Window to Image", "[", [.command], "Shortcut Scope Images"),
        definition("view.fitImageToWindowWidth", "Fit Image to Window Width", "]", [.command], "Shortcut Scope Images"),
        definition("view.zoomOutWindow", "Zoom Out Window", "-", [.command, .shift]),
        definition("view.zoomInWindow", "Zoom In Window", "+", [.command, .shift]),
        definition("view.backgroundColor", "Background Color", nil, []),
        definition("view.increaseOpacity", "Increase Opacity", "\u{F700}", [.command, .shift]),
        definition("view.decreaseOpacity", "Decrease Opacity", "\u{F701}", [.command, .shift])
    ]

    /// 窗口菜单的全部命令；默认值与菜单首次建立时保持一致。
    static let window: [KeyboardShortcutDefinition] = [
        definition("window.moveTopLeft", "Top-Left", "q"),
        definition("window.moveTop", "Top", "w"),
        definition("window.moveTopRight", "Top-Right", "e"),
        definition("window.moveLeft", "Left", "a"),
        definition("window.moveCenter", "Center", "s"),
        definition("window.moveRight", "Right", "d"),
        definition("window.moveBottomLeft", "Bottom-Left", "z"),
        definition("window.moveBottom", "Bottom", "x"),
        definition("window.moveBottomRight", "Bottom-Right", "c"),
        definition("window.showAllFoils", "Show All Foils", "f"),
        definition("window.moveToNextScreen", "Move to Next Screen", "\t")
    ]

    static func definition(withID id: String) -> KeyboardShortcutDefinition? {
        sections.flatMap { $0.definitions }.first { $0.id == id }
    }

    private static func definition(
        _ id: String,
        _ titleKey: String,
        _ keyEquivalent: String?,
        _ modifiers: NSEvent.ModifierFlags = [.control, .option],
        _ noteKey: String? = nil
    ) -> KeyboardShortcutDefinition {
        KeyboardShortcutDefinition(
            id: id,
            titleKey: titleKey,
            defaultShortcut: keyEquivalent.map { KeyboardShortcut(keyEquivalent: $0, modifiers: modifiers) },
            noteKey: noteKey
        )
    }
}
