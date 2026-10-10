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
    /// 可选的生效范围或使用条件说明；nil 表示没有额外说明。
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
    case global
    case file
    case go
    case view
    case image
    case web
    case playback
    case window
    case history

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .global: return "Shortcut Group Global"
        case .file: return "Shortcut Group Content"
        case .go: return "Shortcut Group Navigation"
        case .view: return "Shortcut Group Display"
        case .image: return "Shortcut Group Images"
        case .web: return "Shortcut Group Web"
        case .playback: return "Shortcut Playback"
        case .window: return "Window"
        case .history: return "History"
        }
    }

    var definitions: [KeyboardShortcutDefinition] {
        switch self {
        case .global: return KeyboardShortcutCatalog.global
        case .file: return KeyboardShortcutCatalog.file
        case .go: return KeyboardShortcutCatalog.go
        case .view: return KeyboardShortcutCatalog.view
        case .image: return KeyboardShortcutCatalog.image
        case .web: return KeyboardShortcutCatalog.web
        case .playback: return KeyboardShortcutCatalog.playback
        case .window: return KeyboardShortcutCatalog.window
        case .history: return KeyboardShortcutCatalog.history
        }
    }
}

/// 快捷键搜索命中的一个分组：分组本身 + 组内命中的命令。
nonisolated struct KeyboardShortcutSearchResult: Identifiable {
    let section: KeyboardShortcutSection
    let definitions: [KeyboardShortcutDefinition]

    var id: String { section.id }
}

