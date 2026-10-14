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
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
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
