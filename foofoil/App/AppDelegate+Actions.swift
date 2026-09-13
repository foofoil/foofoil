//  AppDelegate+Actions.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import WebKit
import FoofoilExtensionKit


extension AppDelegate {
    // MARK: - Actions

    @objc func newWindowAction() {
        showNewWindow(with: AppState())
    }

    @objc func showSettingsAction() {
        SettingsWindowController.shared.show()
    }

    @objc func extensionCommandAction(_ sender: NSMenuItem) {
        guard let commandID = sender.representedObject as? String else { return }
        activeAppState?.performExtensionCommand(commandID)
    }

    func showNewWindow(with state: AppState) {
        let controller = FloatingWindowController(appState: state)
        prepareNewWindowFrame(for: controller)
        addWindowController(controller)
        controller.showWindow(nil)
    }

    /// 新箔片错开当前活跃窗口，避免完全重合；无活跃窗口时居中。
    func prepareNewWindowFrame(for controller: FloatingWindowController) {
        if let keyWindow = NSApplication.shared.keyWindow {
            let keyFrame = keyWindow.frame
            let size = controller.window?.frame.size ?? NSSize(width: 400, height: 400)
            let offsetFrame = NSRect(
                x: keyFrame.minX + 30,
                y: keyFrame.minY - 30,
                width: size.width,
                height: size.height
            )
            controller.window?.setFrame(offsetFrame, display: true)
        } else {
            controller.window?.center()
        }
    }

