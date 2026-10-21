import AppKit

/// 标题编辑共用原生输入框，避免总览键盘监听或嵌套信息面板抢走输入焦点。
@MainActor
enum FoilTitleEditing {
    static func editableTitle(for config: WindowConfig) -> String {
        if let list = config.fileList, list.isPresentable { return list.displayTitle }
        return config.customTitle ?? config.historyMenuDisplayName
    }

    static func makeAlert(title: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Change Title", comment: "")
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        let field = WrappingTitleField(frame: NSRect(x: 0, y: 0, width: 360, height: 76))
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byCharWrapping
        field.maximumNumberOfLines = 0
        field.stringValue = title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert
    }
}

extension AppState {
    /// 列表沿用自身标题，其余箔片只修改展示标题，保留文件名与类型识别。
    func applyFoilTitle(_ title: String) {
        guard toConfig().canRenameTitle else { return }
        let normalized = FileListState.normalizedTitle(title)
        if var list = fileList, list.isPresentable {
            list.title = normalized
            list.isCustomTitle = normalized != nil
            fileList = list
            saveState()
        } else {
            customTitle = normalized
        }
    }
}

/// 视觉折行不改变标题内容；粘贴或输入换行时合并为单行。
private final class WrappingTitleField: NSTextField {
    override func textDidChange(_ notification: Notification) {
        if let editor = currentEditor(), editor.string.rangeOfCharacter(from: .newlines) != nil {
            let selection = editor.selectedRange
            editor.string = editor.string.components(separatedBy: .newlines).joined(separator: " ")
            editor.selectedRange = NSRange(location: min(selection.location, (editor.string as NSString).length), length: 0)
        }
        super.textDidChange(notification)
    }
}
