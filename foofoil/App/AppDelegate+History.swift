//  AppDelegate+History.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import WebKit


extension AppDelegate {
    // MARK: - History Management

    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let dockMenu = NSMenu()

        let configs = HistoryRepository.shared.recent(limit: 30).filter { SettingsStore.shared.appleMusicLibraryEnabled || $0.appleMusicReference == nil }

        if configs.isEmpty {
            let noHistoryItem = NSMenuItem(title: NSLocalizedString("No History", comment: ""), action: nil, keyEquivalent: "")
            noHistoryItem.withSymbol("clock")
            noHistoryItem.isEnabled = false
            dockMenu.addItem(noHistoryItem)
        } else {
            for config in configs.prefix(10) {
                var title = config.historyMenuDisplayName

                if title.isEmpty {
                    title = NSLocalizedString("Untitled Note", comment: "")
                }

                let item = NSMenuItem(title: title, action: #selector(openHistoryItemAction(_:)), keyEquivalent: "")
                item.keyEquivalentModifierMask = []
                item.withSymbol(config.historyMenuSymbolName)
                item.representedObject = config
                item.target = self
                dockMenu.addItem(item)
            }
        }

        dockMenu.addItem(NSMenuItem.separator())

        let searchItem = NSMenuItem(title: NSLocalizedString("Search History Menu Item", comment: ""), action: #selector(showHistorySearchAction), keyEquivalent: "")
        searchItem.withSymbol("magnifyingglass")
        searchItem.target = self
        dockMenu.addItem(searchItem)

        let clearHistoryItem = NSMenuItem(title: NSLocalizedString("Clear History Menu Item", comment: ""), action: #selector(clearHistoryAction), keyEquivalent: "")
        clearHistoryItem.withSymbol("trash")
        clearHistoryItem.target = self
        dockMenu.addItem(clearHistoryItem)

        return dockMenu
    }

    public func updateHistoryMenu(preloadedConfigs: [WindowConfig]? = nil) {
        guard let historyMenu = historyMenu else { return }
        historyMenu.removeAllItems()

        let favoriteItem = NSMenuItem(title: "", action: #selector(toggleCurrentFoilFavoriteAction), keyEquivalent: "")
        favoriteItem.target = self
        let favoriteShortcut = KeyboardShortcutStore.shared.shortcut(forID: "history.toggleFavorite")
        favoriteItem.keyEquivalent = favoriteShortcut?.keyEquivalent ?? ""
        favoriteItem.keyEquivalentModifierMask = favoriteShortcut?.modifiers ?? []
        updateCurrentFoilFavoriteMenuItem(favoriteItem)
        historyMenu.addItem(favoriteItem)
        historyMenu.addItem(NSMenuItem.separator())

        let searchItem = NSMenuItem(title: NSLocalizedString("Search History Records Menu Item", comment: ""), action: #selector(showHistorySearchAction), keyEquivalent: "")
        searchItem.withSymbol("magnifyingglass")
        searchItem.target = self
        historyMenu.addItem(searchItem)
        historyMenu.addItem(NSMenuItem.separator())

        let configs = (preloadedConfigs ?? HistoryRepository.shared.recent(limit: 30)).filter { SettingsStore.shared.appleMusicLibraryEnabled || $0.appleMusicReference == nil }

        if configs.isEmpty {
            let noHistoryItem = NSMenuItem(title: NSLocalizedString("No History", comment: ""), action: nil, keyEquivalent: "")
            noHistoryItem.withSymbol("clock")
            noHistoryItem.isEnabled = false
            historyMenu.addItem(noHistoryItem)
        } else {
            for config in configs.prefix(10) {
                var title = config.historyMenuDisplayName

                if title.isEmpty {
                    title = NSLocalizedString("Untitled Note", comment: "")
                }

                // ⌘1-9 不再作为全局菜单快捷键；打开最近历史仅在空白箔窗口内生效。
                let item = NSMenuItem(title: title, action: #selector(openHistoryItemAction(_:)), keyEquivalent: "")
                item.keyEquivalentModifierMask = []
                item.withSymbol(config.historyMenuSymbolName)
                item.representedObject = config
                item.target = self
                historyMenu.addItem(item)
            }
        }

        historyMenu.addItem(NSMenuItem.separator())

        let clearHistoryItem = NSMenuItem(title: NSLocalizedString("Clear History Menu Item", comment: ""), action: #selector(clearHistoryAction), keyEquivalent: "")
        clearHistoryItem.withSymbol("trash")
        let clearShortcut = KeyboardShortcutStore.shared.shortcut(forID: "history.clear")
        clearHistoryItem.keyEquivalent = clearShortcut?.keyEquivalent ?? ""
        clearHistoryItem.keyEquivalentModifierMask = clearShortcut?.modifiers ?? []
        clearHistoryItem.target = self
        historyMenu.addItem(clearHistoryItem)
    }

    /// 收藏属于历史记录；无痕、临时预览和未形成可保存内容的箔片不提供该操作。
    var currentFoilForFavorite: AppState? {
        guard let state = activeAppState, !state.isIncognito, !state.isArchivePreview,
              !state.isFileOpenFeedback, state.archiveSession?.hasTemporarySource != true,
              !HistoryRepository.shared.wasDeleted(state.id),
              HistoryManager.shared.hasPersistableContent(state.toConfig()) else { return nil }
        return state
    }

    @discardableResult
    func updateCurrentFoilFavoriteMenuItem(_ item: NSMenuItem) -> Bool {
        let state = currentFoilForFavorite
        let isFavorite = state.flatMap { HistoryRepository.shared.config(id: $0.id) }?.historyIsPinned == true
        item.title = NSLocalizedString(isFavorite ? "Unfavorite Current Foil" : "Favorite Current Foil", comment: "")
        item.withSymbol(isFavorite ? "bookmark.slash.fill" : "bookmark.fill")
        item.isEnabled = state != nil
        return state != nil
    }

    @objc func toggleCurrentFoilFavoriteAction() {
        guard let state = currentFoilForFavorite else { return }
        HistoryManager.shared.flushPendingListSaves()
        // 新内容先建立历史；已有记录只改收藏状态，避免保存窗口时顺带重排访问顺序。
        if HistoryRepository.shared.config(id: state.id) == nil {
            state.saveState()
            HistoryManager.shared.flushPendingListSaves()
        }
        guard let config = HistoryRepository.shared.config(id: state.id) else {
            state.toast.showFavoriteResult(pinned: true, succeeded: false)
            return
        }
        HistoryManager.shared.setFavorite(id: config.id, pinned: !config.historyIsPinned, toast: state.toast)
        updateHistoryMenu()
    }

    @objc func showHistorySearchAction() {
        NSApp.activate(ignoringOtherApps: true)
        HistorySearchWindowController.shared.show()
    }

    /// 搜索结果优先复用已打开的空白窗口，否则新建窗口。
    public func openSearchResultInNewWindow(id: UUID) {
        guard let config = HistoryRepository.shared.config(id: id),
              SettingsStore.shared.appleMusicLibraryEnabled || config.appleMusicReference == nil else { return }
        openHistoryConfig(config: config, id: id)
    }

    func openHistoryConfig(config: WindowConfig, id: UUID) {
        let musicController = config.appleMusicReference == nil ? nil : windowControllers.first { $0.appState.appleMusicReference != nil && !$0.appState.isIncognito }
        if let controller = musicController ?? availableBlankWindowController {
            controller.appState.saveState()
            guard controller.appState.loadConfig(config) else {
                HistorySearchWindowController.shared.dismiss()
                return
            }
            activateWindow(controller)
        } else {
            let state = AppState()
            guard state.loadConfig(config) else {
                HistorySearchWindowController.shared.dismiss()
                return
            }
            let controller = FloatingWindowController(appState: state)
            if config.windowFrame == nil { controller.window?.center() }
            addWindowController(controller)
            controller.showWindow(nil)
        }
        HistoryRepository.shared.touch(id: id)
        HistoryManager.shared.refresh()
        HistorySearchWindowController.shared.dismiss()
    }

    @objc func openHistoryItemAction(_ sender: NSMenuItem) {
        guard let config = sender.representedObject as? WindowConfig,
              SettingsStore.shared.appleMusicLibraryEnabled || config.appleMusicReference == nil else { return }

        NSApp.activate(ignoringOtherApps: true)
        // 所有历史入口共用恢复结果，失败时只显示反馈箔，不再创建空白内容窗口。
        openHistoryConfig(config: config, id: config.id)
    }

    @objc func clearHistoryAction() {
        // 浮箔总览面板位于 screenSaver 层级，会盖住模态警告框；确认前先收起覆盖层，
        // 与文件对话框、历史搜索的处理保持一致。
        FoilExposeController.shared.dismiss()

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Confirm Clear History", comment: "")
        alert.informativeText = NSLocalizedString("This will clear history and cached content for closed windows, plus WebKit website cache, cookies, and stored website data.", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Clear", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        if alert.runModal() == .alertFirstButtonReturn {
            HistoryManager.shared.clearHistory()
            clearWebKitWebsiteData()
        }
    }

    func clearWebKitWebsiteData() {
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            dataStore.removeData(ofTypes: dataTypes, for: records) { }
        }
    }
}
