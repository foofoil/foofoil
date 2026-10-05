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

    @discardableResult
    func showNewWindow(with state: AppState) -> FloatingWindowController {
        let controller = FloatingWindowController(appState: state)
        prepareNewWindowFrame(for: controller)
        addWindowController(controller)
        controller.showWindow(nil)
        return controller
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

        if appState.isCamera {
            let id = appState.id
            appState.cameraController?.capture { [weak appState] image in
                guard let appState, appState.id == id, appState.isCamera, let image else { return }
                NotificationCenter.default.post(name: Notification.Name("flashWindow_\(id.uuidString)"), object: nil)
                appState.saveWebScreenshot(image, triggerSavePanel: true)
            }
        } else if let webURL = appState.webURL, !webURL.isFileURL {
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

        // 摄像头截图使用本地时间后缀；新打开的箔片名称及历史标题不随保存动作改变。
        if appState.isCamera {
            guard appState.imageURL != nil else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            defaultName = NSLocalizedString("Camera Foil", comment: "") + "_" + formatter.string(from: Date()) + ".png"
            allowedTypes = [.png]
        // 网页模式优先于其截图缓存。
        } else if let webURL = appState.webURL {
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
        // 无箔窗口时同样弹出选择面板；选中的文件在确认后由 openGroupedFiles 落入新开的箔片。
        let appState = activeAppState
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        // Quick Look 接管其它文件类型，选择面板不再维护格式白名单。
        panel.treatsFilePackagesAsDirectories = false

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
    @discardableResult
    func openGroupedFiles(_ urls: [URL], into target: AppState?, append: Bool) -> Bool {
        let probe = target ?? AppState()
        let openable = urls.filter { probe.canOpenFile(url: $0) }
        var groups = FileListGrouper.groups(from: openable)
        guard !groups.isEmpty else { return false }

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
            return true
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
        return true
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
            let remaining = target.consumeDroppedImagesAsAudioCover(
                from: urls,
                directorySourced: DroppedFileResolver.containsDirectory(in: urls)
            )
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

    /// 直接打开剪贴板内容：文件/文件夹/图片复用拖入箔片的处理管线，文本按 Markdown / 网址 / HTML / 笔记区分。
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
            // 剪贴板内容整体是一个网址时直接作为网站打开，不落为纯文本笔记。
            if let url = AppState.websiteURL(fromClipboardText: text) {
                let target = clipboardContentTarget()
                target.state.openWeb(url: url)
                presentClipboardTarget(target)
                return true
            }
            if let html = clipboardHTML(from: pasteboard) ?? (AppState.looksLikeHTML(text) ? text : nil) {
                return openClipboardHTML(html, plainText: text)
            }
            let target = clipboardContentTarget()
            target.state.openText(text, isMarkdown: false)
            presentClipboardTarget(target)
            return true
        }

        // 只有 HTML 表示、没有可读纯文本时仍按网页打开。
        guard let html = clipboardHTML(from: pasteboard) else { return false }
        return openClipboardHTML(html, plainText: nil)
    }

    private func openClipboardHTML(_ html: String, plainText: String?) -> Bool {
        let target = clipboardContentTarget()
        // HTML 片段没有可靠网页标题，历史标题取粘贴文本开头的摘要。
        let fallbackName = NSLocalizedString("Clipboard Web Page", comment: "")
        let title = AppState.clipboardHTMLTitle(html: html, plainText: plainText) ?? fallbackName
        guard target.state.openHTML(html, originalName: title) else {
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

    func clipboardFileURLs(from pasteboard: NSPasteboard = .general) -> [URL] {
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

    /// 覆盖层提示用：与 openClipboardContentInNewWindow 走同一条判定顺序（文件 → 图片 → 文本/HTML），
    /// 返回剪贴板当前会打开成的内容类型；没有可打开内容时返回 nil，提示随之隐藏。
    func clipboardOpenableContent() -> ClipboardOpenableContent? {
        let fileURLs = clipboardFileURLs()
        if !fileURLs.isEmpty {
            return ClipboardOpenableContent.forFileURLs(fileURLs)
        }
        if clipboardImage() != nil { return ClipboardOpenableContent(.image) }
        let pasteboard = NSPasteboard.general
        let declaredMarkdown = Self.markdownPasteboardTypes
            .compactMap { pasteboard.availableType(from: [$0]) }
            .first
            .flatMap { pasteboard.string(forType: $0) }
        return ClipboardOpenableContent.forText(
            declaredMarkdown: declaredMarkdown,
            plainText: pasteboard.string(forType: .string),
            html: clipboardHTML(from: pasteboard)
        )
    }

    @objc func resetContentAction() {
        activeAppState?.resetContent()
    }

    @objc func closeWindowAction() {
        // 设置、关于等带关闭按钮的窗口走系统 performClose；箔窗口是无边框，仍由控制器关闭。
        if closeStandardKeyWindow(NSApplication.shared.keyWindow) {
            return
        }
        guard let controller = activeWindowController else { return }
        // 音频播放中先确认关闭还是隐藏，避免误关导致音乐中断。
        guard confirmClosingPlayingAudio(for: controller.appState) else { return }
        controller.close()
    }

    /// 音频播放中按 ⌘W：询问是关闭还是隐藏，避免误关导致音乐中断。
    /// 返回 true 表示继续关闭箔片；选择隐藏或取消则返回 false。
    func confirmClosingPlayingAudio(for appState: AppState) -> Bool {
        guard appState.isAudioDocument,
              appState.isMediaPlaying,
              SettingsStore.shared.confirmClosingPlayingAudio else { return true }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Close Playing Audio Title", comment: "")
        alert.informativeText = NSLocalizedString("Close Playing Audio Message", comment: "")
        alert.alertStyle = .informational
        // 默认按钮放在隐藏上：隐藏不中断播放，是更安全的选择。
        alert.addButton(withTitle: NSLocalizedString("Hide foofoil", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Close foofoil", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = NSLocalizedString("Do Not Ask Again", comment: "")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        // 勾选“不再提示”与设置面板共用同一个偏好项。
        if alert.suppressionButton?.state == .on {
            SettingsStore.shared.confirmClosingPlayingAudio = false
        }

        switch response {
        case .alertFirstButtonReturn:
            hideApplicationKeepingAudioPlaying()
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// 选择隐藏后先说明 ⌘H：隐藏让音乐继续播放，下次可直接按 ⌘H 而不必关闭箔片。
    private func hideApplicationKeepingAudioPlaying() {
        let hint = NSAlert()
        hint.messageText = NSLocalizedString("Audio Hidden Hint Title", comment: "")
        hint.informativeText = NSLocalizedString("Audio Hidden Hint Message", comment: "")
        hint.alertStyle = .informational
        hint.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        hint.runModal()
        NSApp.hide(nil)
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

    /// 把导航面板移到另一侧；菜单栏 ⇧⌘L/⌥⌘L 家族中的换边动作，与面板右键菜单一致。
    @objc func moveNavigatorToOppositeSideAction() {
        guard let appState = activeAppState, !appState.navigatorContributions.isEmpty else { return }
        let next: NavigatorPanelSide = appState.navigatorPanelSide == .left ? .right : .left
        appState.navigatorPanelSide = next
        SettingsStore.shared.navigatorPanelSide = next
    }

    @objc func reloadPageAction() {
        guard let appState = activeAppState, appState.webURL != nil else { return }
        NotificationCenter.default.post(
            name: Notification.Name("reloadWebView_\(appState.id.uuidString)"),
            object: nil
        )
    }

    @objc func captureImageFoofoilAction() {
        guard let appState = activeAppState else { return }
        if appState.isCamera {
            let id = appState.id
            appState.cameraController?.capture { [weak appState] image in
                guard let appState, appState.id == id, appState.isCamera, let image else { return }
                NotificationCenter.default.post(name: Notification.Name("flashWindow_\(id.uuidString)"), object: nil)
                appState.createNewFoofoilFromScreenshot(image: image, backingScaleFactor: 1)
            }
            return
        }
        guard appState.webURL != nil else { return }
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

    @objc func extractTextFromImageAction() {
        guard let appState = activeAppState else { return }
        extractTextFromImage(from: appState)
    }

    /// 对图片箔运行系统 Vision OCR，识别到文字后在新箔片中以纯文本打开。
    /// OCR 结果已在图片载入检测时缓存，这里直接复用；仅在缓存缺失时才重跑一次。
    func extractTextFromImage(from appState: AppState) {
        guard appState.canExtractImageText,
              let imageURL = appState.imageURL,
              !appState.isExtractingText else { return }
        if let cached = appState.imageOCRText?.trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
            presentExtractedText(cached)
            return
        }
        appState.isExtractingText = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak appState] in
            let recognized = ((try? ImageOCRIndexer.recognize(url: imageURL)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                appState?.isExtractingText = false
                guard let self, !recognized.isEmpty else { return }
                // 回填缓存，后续提取与重开历史都无需再跑 OCR。
                appState?.imageOCRText = recognized
                appState?.hasExtractableImageText = true
                appState?.imageTextDetectedURL = imageURL
                appState?.saveState()
                self.presentExtractedText(recognized)
            }
        }
    }

    /// 把识别到的文字在新箔片中以纯文本打开，复用"新建空白箔"的窗口通道。
    private func presentExtractedText(_ recognized: String) {
        let state = AppState()
        state.openText(recognized, isMarkdown: false)
        showNewWindow(with: state)
    }

    @objc func extractImageSubjectAction() {
        guard let appState = activeAppState else { return }
        extractImageSubject(from: appState)
    }

    /// 用系统 Vision 的前景实例掩码抠出主体，写成带透明的 PNG，再在新的无边框箔片里打开。
    /// 抠图已在图片载入检测时生成并缓存，这里直接复制；仅在缓存缺失时才重跑一次。
    func extractImageSubject(from appState: AppState) {
        guard appState.canExtractImageSubject,
              let sourceURL = appState.imageURL,
              !appState.isExtractingImageSubject else { return }
        let newID = UUID()
        guard let destURL = appState.getCachedImageURL(for: newID, extension: "png") else { return }
        let originalName = appState.originalImageName ?? sourceURL.lastPathComponent

        if let cachedCutout = appState.imageSubjectCutoutURL,
           FileManager.default.fileExists(atPath: cachedCutout.path) {
            appState.isExtractingImageSubject = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak appState] in
                let copied = Self.copyCacheFile(from: cachedCutout, to: destURL)
                DispatchQueue.main.async {
                    appState?.isExtractingImageSubject = false
                    guard let self, copied else { return }
                    self.postExtractedSubjectFoofoil(id: newID, imageURL: destURL, originalName: originalName)
                }
            }
            return
        }

        appState.isExtractingImageSubject = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak appState] in
            let extracted = ImageSubjectExtractor.writeSubjectPNG(from: sourceURL, to: destURL)
            DispatchQueue.main.async {
                appState?.isExtractingImageSubject = false
                guard let self, extracted else { return }
                self.postExtractedSubjectFoofoil(id: newID, imageURL: destURL, originalName: originalName)
            }
        }
    }

    /// 派生缓存到新箔片资源的文件复制；同名目标已存在时先移除再复制。
    nonisolated private static func copyCacheFile(from source: URL, to dest: URL) -> Bool {
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.copyItem(at: source, to: dest)
            return true
        } catch {
            return false
        }
    }

    /// 主体抠图写入新箔片后，走既有的"从图片新建箔片"通道发布。
    private func postExtractedSubjectFoofoil(id: UUID, imageURL: URL, originalName: String) {
        NotificationCenter.default.post(
            name: .createNewFoofoilFromImage,
            object: nil,
            userInfo: [
                "id": id,
                "imageURL": imageURL,
                "originalName": String(format: NSLocalizedString("Image Subject: %@", comment: ""), originalName)
            ]
        )
    }

    @objc func documentStyleAction() {
        guard let appState = activeAppState else { return }
        guard appState.supportsContentBackgroundColor || appState.supportsDocumentTextStyling else { return }
        DocumentStylePanelController.shared.show(for: appState)
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

/// 剪贴板内容按打开规则归出的类型：覆盖层提示里的类型名取自这里，
/// 判定与 openClipboardContentInNewWindow 保持一致，保证“提示什么就打开什么”。
struct ClipboardOpenableContent: Equatable {
    enum Kind: Equatable {
        case folder, file, image, imageList, audio, audioList, video, videoList, pdf, web, htmlFragment, website, markdown, text

        /// 提示文案中的基础类型名（“打开剪贴板里的图片”中的“图片”）。
        var localizedName: String {
            switch self {
            case .folder: return NSLocalizedString("Clipboard Type Folder", comment: "")
            case .file: return NSLocalizedString("File", comment: "")
            case .image: return NSLocalizedString("Clipboard Type Image", comment: "")
            case .imageList: return NSLocalizedString("Image List", comment: "")
            case .audio: return NSLocalizedString("Clipboard Type Audio", comment: "")
            case .audioList: return NSLocalizedString("Audio List", comment: "")
            case .video: return NSLocalizedString("Video", comment: "")
            case .videoList: return NSLocalizedString("Video List", comment: "")
            case .pdf: return NSLocalizedString("Clipboard Type PDF", comment: "")
            case .web: return NSLocalizedString("Clipboard Type Web Page", comment: "")
            case .htmlFragment: return NSLocalizedString("Clipboard Type HTML Fragment", comment: "")
            case .website: return NSLocalizedString("Clipboard Type Website", comment: "")
            case .markdown: return NSLocalizedString("Clipboard Type Markdown", comment: "")
            case .text: return NSLocalizedString("Clipboard Type Text", comment: "")
            }
        }
    }

    let kind: Kind
    /// 文件来源内容的扩展名（小写、不含点），如 “flac”、“log”；组内扩展名不一致或不是文件来源时为 nil。
    let fileExtension: String?

    init(_ kind: Kind, fileExtension: String? = nil) {
        self.kind = kind
        self.fileExtension = fileExtension
    }

    /// 提示文案中的类型名：文件来源带上扩展名（如 “.flac音频”、“.log文本”），其余只显示类型名。
    var localizedName: String {
        let base = kind.localizedName
        guard let fileExtension, !fileExtension.isEmpty else { return base }
        return String(
            format: NSLocalizedString("Clipboard Type With Extension Format", comment: ""),
            "." + fileExtension,
            base
        )
    }

    /// 组内文件扩展名一致时返回它（小写）；不一致或没有扩展名时返回 nil。
    nonisolated static func commonExtension(of urls: [URL]) -> String? {
        let extensions = Set(urls.map { $0.pathExtension.lowercased() })
        guard extensions.count == 1, let ext = extensions.first, !ext.isEmpty else { return nil }
        return ext
    }

    /// 文件分支：与 openClipboardFileURLs → handleDroppedFileURLs 的分组选择一致；
    /// 目录打开的是其内容，先按“文件夹”提示；没有可打开文件时返回 nil（与实际打开结果一致：无动作）。
    @MainActor
    static func forFileURLs(_ urls: [URL]) -> ClipboardOpenableContent? {
        if DroppedFileResolver.containsDirectory(in: urls) { return ClipboardOpenableContent(.folder) }
        let probe = AppState()
        let openable = urls.filter { probe.canOpenFile(url: $0) }
        guard let group = FileListGrouper.groups(from: openable).first,
              let firstURL = group.urls.first else { return nil }
        let ext = commonExtension(of: group.urls)
        switch group.kind {
        case .listable(.audio):
            return ClipboardOpenableContent(group.urls.count > 1 ? .audioList : .audio, fileExtension: ext)
        case .cueSheets:
            return ClipboardOpenableContent(.audio, fileExtension: ext)
        case .listable(.video):
            return ClipboardOpenableContent(group.urls.count > 1 ? .videoList : .video, fileExtension: ext)
        case .listable(.image):
            return ClipboardOpenableContent(group.urls.count > 1 ? .imageList : .image, fileExtension: ext)
        case .other:
            switch FileListGrouper.dropKind(url: firstURL) {
            // PDF 的类型名本身已是扩展名，不再重复前缀。
            case .pdf: return ClipboardOpenableContent(.pdf)
            case .web: return ClipboardOpenableContent(.web, fileExtension: ext)
            case .text:
                // 与 openTextFile 一致：md/markdown 后缀进入 Markdown 预览，其余按文本。
                let isMarkdown = ["md", "markdown"].contains(firstURL.pathExtension.lowercased())
                return ClipboardOpenableContent(isMarkdown ? .markdown : .text, fileExtension: ext)
            case .image: return ClipboardOpenableContent(.image, fileExtension: ext)
            case .video: return ClipboardOpenableContent(.video, fileExtension: ext)
            case .audio: return ClipboardOpenableContent(.audio, fileExtension: ext)
            case .other: return ClipboardOpenableContent(.file, fileExtension: ext)
            }
        }
    }

    /// 文本分支：与 openClipboardText 的 Markdown → 网址 → HTML → 笔记顺序一致。
    nonisolated static func forText(
        declaredMarkdown: String?,
        plainText: String?,
        html: String?
    ) -> ClipboardOpenableContent? {
        let isDeclaredMarkdown = !(declaredMarkdown?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let text = isDeclaredMarkdown ? declaredMarkdown : plainText
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isDeclaredMarkdown || AppState.looksLikeMarkdown(text) { return ClipboardOpenableContent(.markdown) }
            if AppState.websiteURL(fromClipboardText: text) != nil { return ClipboardOpenableContent(.website) }
            if html != nil || AppState.looksLikeHTML(text) { return ClipboardOpenableContent(.htmlFragment) }
            return ClipboardOpenableContent(.text)
        }
        return html == nil ? nil : ClipboardOpenableContent(.htmlFragment)
    }
}