nonisolated enum KeyboardShortcutCatalog {
    static var sections: [KeyboardShortcutSection] { KeyboardShortcutSection.allCases }

    static let openClipboardContent = definition("file.openClipboardContent", "Open Clipboard Content", "v", [.command, .shift], "Shortcut Scope App")

    // 设置页按操作目的分组；命令标识和默认键位保持稳定，菜单仍按原有结构组织。
    static let global: [KeyboardShortcutDefinition] = [
        definition("window.showAllFoils", "Foil Overview", "\u{1B}", [.control, .shift], "Shortcut Overview Purpose"),
        definition("global.openClipboardContent", "Open Clipboard Content", nil, [], "Shortcut Scope Global")
    ]

    static let file: [KeyboardShortcutDefinition] = [
        definition("file.openDirectory", "Open Directory...", "o", [.command, .shift]),
        definition("history.search", "Search History Menu Item", "p", [.command], "Shortcut Quick Open Purpose"),
        definition("file.addToList", "Add to List...", nil, []),
        openClipboardContent,
        definition("file.openURL", "Open URL Menu Item", "l", [.command]),
        definition("file.openCamera", "Open Camera", nil, []),
        definition("file.share", "Share...", nil, []),
        definition("file.reset", "Reset", "k", [.command])
    ]

    static let go: [KeyboardShortcutDefinition] = [
        definition("go.previousPage", "Previous Page", "\u{F702}", [], "Shortcut Scope PDF"),
        definition("go.nextPage", "Next Page", "\u{F703}", [], "Shortcut Scope PDF"),
        definition("go.goToPage", "Go to Page Menu Item", "g", [.command], "Shortcut Scope PDF"),
        definition("go.previousItem", "Previous Item", "\u{F700}", [], "Shortcut Scope Lists"),
        definition("go.nextItem", "Next Item", "\u{F701}", [], "Shortcut Scope Lists"),
        definition("view.toggleNavigator", "Always Show Navigator", "l", [.command, .shift], "Shortcut Scope Navigator"),
        definition("view.moveNavigatorSide", "Shortcut Switch Navigator Side", "l", [.command, .option], "Shortcut Scope Navigator")
    ]

    static let view: [KeyboardShortcutDefinition] = [
        definition("view.zoomInContent", "Zoom In Content", "+", [.command]),
        definition("view.zoomOutContent", "Zoom Out Content", "-", [.command]),
        definition("view.actualSize", "Actual Size", "0", [.command]),
        definition("view.documentStyle", "Document Style", "i", [.command], "Shortcut Scope Document Style")
    ]

    static let image: [KeyboardShortcutDefinition] = [
        definition("edit.extractText", "Extract Text", "e", [.command], "Shortcut Scope Raster Images"),
        definition("edit.extractImageSubject", "Extract Image Subject", nil, [.command, .option], "Shortcut Scope Detected Image Subject"),
        definition("view.selectColor", "Select Color", nil, [], "Shortcut Scope SVG"),
        definition("view.slideshow", "Slideshow", nil, [], "Shortcut Scope Image Lists"),
        definition("view.fitWindowToImage", "Fit Window to Image", "[", [.command], "Shortcut Scope Bordered Images"),
        definition("view.fitImageToWindowWidth", "Fit Image to Window Width", "]", [.command], "Shortcut Scope Bordered Images")
    ]

    static let web: [KeyboardShortcutDefinition] = [
        definition("file.openInBrowser", "Shortcut Open in Browser", nil, [], "Shortcut Scope Web"),
        definition("file.copyURL", "Copy URL", "c", [.command, .option], "Shortcut Scope Web"),
        definition("view.reloadPage", "Reload Page", "r", [.command], "Shortcut Scope Web"),
        definition("view.captureImage", "Capture Image foofoil", nil, [], "Shortcut Scope Web")
    ]

    static let playback: [KeyboardShortcutDefinition] = [
        definition("playback.toggle", "Shortcut Play Pause", " ", [], "Shortcut Scope Media"),
        definition("playback.backward", "Shortcut Seek Backward", "\u{F702}", [], "Shortcut Scope Media"),
        definition("playback.forward", "Shortcut Seek Forward", "\u{F703}", [], "Shortcut Scope Media")
    ]

    static let window: [KeyboardShortcutDefinition] = [
        definition("view.togglePin", "Toggle Pin", "t", [.command]),
        definition("view.toggleBorder", "Border", "b", [.command], "Shortcut Scope Border"),
        definition("view.toggleFullScreen", "Shortcut Toggle Full Screen", "f", [.command, .control]),
        definition("view.zoomInWindow", "Zoom In Window", "+", [.command, .shift], "Shortcut Scope Non Full Screen"),
        definition("view.zoomOutWindow", "Zoom Out Window", "-", [.command, .shift], "Shortcut Scope Non Full Screen"),
        definition("view.increaseOpacity", "Increase Opacity", "\u{F700}", [.command, .shift]),
        definition("view.decreaseOpacity", "Decrease Opacity", "\u{F701}", [.command, .shift]),
        definition("window.moveTopLeft", "Top-Left", "q"),
        definition("window.moveTop", "Top", "w"),
        definition("window.moveTopRight", "Top-Right", "e"),
        definition("window.moveLeft", "Left", "a"),
        definition("window.moveCenter", "Center", "s"),
        definition("window.moveRight", "Right", "d"),
        definition("window.moveBottomLeft", "Bottom-Left", "z"),
        definition("window.moveBottom", "Bottom", "x"),
        definition("window.moveBottomRight", "Bottom-Right", "c"),
        definition("window.moveToNextScreen", "Move to Next Screen", "\t")
    ]

    static let history: [KeyboardShortcutDefinition] = [
        definition("history.clear", "Clear History Menu Item", nil, [])
    ]

    static func definition(withID id: String) -> KeyboardShortcutDefinition? {
        sections.flatMap { $0.definitions }.first { $0.id == id }
    }

    /// 设置页顶部搜索：按命令名称（本地化标题或说明）和/或当前生效的快捷键过滤。
    /// 两个条件同时给出时取交集；返回的分组都不为空。`shortcutProvider` 供测试注入。
    static func searchResults(
        nameQuery: String,
        shortcutQuery: KeyboardShortcut?,
        shortcutProvider: (KeyboardShortcutDefinition) -> KeyboardShortcut? = {
            KeyboardShortcutStore.shared.shortcut(for: $0)
        }
    ) -> [KeyboardShortcutSearchResult] {
        let trimmedQuery = nameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return sections.compactMap { section in
            let matches = section.definitions.filter { definition in
                if !trimmedQuery.isEmpty {
                    let nameMatches = definition.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                    let noteMatches = definition.note?.localizedCaseInsensitiveContains(trimmedQuery) ?? false
                    guard nameMatches || noteMatches else { return false }
                }
                if let shortcutQuery {
                    guard shortcutProvider(definition) == shortcutQuery else { return false }
                }
                return true
            }
            return matches.isEmpty ? nil : KeyboardShortcutSearchResult(section: section, definitions: matches)
        }
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