    func showSaveErrorAlert(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Save Failed Title", comment: "")
            alert.informativeText = String(format: NSLocalizedString("Save Failed Message Format", comment: ""), error.localizedDescription)
            alert.runModal()
        }
    }

    @objc func saveAsAction() {
        guard let appState = activeAppState else { return }

        if let webURL = appState.webURL, !webURL.isFileURL {
            // 在线网页：先出发截图和闪白信号
            NotificationCenter.default.post(
                name: Notification.Name("triggerSaveSnapshot_\(appState.id.uuidString)"),
                object: nil
            )
        } else {
            // 文本、图片或本地 HTML 模式：直接弹出另存为面板
            presentSavePanel(for: appState)
        }
    }

    /// 根据当前内容提供系统共享所需的原生对象，保留文件类型或文本内容。
    func sharingItems(for appState: AppState) -> [Any] {
        if let webURL = appState.webURL {
            return [webURL]
        }

        if let imageURL = appState.imageURL {
            return [imageURL]
        }

        if let textURL = appState.textURL {
            return [textURL]
        }

        let text = appState.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [text]
    }

    @objc func shareAction() {
        guard let controller = activeWindowController,
              let contentView = controller.window?.contentView else {
            return
        }

        let items = sharingItems(for: controller.appState)
        guard !items.isEmpty else { return }

        let picker = NSSharingServicePicker(items: items)
        let anchorRect = NSRect(
            x: contentView.bounds.midX,
            y: contentView.bounds.maxY,
            width: 1,
            height: 1
        )
        picker.show(relativeTo: anchorRect, of: contentView, preferredEdge: .maxY)
    }

    func defaultBrowserInfo() -> (name: String, itemTitle: String) {
        let defaultBrowserName: String
        if let httpsURL = URL(string: "https://www.apple.com"),
           let appURL = NSWorkspace.shared.urlForApplication(toOpen: httpsURL) {
            let bundle = Bundle(url: appURL)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? FileManager.default.displayName(atPath: appURL.path)
            var displayName = name
            if displayName.hasSuffix(".app") {
                displayName = String(displayName.dropLast(4))
            }
            defaultBrowserName = displayName.isEmpty ? NSLocalizedString("Default Browser", comment: "") : displayName
        } else {
            defaultBrowserName = NSLocalizedString("Default Browser", comment: "")
        }
        let title = String(format: NSLocalizedString("Open in %@", comment: ""), defaultBrowserName)
        return (defaultBrowserName, title)
    }

    @objc func openInDefaultBrowserAction() {
        guard let appState = activeAppState,
              let url = appState.actualWebURL ?? appState.webURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func copyWebURLAction() {
        guard let appState = activeAppState,
              let url = appState.actualWebURL ?? appState.webURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    @objc func handleWebSnapshotReadyForSave(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let id = userInfo["id"] as? UUID,
              let appState = activeAppState,
              appState.id == id else {
            return
        }

        // 截图和闪白已完成，现在弹出保存面板
        presentSavePanel(for: appState)
    }

    func presentSavePanel(for appState: AppState) {
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true

        var defaultName = "Untitled"
        var allowedTypes: [UTType] = []

        // 1. 优先判定是否为网页模式 (即便后台已缓存网页截图 imageURL，核心类型依然属于网页)
        if let webURL = appState.webURL {
            if webURL.isFileURL {
                if let name = appState.originalImageName, !name.isEmpty {
                    defaultName = name
                } else {
                    defaultName = webURL.lastPathComponent
                }
                let ext = webURL.pathExtension
                if let type = UTType(filenameExtension: ext) {
                    allowedTypes = [type]
                } else {
                    allowedTypes = [.html, .data]
                }
            } else {
                // 在线网页：直接保存为生成的截图图片 (PNG)
                guard let _ = appState.imageURL else {
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Web Snapshot Loading Title", comment: "")
                    alert.informativeText = NSLocalizedString("Web Snapshot Loading Message", comment: "")
                    alert.runModal()
                    return
                }
                if let name = appState.originalImageName, !name.isEmpty {
                    defaultName = name
                } else if let host = webURL.host {
                    defaultName = host
                } else {
                    defaultName = "Snapshot"
                }

                // 去除所有已知网页相关的后缀
                if defaultName.lowercased().hasSuffix(".webloc") {
                    defaultName = String(defaultName.dropLast(7))
                }
                if defaultName.lowercased().hasSuffix(".webarchive") {
                    defaultName = String(defaultName.dropLast(11))
                }
                if defaultName.lowercased().hasSuffix(".pdf") {
                    defaultName = String(defaultName.dropLast(4))
                }

                if !defaultName.lowercased().hasSuffix(".png") {
                    defaultName += ".png"
                }
                allowedTypes = [.png]
            }
        } else if let imageURL = appState.imageURL { // 2. 其次判定是否为独立的图片或 PDF
            if let name = appState.originalImageName {
                defaultName = name
            } else {
                defaultName = imageURL.lastPathComponent
            }
            let ext = imageURL.pathExtension
            if let type = UTType(filenameExtension: ext) {
                allowedTypes = [type]
            } else {
                allowedTypes = [.image, .data]
            }
        } else if !appState.text.isEmpty { // 3. 最后判定是否为文本
            if let name = appState.originalImageName, !name.isEmpty {
                defaultName = name
            } else {
                defaultName = appState.isMarkdownPreview ? "Untitled.md" : "Untitled.txt"
            }

            let ext = URL(fileURLWithPath: defaultName).pathExtension.lowercased()
            if ext == "md" || ext == "markdown" {
                if let mdType = UTType("net.daringfireball.markdown") {
                    allowedTypes.append(mdType)
                }
                if let pubMdType = UTType("public.markdown") {
                    allowedTypes.append(pubMdType)
                }
                allowedTypes.append(.plainText)
            } else if ext == "csv" {
                if let csvType = UTType(filenameExtension: "csv") {
                    allowedTypes.append(csvType)
                }
                allowedTypes.append(.plainText)
            } else {
                allowedTypes = [.plainText]
            }
        } else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Save As Failed Title", comment: "")
            alert.informativeText = NSLocalizedString("Save As Failed Message", comment: "")
            alert.runModal()
            return
        }

        savePanel.nameFieldStringValue = defaultName
        if !allowedTypes.isEmpty {
            savePanel.allowedContentTypes = allowedTypes
        }

        savePanel.begin { response in
            if response == .OK, let targetURL = savePanel.url {
                DispatchQueue.main.async {
                    self.performSaveAs(appState: appState, to: targetURL)
                }
            }
        }
    }

    func performSaveAs(appState: AppState, to targetURL: URL) {
        let isAccessing = targetURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                targetURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            // 1. 优先处理网页模式
            if let webURL = appState.webURL {
                if webURL.isFileURL {
                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        try FileManager.default.removeItem(at: targetURL)
                    }
                    try FileManager.default.copyItem(at: webURL, to: targetURL)
                } else {
                    // 在线网页另存为：拷贝截图文件
                    guard let imageURL = appState.imageURL else {
                        throw NSError(domain: "FoofoilError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Snapshot image not found"])
                    }
                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        try FileManager.default.removeItem(at: targetURL)
                    }
                    try FileManager.default.copyItem(at: imageURL, to: targetURL)
                }
            } else if let imageURL = appState.imageURL { // 2. 其次处理图片模式
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
                try FileManager.default.copyItem(at: imageURL, to: targetURL)
            } else if !appState.text.isEmpty { // 3. 最后处理文本
                try appState.text.write(to: targetURL, atomically: true, encoding: .utf8)
            }
        } catch {
            self.showSaveErrorAlert(error)
        }
    }

    @objc func openFileAction() {
        guard let appState = activeAppState else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        var types: [UTType] = [.image, .pdf, .html, .text, .movie, .audio]
        if let cueType = UTType(filenameExtension: "cue") {
            types.append(cueType)
        }
        if let testExtensionType = UTType("app.foofoil.test-document") {
            types.append(testExtensionType)
        }
        if let webarchiveType = UTType("com.apple.webarchive") {
            types.append(webarchiveType)
        }
        types.append(contentsOf: ExtensionHost.shared.additionalContentTypes(for: .audio))
        panel.allowedContentTypes = Array(Dictionary(grouping: types, by: \.identifier).compactMap(\.value.first))

        panel.begin { response in
            if response == .OK {
                DispatchQueue.main.async {
                    self.openGroupedFiles(panel.urls, into: appState, append: false)
                }
            }
        }
    }

    @objc func addToFileListAction() {
        guard let appState = activeAppState, let kind = appState.listableKind else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var contentTypes = kind.allowedContentTypes
        if kind == .audio {
            contentTypes.append(contentsOf: ExtensionHost.shared.additionalContentTypes(for: .audio))
        }
        panel.allowedContentTypes = Array(Dictionary(grouping: contentTypes, by: \.identifier).compactMap(\.value.first))

        panel.begin { response in
            if response == .OK {
                DispatchQueue.main.async {
                    self.openGroupedFiles(panel.urls, into: appState, append: true)
                }
            }
        }
    }

    @objc func handleOpenGroupedFiles(_ notification: Notification) {
        guard let urls = notification.userInfo?["urls"] as? [URL] else { return }
        let windowID = notification.userInfo?["windowID"] as? UUID
        let append = notification.userInfo?["append"] as? Bool ?? false
        let target = windowControllers.first(where: { $0.appState.id == windowID })?.appState
        openGroupedFiles(urls, into: target, append: append)
    }

    /// 按同类型分组打开：第一组进入目标箔片（或新窗口），其余组另开箔片。
    func openGroupedFiles(_ urls: [URL], into target: AppState?, append: Bool) {
        let probe = target ?? AppState()
        let openable = urls.filter { probe.canOpenFile(url: $0) }
        var groups = FileListGrouper.groups(from: openable)
        guard !groups.isEmpty else { return }

        if append, let target {
            if let kind = target.listableKind {
                let matching: [URL]
                if kind == .audio {
                    let cues = groups.filter { $0.kind == .cueSheets }.flatMap(\.urls)
                    matching = cues.isEmpty
                        ? groups.filter { $0.kind == .listable(.audio) }.flatMap(\.urls)
                        : cues
                } else {
                    matching = groups.filter { $0.kind == .listable(kind) }.flatMap(\.urls)
                }
                if !matching.isEmpty {
                    target.appendToFileList(urls: matching)
                }
                groups.removeAll { group in
                    switch group.kind {
                    case .cueSheets:
                        return kind == .audio
                    case .listable(let listKind):
                        return listKind == kind
                    case .other:
                        return false
                    }
                }
            }
            for group in groups {
                openGroupInNewWindow(group)
            }
            return
        }

        let first = groups.removeFirst()
        if let target {
            target.openFileGroup(first, preservesIdentity: isBlank(target))
            if let controller = windowControllers.first(where: { $0.appState === target }) {
                activateWindow(controller)
            }
        } else {
            openGroupInNewWindow(first)
        }
        for group in groups {
            openGroupInNewWindow(group)
        }
    }

    /// Finder 拖到 Dock 图标时与箔片内拖放保持一致：非空箔片只接收当前类型。
    func openDroppedFiles(_ urls: [URL], into target: AppState?) {
        guard let target else {
            let state = AppState()
            guard state.handleDroppedFileURLs(urls) else { return }
            showNewWindow(with: state)
            return
        }

        if isBlank(target) {
            guard target.handleDroppedFileURLs(urls) else { return }
            if let controller = windowControllers.first(where: { $0.appState === target }) {
                activateWindow(controller)
            }
            return
        }

        if target.listableKind != nil {
            let remaining = target.consumeDroppedImagesAsAudioCover(from: urls)
            let consumedCover = remaining.count < urls.count
            if remaining.isEmpty {
                if consumedCover, let controller = windowControllers.first(where: { $0.appState === target }) {
                    activateWindow(controller)
                }
                return
            }
            guard target.appendMatchingDroppedFiles(urls: remaining) || consumedCover else { return }
        } else {
            let matching = target.matchingDroppedFiles(urls: urls)
            guard !matching.isEmpty else { return }
            openGroupedFiles(matching, into: target, append: false)
        }

        if let controller = windowControllers.first(where: { $0.appState === target }) {
            activateWindow(controller)
        }
    }

    func openGroupInNewWindow(_ group: FileListGroup) {
        let state = AppState()
        state.openFileGroup(group, preservesIdentity: true)
        showNewWindow(with: state)
    }

    @objc func openWebURLAction() {
        let currentURLString: String? = {
            guard let appState = activeAppState,
                  let url = appState.actualWebURL ?? appState.webURL else { return nil }
            return url.absoluteString
        }()
        HistorySearchWindowController.shared.showURLInput(initialQuery: currentURLString)
    }

    /// 在空白窗口中打开网页；若没有空白窗口，则创建新窗口。
    public func openWebURLInPreferredWindow(_ url: URL) {
        if let controller = availableBlankWindowController {
            controller.appState.openWeb(url: url)
            activateWindow(controller)
        } else {
            let state = AppState()
            state.openWeb(url: url)
            showNewWindow(with: state)
        }
        HistorySearchWindowController.shared.dismiss()
    }

    @objc func openClipboardContentAction() {
        _ = openClipboardContentInNewWindow()
    }

    /// 直接打开剪贴板内容：文件/文件夹/图片复用拖入箔片的处理管线，文本按 Markdown / HTML / 笔记区分。
    @discardableResult
    func openClipboardContentInNewWindow() -> Bool {
        let fileURLs = clipboardFileURLs()
        if !fileURLs.isEmpty {
            return openClipboardFileURLs(fileURLs)
        }

        if let image = clipboardImage() {
            let target = clipboardContentTarget()
            target.state.openImage(image: image, imageSource: .clipboard)
            presentClipboardTarget(target)
            return true
        }

        return openClipboardText(from: NSPasteboard.general)
    }

    /// 剪贴板文件与拖入箔片走同一条管线；没有空白箔片时新建一扇再接管。
    private func openClipboardFileURLs(_ urls: [URL]) -> Bool {
        if let controller = availableBlankWindowController {
            guard controller.appState.handleDroppedFileURLs(urls) else { return false }
            activateWindow(controller)
            return true
        }

        // 多个文件分组会通过通知回到源窗口，先把控制器登记进窗口表再交给拖放管线。
        let state = AppState()
        let controller = FloatingWindowController(appState: state)
        prepareNewWindowFrame(for: controller)
        addWindowController(controller)
        guard state.handleDroppedFileURLs(urls) else {
            removeWindowController(controller)
            controller.close()
            return false
        }
        activateWindow(controller)
        return true
    }

    private func openClipboardText(from pasteboard: NSPasteboard) -> Bool {
        let declaredMarkdownRaw = Self.markdownPasteboardTypes
            .compactMap { pasteboard.availableType(from: [$0]) }
            .first
            .flatMap { pasteboard.string(forType: $0) }
        let isDeclaredMarkdown = !(declaredMarkdownRaw?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let text = isDeclaredMarkdown ? declaredMarkdownRaw : pasteboard.string(forType: .string)

        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isDeclaredMarkdown || AppState.looksLikeMarkdown(text) {
                let target = clipboardContentTarget()
                target.state.openText(text, isMarkdown: true)
                presentClipboardTarget(target)
                return true
            }
            if let html = clipboardHTML(from: pasteboard) ?? (AppState.looksLikeHTML(text) ? text : nil) {
                return openClipboardHTML(html)
            }
            let target = clipboardContentTarget()
            target.state.openText(text, isMarkdown: false)
            presentClipboardTarget(target)
            return true
        }

        // 只有 HTML 表示、没有可读纯文本时仍按网页打开。
        guard let html = clipboardHTML(from: pasteboard) else { return false }
        return openClipboardHTML(html)
    }

    private func openClipboardHTML(_ html: String) -> Bool {
        let target = clipboardContentTarget()
        guard target.state.openHTML(html, originalName: NSLocalizedString("Clipboard Web Page", comment: "")) else {
            return false
        }
        presentClipboardTarget(target)
        return true
    }

    /// 剪贴板内容优先落到空白箔片（当前活跃优先），否则新建一扇。
    private struct ClipboardContentTarget {
        let state: AppState
        let controller: FloatingWindowController?
    }

    private func clipboardContentTarget() -> ClipboardContentTarget {
        if let controller = availableBlankWindowController {
            return ClipboardContentTarget(state: controller.appState, controller: controller)
        }
        return ClipboardContentTarget(state: AppState(), controller: nil)
    }

    private func presentClipboardTarget(_ target: ClipboardContentTarget) {
        if let controller = target.controller {
            activateWindow(controller)
        } else {
            showNewWindow(with: target.state)
        }
    }

    private static let markdownPasteboardTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("net.daringfireball.markdown"),
        NSPasteboard.PasteboardType("public.markdown")
    ]

    private func clipboardHTML(from pasteboard: NSPasteboard) -> String? {
        guard let html = pasteboard.string(forType: .html),
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return html
    }

    func clipboardFileURLs() -> [URL] {
        let pasteboard = NSPasteboard.general
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    func clipboardImage() -> NSImage? {
        // 若剪贴板包含文件，不能回退到它的 Finder 图标。
        guard clipboardFileURLs().isEmpty else { return nil }
        let pasteboard = NSPasteboard.general
        guard pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) else {
            return nil
        }
        return NSImage(pasteboard: pasteboard)
    }

    /// 菜单校验：剪贴板里存在会被箔片打开的文件、图片或文本。
    func hasOpenableClipboardContent(using appState: AppState?) -> Bool {
        let fileURLs = clipboardFileURLs()
        if !fileURLs.isEmpty {
            // 没有活跃箔片时无法判断扩展/图片可打开性，交给动作本身筛选。
            guard let appState else { return true }
            return fileURLs.contains { $0.hasDirectoryPath || appState.canOpenFile(url: $0) }
        }
        if clipboardImage() != nil { return true }
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return clipboardHTML(from: pasteboard) != nil
    }

    @objc func resetContentAction() {
        activeAppState?.resetContent()
    }

    @objc func closeWindowAction() {
        // 设置、关于等带关闭按钮的窗口走系统 performClose；箔窗口是无边框，仍由控制器关闭。
        if closeStandardKeyWindow(NSApplication.shared.keyWindow) {
            return
        }
        activeWindowController?.close()
    }

    @discardableResult
    func closeStandardKeyWindow(_ window: NSWindow?) -> Bool {
        guard let window, window.styleMask.contains(.closable) else { return false }
        window.performClose(nil)
        return true
    }

    @objc func togglePinAction() {
        activeAppState?.togglePin()
    }

    @objc func toggleShowBorderAction() {
        guard activeAppState?.isFullScreen != true else { return }
        activeAppState?.showBorder.toggle()
    }

    @objc func toggleFullScreenAction() {
        activeWindowController?.toggleFullScreen()
    }

    @objc func toggleNavigatorPanelAction() {
        guard let appState = activeAppState, !appState.navigatorContributions.isEmpty else { return }
        let next: NavigatorPanelVisibilityMode = appState.navigatorPanelVisibilityMode == .always ? .onHover : .always
        appState.navigatorPanelVisibilityMode = next
        SettingsStore.shared.navigatorPanelVisibilityMode = next
        if next != .always {
            appState.isNavigatorPanelExplicitlyVisible = false
        }
    }

    @objc func placeNavigatorOnLeftAction() {
        activeAppState?.navigatorPanelSide = .left
        SettingsStore.shared.navigatorPanelSide = .left
    }

    @objc func placeNavigatorOnRightAction() {
        activeAppState?.navigatorPanelSide = .right
        SettingsStore.shared.navigatorPanelSide = .right
    }

    @objc func reloadPageAction() {
        guard let appState = activeAppState, appState.webURL != nil else { return }
        NotificationCenter.default.post(
            name: Notification.Name("reloadWebView_\(appState.id.uuidString)"),
            object: nil
        )
    }

    @objc func captureImageFoofoilAction() {
        guard let appState = activeAppState, appState.webURL != nil else { return }
        NotificationCenter.default.post(
            name: Notification.Name("captureImageFoofoil_\(appState.id.uuidString)"),
            object: nil
        )
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        var filePaths: [String] = []
        for url in urls {
            if url.scheme == "foofoil" {
                if url.host == "open-clipboard" {
                    NSApp.activate(ignoringOtherApps: true)
                    _ = openClipboardContentInNewWindow()
                }
            } else if url.isFileURL {
                filePaths.append(url.path)
            }
        }
        if !filePaths.isEmpty {
            self.application(application, openFiles: filePaths)
        }
    }

    @objc func handleCreateNewFoofoilFromImage(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let id = userInfo["id"] as? UUID,
              let imageURL = userInfo["imageURL"] as? URL,
              let originalName = userInfo["originalName"] as? String else {
            return
        }

        let config = WindowConfig(
            id: id,
            imagePath: imageURL.path,
            originalImageName: originalName,
            showBorder: false,
            createdAt: Date()
        )

        let newState = AppState(config: config)

        // 显示新窗口
        showNewWindow(with: newState)

        // 保存新状态并将其加入历史记录
        newState.saveState()
    }

    @objc func selectColorAction() {
        activeAppState?.showColorPanel()
    }

    @objc func backgroundColorAction() {
        activeAppState?.showBackgroundColorPanel()
    }

    @objc func previousPDFPageAction() {
        postPDFNavigationNotification(.shouldGoToPreviousPDFPage)
    }

    @objc func nextPDFPageAction() {
        postPDFNavigationNotification(.shouldGoToNextPDFPage)
    }

    @objc func previousFileListItemAction() {
        activeAppState?.activateAdjacentFileListItem(delta: -1)
    }

    @objc func nextFileListItemAction() {
        activeAppState?.activateAdjacentFileListItem(delta: 1)
    }

    @objc func findNavigatorAction() {
        activeAppState?.focusNavigatorSearch()
    }

    @objc func findNavigatorNextAction() {
        activeAppState?.advanceNavigatorSearchMatch(delta: 1)
    }

    @objc func findNavigatorPreviousAction() {
        activeAppState?.advanceNavigatorSearchMatch(delta: -1)
    }

    @objc func toggleImageListSlideshowAction() {
        activeAppState?.toggleImageListSlideshow()
    }

    @objc func goToPDFPageAction() {
        postPDFNavigationNotification(.shouldPromptForPDFPage)
    }

    func postPDFNavigationNotification(_ name: Notification.Name) {
        guard let appState = activeAppState, appState.isPDFDocument else { return }
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["id": appState.id])
    }



    @objc func increaseOpacityAction() {
        activeAppState?.increaseOpacity()
    }

    @objc func decreaseOpacityAction() {
        activeAppState?.decreaseOpacity()
    }

    @objc func chooseOpacityAction(_ sender: NSMenuItem) {
        if let val = sender.representedObject as? Double {
            activeAppState?.opacity = val
        }
    }

    @objc func zoomInAction() {
        activeWindowController?.zoomIn()
    }

    @objc func zoomOutAction() {
        activeWindowController?.zoomOut()
    }

    @objc func actualSizeAction() {
        activeWindowController?.actualSize()
    }

    @objc func fitWindowToImageAction() {
        guard let appState = activeAppState,
              appState.imageURL != nil && appState.webURL == nil,
              appState.effectiveShowBorder else { return }
        activeWindowController?.fitWindowToCurrentImageSize()
    }

    @objc func fitImageToWindowWidthAction() {
        guard let appState = activeAppState,
              appState.imageURL != nil && appState.webURL == nil,
              appState.effectiveShowBorder else { return }
        activeWindowController?.fitImageToWindowWidth()
    }

    @objc func zoomOutWindowAction() {
        guard let appState = activeAppState, !appState.isFullScreen else { return }
        let isImageMode = appState.imageURL != nil && appState.webURL == nil
        if isImageMode {
            if appState.showBorder {
                activeWindowController?.zoomOutWindow()
            } else {
                activeWindowController?.zoomOut()
            }
        } else {
            activeWindowController?.zoomOutWindow()
        }
    }

    @objc func zoomInWindowAction() {
        guard let appState = activeAppState, !appState.isFullScreen else { return }
        let isImageMode = appState.imageURL != nil && appState.webURL == nil
        if isImageMode {
            if appState.showBorder {
                activeWindowController?.zoomInWindow()
            } else {
                activeWindowController?.zoomIn()
            }
        } else {
            activeWindowController?.zoomInWindow()
        }
    }

    // MARK: - Window Positioning Actions

    @objc func moveToTopLeftAction() {
        activeWindowController?.moveWindow(to: .topLeft)
    }

    @objc func moveToTopAction() {
        activeWindowController?.moveWindow(to: .top)
    }

    @objc func moveToTopRightAction() {
        activeWindowController?.moveWindow(to: .topRight)
    }

    @objc func moveToLeftAction() {
        activeWindowController?.moveWindow(to: .left)
    }

    @objc func moveToCenterAction() {
        activeWindowController?.moveWindow(to: .center)
    }

    @objc func moveToRightAction() {
        activeWindowController?.moveWindow(to: .right)
    }

    @objc func moveToBottomLeftAction() {
        activeWindowController?.moveWindow(to: .bottomLeft)
    }

    @objc func moveToBottomAction() {
        activeWindowController?.moveWindow(to: .bottom)
    }

    @objc func moveToBottomRightAction() {
        activeWindowController?.moveWindow(to: .bottomRight)
    }

    @objc func moveToNextScreenAction() {
        activeWindowController?.moveToNextScreen()
    }
}
