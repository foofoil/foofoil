import AppKit

/// 打开命令共用派生键位、菜单标题及冲突规则；无痕版本不单独存储。
nonisolated enum IncognitoOpening {
    static let titles: [String: String] = [
        "history.search": "Quick Open Incognito...",
        "file.openFile": "Open File Incognito...",
        "file.openDirectory": "Open Directory Incognito...",
        "file.openURL": "Open URL Incognito...",
        "file.openTerminal": "Open Terminal Incognito...",
        "file.openCamera": "Open Camera Incognito",
        "file.openClipboardContent": "Open Clipboard Incognito"
    ]
    static let suffix = ".incognito"
    static let clipboardShortcut = KeyboardShortcut(keyEquivalent: "v", modifiers: [.command, .option])

    // Shift 产生的标点与显式 Shift + 基键视为同一键位。
    static func canonical(_ shortcut: KeyboardShortcut) -> KeyboardShortcut {
        let shifted = ["+": "=", "_": "-", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "~": "`", "<": ",", ">": ".", "?": "/", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0"]
        guard let base = shifted[shortcut.keyEquivalent] else { return shortcut }
        return KeyboardShortcut(keyEquivalent: base, modifiers: shortcut.modifiers.union(.shift))
    }

    static func derived(_ shortcut: KeyboardShortcut?) -> KeyboardShortcut? {
        shortcut.map { KeyboardShortcut(keyEquivalent: $0.keyEquivalent, modifiers: $0.modifiers.union(.option)) }
    }
}

extension KeyboardShortcutStore {
    func incognitoShortcut(forID id: String) -> KeyboardShortcut? {
        guard IncognitoOpening.titles[id] != nil else { return nil }
        return IncognitoOpening.derived(shortcut(forID: id))
    }

    /// 检查候选键及其无痕派生键；只读运行中菜单补齐系统固定键位。
    func validationMessage(_ candidate: KeyboardShortcut?, for definition: KeyboardShortcutDefinition) -> String? {
        guard let candidate else { return nil }
        let opensContent = IncognitoOpening.titles[definition.id] != nil
        if opensContent && candidate.modifiers.contains(.option) {
            return NSLocalizedString("Option Reserved for Incognito", comment: "")
        }
        if opensContent && !candidate.hasRequiredModifiers {
            return NSLocalizedString("Opening Shortcut Requires Modifier", comment: "")
        }
        let candidates = [candidate] + (opensContent ? [IncognitoOpening.derived(candidate)!] : [])
        func conflict(_ shortcut: KeyboardShortcut, title: String) -> String? {
            guard candidates.contains(where: { IncognitoOpening.canonical($0) == IncognitoOpening.canonical(shortcut) }) else { return nil }
            return String(format: NSLocalizedString("Shortcut Conflicts With %@", comment: ""), title)
        }
        if let error = conflict(IncognitoOpening.clipboardShortcut, title: NSLocalizedString("Open Clipboard Incognito", comment: "")) { return error }
        for other in KeyboardShortcutCatalog.sections.flatMap(\.definitions) where other.id != definition.id {
            if let shortcut = shortcut(for: other) {
                // 默认方向键等按内容范围复用；保留目录中明确设计的默认共享键位。
                let sharesDefault = !opensContent && candidate == definition.defaultShortcut
                    && shortcut == other.defaultShortcut
                if !sharesDefault, let error = conflict(shortcut, title: other.displayName) { return error }
            }
            if let title = IncognitoOpening.titles[other.id], let shortcut = incognitoShortcut(forID: other.id),
               let error = conflict(shortcut, title: NSLocalizedString(title, comment: "")) { return error }
        }
        func inspect(_ menu: NSMenu?) -> String? {
            guard let menu else { return nil }
            for item in menu.items {
                if let error = inspect(item.submenu) { return error }
                // 可配置项已按当前配置检查；此处仅检查固定的系统/编辑命令。
                guard item.action != nil, !item.keyEquivalent.isEmpty,
                      (item.representedObject as? String).flatMap({ KeyboardShortcutCatalog.definition(withID: $0) }) == nil,
                      !(item.representedObject as? String ?? "").hasSuffix(IncognitoOpening.suffix) else { continue }
                let shortcut = KeyboardShortcut(keyEquivalent: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
                if let error = conflict(shortcut, title: item.title) { return error }
            }
            return nil
        }
        return inspect(NSApp.mainMenu)
    }
}
