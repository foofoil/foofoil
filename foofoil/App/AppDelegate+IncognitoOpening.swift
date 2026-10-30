import AppKit

extension AppDelegate {
    func installIncognitoOpeningAlternates(in menu: NSMenu) {
        for item in menu.items {
            guard let id = item.representedObject as? String,
                  let title = IncognitoOpening.titles[id] else { continue }
            let alternate = NSMenuItem(title: NSLocalizedString(title, comment: ""),
                                       action: #selector(openIncognitoContentAction(_:)), keyEquivalent: item.keyEquivalent)
            alternate.target = self
            alternate.representedObject = id + IncognitoOpening.suffix
            alternate.image = item.image
            // 剪贴板已有独立的可见无痕命令；隐藏派生项但保留其快捷键。
            let isClipboard = id == "file.openClipboardContent"
            alternate.isAlternate = !isClipboard
            alternate.keyEquivalentModifierMask = item.keyEquivalentModifierMask.union(.option)
            alternate.isHidden = isClipboard || item.isHidden
            alternate.allowsKeyEquivalentWhenHidden = isClipboard
            menu.insertItem(alternate, at: menu.index(of: item) + 1)
        }
    }

    @objc func openIncognitoContentAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        switch id {
        case "history.search.incognito": HistorySearchWindowController.shared.show(isIncognito: true)
        case "file.openFile.incognito": openContentPanel(directory: false, target: AppState(isIncognito: true))
        case "file.openDirectory.incognito": openContentPanel(directory: true, target: AppState(isIncognito: true))
        case "file.openURL.incognito": HistorySearchWindowController.shared.showURLInput(target: AppState(isIncognito: true))
        case "file.openTerminal.incognito": openTerminal(isIncognito: true)
        case "file.openCamera.incognito": openCamera(isIncognito: true)
        case "file.openClipboardContent.incognito": _ = openClipboardContentInNewWindow(isIncognito: true)
        default: break
        }
    }

    /// 面板打开时固定来源与隐私模式；只有确认并成功加载后才为新状态建窗。
    func openContentPanel(directory: Bool, target: AppState?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.allowsMultipleSelection = !directory
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            DispatchQueue.main.async {
                if directory { self.openDroppedFiles(panel.urls, into: target) }
                else { self.openGroupedFiles(panel.urls, into: target, append: false) }
                if let target, !self.isBlank(target), !self.windowControllers.contains(where: { $0.appState === target }) {
                    self.showNewWindow(with: target)
                }
            }
        }
    }

    func openWebURL(_ url: URL, into target: AppState) {
        target.openWeb(url: url)
        if let controller = windowControllers.first(where: { $0.appState === target }) {
            activateWindow(controller)
        } else { showNewWindow(with: target) }
    }
}
