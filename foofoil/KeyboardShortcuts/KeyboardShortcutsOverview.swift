import Foundation

/// 稳定来源标识让历史恢复重新生成一览，而不是展示持久化的旧键位。
@MainActor
enum KeyboardShortcutsOverview {
    static let sourceFingerprint = "foofoil:keyboard-shortcuts-overview"

    static func markdown(
        shortcutProvider: (KeyboardShortcutDefinition) -> KeyboardShortcut? = {
            KeyboardShortcutStore.shared.shortcut(for: $0)
        }
    ) -> String {
        guard let url = Bundle.main.url(forResource: "KeyboardShortcuts", withExtension: "md"),
              var text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let none = NSLocalizedString("Shortcut Overview Unassigned", comment: "")
        func cell(_ value: String) -> String {
            value.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
        }
        for section in KeyboardShortcutCatalog.sections {
            let rows = section.definitions.map { definition in
                let defaultKey = definition.defaultShortcut?.displayString ?? none
                let currentKey = shortcutProvider(definition)?.displayString ?? none
                return "| \(cell(definition.displayName)) | \(cell(defaultKey)) | \(cell(currentKey)) | \(cell(definition.note ?? "")) |"
            }.joined(separator: "\n")
            text = text.replacingOccurrences(of: "{{\(section.rawValue)}}", with: rows)
        }
        if let clipboard = KeyboardShortcutCatalog.definition(withID: "file.openClipboardContent") {
            text = text.replacingOccurrences(of: "{{clipboardShortcut}}", with: cell(shortcutProvider(clipboard)?.displayString ?? none))
        }
        return text
    }
}

extension AppState {
    /// 无来源文件的 Markdown 沿用普通文本历史管线，额外记录可再生文档的身份。
    func openKeyboardShortcutsOverview() {
        openText(KeyboardShortcutsOverview.markdown(), isMarkdown: true)
        sourceFingerprint = KeyboardShortcutsOverview.sourceFingerprint
        originalImageName = NSLocalizedString("Keyboard Shortcuts Overview", comment: "") + ".md"
        saveState()
    }
}
