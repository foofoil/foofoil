//  AppDelegate+Actions.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//

import OSLog
import SwiftUI
import UniformTypeIdentifiers
import Combine
import WebKit
import FoofoilExtensionKit


extension AppDelegate {
    // MARK: - Actions

    @objc func newIncognitoWindowAction() {
        showNewWindow(with: AppState(isIncognito: true))
    }

    @objc func openClipboardIncognitoAction() {
        _ = openClipboardContentInNewWindow(isIncognito: true)
    }

    @objc func newWindowAction() {
        showNewWindow(with: AppState())
    }

    /// 根据当前快捷键生成 Markdown，一览沿用文本内容与历史记录管线。
    @objc func showKeyboardShortcutsOverviewAction() {
        if activateOpenHelpDocument(sourceFingerprint: KeyboardShortcutsOverview.sourceFingerprint,
                                    titleKey: "Keyboard Shortcuts Overview",
                                    markdown: KeyboardShortcutsOverview.markdown()) { return }
        let target = clipboardContentTarget()
        target.state.openKeyboardShortcutsOverview()
        presentClipboardTarget(target)
    }

    @objc func showFoilCommandsOverviewAction() {
        if activateOpenHelpDocument(sourceFingerprint: FoilCommandsOverview.sourceFingerprint,
                                    titleKey: "Foil Commands Overview",
                                    markdown: FoilCommandsOverview.markdown()) { return }
        let target = clipboardContentTarget()
        target.state.openFoilCommandsOverview()
        presentClipboardTarget(target)
    }

    @objc func showSupportedContentOverviewAction() {
        if activateOpenHelpDocument(sourceFingerprint: SupportedContentOverview.sourceFingerprint,
                                    titleKey: "Supported Content Overview",
                                    markdown: SupportedContentOverview.markdown()) { return }
        let target = clipboardContentTarget()
        target.state.openSupportedContentOverview()
        presentClipboardTarget(target)
    }

    /// 同一帮助文档只保留一张打开的箔；刷新时保留历史身份和用户的窗口/阅读样式。
    private func activateOpenHelpDocument(sourceFingerprint: String, titleKey: String, markdown: String) -> Bool {
        guard let controller = windowControllers.first(where: { $0.appState.sourceFingerprint == sourceFingerprint }) else { return false }
        let state = controller.appState
        state.text = markdown
        state.originalImageName = NSLocalizedString(titleKey, comment: "") + ".md"
        state.saveState()
        if controller.window?.isMiniaturized == true {
            controller.window?.deminiaturize(nil)
        }
        activateWindow(controller)
        controller.window?.orderFrontRegardless()
        return true
    }

    @objc func showSettingsAction() {
        SettingsWindowController.shared.show()
    }

    @objc func extensionCommandAction(_ sender: NSMenuItem) {
        guard let commandID = sender.representedObject as? String else { return }
        activeReadingState?.performExtensionCommand(commandID)
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

    @objc func captureVideoFrameAction() {
        guard let state = activeReadingState, state.isVideoDocument else { return }
        NotificationCenter.default.post(name: VideoFrameCapture.notification(for: state.id), object: nil)
    }

    @objc func saveContentImageAction() {
        guard let state = activeReadingState, state.canSaveContentImage else { return }
        if state.isVideoDocument {
            captureVideoFrameAction()
        } else if state.isCamera {
            let name = state.contentImageName
            let id = state.id
            state.cameraController?.capture { [weak self] image in
                guard let image else { return }
                if state.id == id, state.isCamera {
                    NotificationCenter.default.post(name: Notification.Name("flashWindow_\(id.uuidString)"), object: nil)
                    state.saveWebScreenshot(image)
                }
                self?.presentContentImagePanel(image, name: name)
            }
        } else if let image = state.audioCoverImage {
            presentContentImagePanel(image, name: state.contentImageName)
        } else if state.webURL != nil {
            NotificationCenter.default.post(
                name: Notification.Name("triggerSaveSnapshot_\(state.id.uuidString)"), object: nil)
        } else if let root = activeWindowController?.window?.contentView {
            let name = state.contentImageName
            Task { @MainActor in
                do {
                    let image = try await FoilContentCapture.capture(in: root, state: state)
                    presentContentImagePanel(image, name: name)
                } catch { showSaveErrorAlert(error) }
            }
        }
    }

    @objc func saveAsAction() {
        if activeAppState?.savesClipboardImageAsContentImage == true {
            saveContentImageAction()
            return
        }
        if let archive = activeAppState?.selectedArchiveSession { archive.saveSelected(); return }
        guard let state = activeAppState, let content = state.contentSavePayload else { return }
        if case .webArchive = content {
            NotificationCenter.default.post(
                name: Notification.Name("saveWebArchive_\(state.id.uuidString)"), object: nil)
        } else {
            presentContentSavePanel(content,
                name: state.contentSaveName,
                title: state.saveAsTitle)
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
        guard let appState = activeReadingState,
              let url = appState.actualWebURL ?? appState.webURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func copyWebURLAction() {
        guard let appState = activeReadingState,
              let url = appState.actualWebURL ?? appState.webURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(url.absoluteString, forType: .string) {
            appState.toast.show(NSLocalizedString("Link Copied Toast", comment: ""), symbolName: "checkmark")
        }
    }

    @objc func openFileAction() {
        let target = activeAppState.flatMap { $0.isIncognito ? availableBlankWindowController?.appState : $0 }
        openContentPanel(directory: false, target: target)
    }

    @objc func openDirectoryAction() {
        let target = activeAppState.flatMap { $0.isIncognito ? availableBlankWindowController?.appState : $0 }
        openContentPanel(directory: true, target: target)
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
        if kind == .video {
            contentTypes.append(contentsOf: ExtensionHost.shared.additionalContentTypes(for: .video))
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
        openGroupedFiles(urls, into: target, append: append,
                         feedbackBatchID: notification.userInfo?["feedbackBatchID"] as? UUID ?? UUID())
    }

    /// 按同类型分组打开：第一组进入目标箔片（或新窗口），其余组另开箔片。
    @discardableResult
    func openGroupedFiles(_ urls: [URL], into target: AppState?, append: Bool, feedbackBatchID: UUID = UUID()) -> Bool {
        let probe = target ?? AppState()
        probe.fileOpenFeedbackBatchID = feedbackBatchID
        let urls = probe.filterFileOpenFailures(urls)
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
                openGroupInNewWindow(group, feedbackBatchID: probe.fileOpenFeedbackBatchID, isIncognito: probe.isIncognito)
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
            openGroupInNewWindow(first, feedbackBatchID: probe.fileOpenFeedbackBatchID, isIncognito: probe.isIncognito)
        }
        for group in groups {
            openGroupInNewWindow(group, feedbackBatchID: probe.fileOpenFeedbackBatchID, isIncognito: probe.isIncognito)
        }
        return true
    }

    /// Finder 拖到 Dock 图标时与箔片内拖放保持一致：非空箔片只接收当前类型。
    func openDroppedFiles(_ urls: [URL], into target: AppState?, feedbackBatchID: UUID = UUID()) {
        let probe = target ?? AppState()
        probe.fileOpenFeedbackBatchID = feedbackBatchID
        let urls = probe.filterFileOpenFailures(urls)
        guard !urls.isEmpty else { return }
        guard let target else {
            let state = AppState()
            guard state.handleDroppedFileURLs(urls, feedbackBatchID: feedbackBatchID) else { return }
            showNewWindow(with: state)
            return
        }

        if isBlank(target) {
            guard target.handleDroppedFileURLs(urls, feedbackBatchID: feedbackBatchID) else { return }
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
            let matching = target.matchingDroppedFiles(urls: remaining)
            let paths = Set(matching.map(\.path))
            target.reportFileOpenFeedback(remaining.filter { !paths.contains($0.path) }.map { .init(url: $0, reason: .differentType) })
            guard target.appendMatchingDroppedFiles(urls: matching) || consumedCover else { return }
        } else {
            let matching = target.matchingDroppedFiles(urls: urls)
            let paths = Set(matching.map(\.path))
            target.reportFileOpenFeedback(urls.filter { !paths.contains($0.path) }.map { .init(url: $0, reason: .differentType) })
            guard !matching.isEmpty else { return }
            openGroupedFiles(matching, into: target, append: false, feedbackBatchID: probe.fileOpenFeedbackBatchID)
        }

        if let controller = windowControllers.first(where: { $0.appState === target }) {
            activateWindow(controller)
        }
    }

    func openGroupInNewWindow(_ group: FileListGroup, feedbackBatchID: UUID = UUID(), isIncognito: Bool = false) {
        let state = AppState(isIncognito: isIncognito)
        state.fileOpenFeedbackBatchID = feedbackBatchID
        state.closesEmptyWindowAfterFileOpenFailure = true
        state.openFileGroup(group, preservesIdentity: true)
        showNewWindow(with: state)
    }

    @objc func openWebURLAction() {
        HistorySearchWindowController.shared.showURLInput()
    }

    /// 在空白窗口中打开网页；若没有空白窗口，则创建新窗口。
    public func openWebURLInPreferredWindow(_ url: URL) {
        appleMusicLinkTask?.cancel()
        appleMusicLinkTask = nil
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
        // 普通命令始终有痕；无痕由明确入口或派生快捷键决定。
        _ = openClipboardContentInNewWindow(isIncognito: false)
    }

    /// 直接打开剪贴板内容：文件/文件夹/图片复用拖入箔片的处理管线，文本按 Markdown / 网址 / HTML / 笔记区分。
    @discardableResult
    func openClipboardContentInNewWindow(isIncognito: Bool = false) -> Bool {
        appleMusicLinkTask?.cancel()
        appleMusicLinkTask = nil
        let fileURLs = clipboardFileURLs()
        if !fileURLs.isEmpty {
            return openClipboardFileURLs(fileURLs, isIncognito: isIncognito)
        }

        if let image = clipboardImage() {
            let target = clipboardContentTarget(isIncognito: isIncognito)
            let representation = Self.clipboardImageRepresentation(from: .general)
            target.state.openImage(image: image, imageSource: .clipboard,
                                   originalData: representation?.data, filenameExtension: representation?.ext ?? "png")
            presentClipboardTarget(target)
            return true
        }

        return openClipboardText(from: NSPasteboard.general, isIncognito: isIncognito)
    }

    /// 从搜索快照打开，不把历史内容写回 NSPasteboard.general，避免改变 Spotlight 历史。
    @discardableResult
    func openClipboardSearchEntry(_ entry: ClipboardSearchEntry, isIncognito: Bool = false) -> Bool {
        switch entry.content {
        case .unavailable: return false
        case .files(let urls): return openClipboardFileURLs(urls, isIncognito: isIncognito)
        case .html(let html, let plain):
            if let plain, AppState.looksLikeMarkdown(plain) {
                let target = clipboardContentTarget(isIncognito: isIncognito)
                target.state.openText(plain, isMarkdown: true); presentClipboardTarget(target); return true
            }
            return openClipboardHTML(html, plainText: plain, isIncognito: isIncognito)
        case .image(let data):
            guard let image = NSImage(data: data) else { return false }
            let target = clipboardContentTarget(isIncognito: isIncognito)
            target.state.openImage(image: image, imageSource: .clipboard, originalData: data,
                                   filenameExtension: entry.imageFilenameExtension ?? "png")
            presentClipboardTarget(target); return true
        case .markdown(let text):
            let target = clipboardContentTarget(isIncognito: isIncognito)
            target.state.openText(text, isMarkdown: true); presentClipboardTarget(target); return true
        case .text(let text):
            if let url = AppState.websiteURL(fromClipboardText: text), SettingsStore.shared.appleMusicLibraryEnabled, AppleMusicLink(url: url) != nil {
                openAppleMusicLink(url, isIncognito: isIncognito); return true
            }
            let target = clipboardContentTarget(isIncognito: isIncognito)
            if let url = AppState.websiteURL(fromClipboardText: text) { target.state.openWeb(url: url) }
            else if AppState.looksLikeHTML(text) { return openClipboardHTML(text, plainText: nil, isIncognito: isIncognito) }
            else { target.state.openText(text, isMarkdown: AppState.looksLikeMarkdown(text)) }
            presentClipboardTarget(target); return true
        }
    }

    /// 剪贴板文件与拖入箔片走同一条管线；没有空白箔片时新建一扇再接管。
    func openClipboardFileURLs(_ urls: [URL], isIncognito: Bool = false) -> Bool {
        let probe = AppState()
        let urls = probe.filterFileOpenFailures(urls)
        guard !urls.isEmpty else { return true }
        if let controller = blankWindowController(isIncognito: isIncognito) {
            guard controller.appState.handleDroppedFileURLs(urls, feedbackBatchID: probe.fileOpenFeedbackBatchID) else { return false }
            activateWindow(controller)
            return true
        }

        // 多个文件分组会通过通知回到源窗口，先把控制器登记进窗口表再交给拖放管线。
        let state = AppState(isIncognito: isIncognito)
        state.closesEmptyWindowAfterFileOpenFailure = true
        let controller = FloatingWindowController(appState: state)
        prepareNewWindowFrame(for: controller)
        addWindowController(controller)
        guard state.handleDroppedFileURLs(urls, feedbackBatchID: probe.fileOpenFeedbackBatchID) else {
            removeWindowController(controller)
            controller.close()
            return false
        }
        activateWindow(controller)
        return true
    }

    private func openClipboardText(from pasteboard: NSPasteboard, isIncognito: Bool) -> Bool {
        let declaredMarkdownRaw = Self.markdownPasteboardTypes
            .compactMap { pasteboard.availableType(from: [$0]) }
            .first
            .flatMap { pasteboard.string(forType: $0) }
        let isDeclaredMarkdown = !(declaredMarkdownRaw?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let text = isDeclaredMarkdown ? declaredMarkdownRaw : pasteboard.string(forType: .string)

        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isDeclaredMarkdown || AppState.looksLikeMarkdown(text) {
                let target = clipboardContentTarget(isIncognito: isIncognito)
                target.state.openText(text, isMarkdown: true)
                presentClipboardTarget(target)
                return true
            }
            // 剪贴板内容整体是一个网址时直接作为网站打开，不落为纯文本笔记。
            if let url = AppState.websiteURL(fromClipboardText: text) {
                if SettingsStore.shared.appleMusicLibraryEnabled && AppleMusicLink(url: url) != nil {
                    openAppleMusicLink(url, isIncognito: isIncognito)
                    return true
                }
                let target = clipboardContentTarget(isIncognito: isIncognito)
                target.state.openWeb(url: url)
                presentClipboardTarget(target)
                return true
            }
            if let html = clipboardHTML(from: pasteboard) ?? (AppState.looksLikeHTML(text) ? text : nil) {
                return openClipboardHTML(html, plainText: text, isIncognito: isIncognito)
            }
            let target = clipboardContentTarget(isIncognito: isIncognito)
            target.state.openText(text, isMarkdown: false)
            presentClipboardTarget(target)
            return true
        }

        // 只有 HTML 表示、没有可读纯文本时仍按网页打开。
        guard let html = clipboardHTML(from: pasteboard) else { return false }
        return openClipboardHTML(html, plainText: nil, isIncognito: isIncognito)
    }

    private func openClipboardHTML(_ html: String, plainText: String?, isIncognito: Bool) -> Bool {
        let target = clipboardContentTarget(isIncognito: isIncognito)
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

    private func clipboardContentTarget(isIncognito: Bool = false) -> ClipboardContentTarget {
        if let controller = blankWindowController(isIncognito: isIncognito) {
            return ClipboardContentTarget(state: controller.appState, controller: controller)
        }
        return ClipboardContentTarget(state: AppState(isIncognito: isIncognito), controller: nil)
    }

    private func presentClipboardTarget(_ target: ClipboardContentTarget) {
        if let controller = target.controller {
            // 剪贴板 Markdown 预览复用空白箔时，也按只读文档应用初始阅读尺寸。
            if target.state.isMarkdownDocument && target.state.isMarkdownPreview {
                controller.setWindowSize(FloatingWindowController.initialWindowSize(for: target.state), keepWidth: false, animated: false)
            }
            activateWindow(controller)
        } else {
            showNewWindow(with: target.state)
        }
    }

    static let markdownPasteboardTypes: [NSPasteboard.PasteboardType] = [
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

    /// 只读取实际图片数据，不通过 URL 表示下载；保留原始无损或动画表示。
    static func clipboardImageRepresentation(from pasteboard: NSPasteboard) -> (data: Data, ext: String)? {
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.init("com.compuserve.gif"), "gif"), (.init("public.jpeg"), "jpg"), (.tiff, "tiff")] {
            if let data = pasteboard.data(forType: type), NSImage(data: data) != nil { return (data, ext) }
        }
        return nil
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
            html: clipboardHTML(from: pasteboard),
            appleMusicEnabled: SettingsStore.shared.appleMusicLibraryEnabled
        )
    }

    @objc func resetContentAction() {
        guard let state = activeAppState, !state.isBlank else { return }
        if state.terminalSession?.needsCloseConfirmation == true, !TerminalSession.confirmTermination() { return }
        state.resetContent()
    }

    /// 只收起当前箔及其伴随面板，不关闭内容或中断播放；总览仍保留此箔。
    @objc func hideCurrentFoilAction() {
        activeWindowController?.hideFoil()
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
        alert.addButton(withTitle: NSLocalizedString("Hide Current Foil", comment: ""))
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
            hideCurrentFoilKeepingAudioPlaying()
            return false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// 选择隐藏后先说明 ⌘H：隐藏让音乐继续播放，下次可直接按 ⌘H 而不必关闭箔片。
    private func hideCurrentFoilKeepingAudioPlaying() {
        let hint = NSAlert()
        hint.messageText = NSLocalizedString("Audio Hidden Hint Title", comment: "")
        hint.informativeText = NSLocalizedString("Audio Hidden Hint Message", comment: "")
        hint.alertStyle = .informational
        hint.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        hint.runModal()
        hideCurrentFoilAction()
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

    /// 只读代码文件的行号显示；作用于当前活动箔（压缩包内容随所属窗口同步）。
    @objc func toggleCodeLineNumbersAction() {
        guard let appState = activeReadingState, appState.codeLanguageID != nil else { return }
        appState.showCodeLineNumbers.toggle()
    }

    @objc func toggleFullScreenAction() {
        activeWindowController?.toggleFullScreen()
    }

    /// 按 始终显示 → 自动 → 不显示 循环切换侧边栏模式。
    @objc func toggleNavigatorPanelAction() {
        guard let appState = activeAppState, !appState.navigatorContributions.isEmpty else { return }
        appState.cycleNavigatorPanelVisibilityMode()
    }

    /// 子菜单中的单选项：representedObject 为目标模式的原始值。
    @objc func setNavigatorVisibilityModeAction(_ sender: NSMenuItem) {
        guard let appState = activeAppState, !appState.navigatorContributions.isEmpty,
              let raw = sender.representedObject as? String,
              let mode = NavigatorPanelVisibilityMode(rawValue: raw) else { return }
        appState.setNavigatorPanelVisibilityMode(mode)
    }

    /// 把导航面板移到另一侧；菜单栏 ⇧⌘L/⌥⌘L 家族中的换边动作，与面板右键菜单一致。
    @objc func moveNavigatorToOppositeSideAction() {
        guard let appState = activeAppState, !appState.navigatorContributions.isEmpty else { return }
        let next: NavigatorPanelSide = appState.navigatorPanelSide == .left ? .right : .left
        appState.navigatorPanelSide = next
        SettingsStore.shared.navigatorPanelSide = next
    }

    @objc func toggleTerminalHistoryAction() {
        guard let state = activeReadingState, let session = state.terminalSession,
              session.previousOutput != nil else { return }
        session.isPreviousOutputHidden.toggle()
        state.contentSearch.refreshSurface()
    }

    @objc func clearTerminalContentAction() {
        guard let state = activeReadingState, let session = state.terminalSession else { return }
        session.clearContent()
        state.clearPreviousTerminalOutput()
    }

    @objc func reloadPageAction() {
        guard let appState = activeReadingState else { return }
        Task { @MainActor in await appState.reloadContent() }
    }

    @objc func captureImageFoofoilAction() {
        guard let appState = activeReadingState else { return }
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
        ShareDiagnostics.logger.notice("URL receive: \(urls.count, privacy: .public) items")
        var filePaths: [String] = []
        for url in urls {
            if let shared = SharedContentLink(url: url) {
                let isIncognito = SharedContentLink.isIncognito(url)
                didOpenFiles = true
                NSApp.activate(ignoringOtherApps: true)
                switch shared {
                case .website(let website): openSharedWebsite(website, isIncognito: isIncognito)
                case .text(let text):
                    if let website = AppState.websiteURL(fromClipboardText: text) { openSharedWebsite(website, isIncognito: isIncognito) }
                    else {
                        let state = AppState(isIncognito: isIncognito)
                        if AppState.looksLikeHTML(text) { _ = state.openHTML(text, originalName: NSLocalizedString("Untitled Page", comment: ""), isClipboard: false) }
                        else { state.openText(text, isMarkdown: AppState.looksLikeMarkdown(text), isClipboard: false) }
                        showNewWindow(with: state)
                    }
                }
            } else if url.scheme == "foofoil" {
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

    private func openSharedWebsite(_ url: URL, isIncognito: Bool = false) {
        if SettingsStore.shared.appleMusicLibraryEnabled && AppleMusicLink(url: url) != nil {
            openAppleMusicLink(url, isIncognito: isIncognito)
            return
        }
        if isIncognito {
            let state = AppState(isIncognito: true)
            state.openWeb(url: url)
            showNewWindow(with: state)
            return
        }
        openWebURLInPreferredWindow(url)
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

        let newState = AppState(isIncognito: userInfo["isIncognito"] as? Bool ?? false)
        guard newState.loadConfig(config) else { return }

        // 显示新窗口
        showNewWindow(with: newState)

        // 保存新状态并将其加入历史记录
        newState.saveState()
    }

    @objc func selectColorAction() {
        activeReadingState?.showColorPanel()
    }

    @objc func extractTextFromImageAction() {
        guard let appState = activeReadingState else { return }
        extractTextFromImage(from: appState)
    }

    /// 对图片箔运行系统 Vision OCR，识别到文字后在新箔片中以纯文本打开。
    /// OCR 结果已在图片载入检测时缓存，这里直接复用；仅在缓存缺失时才重跑一次。
    func extractTextFromImage(from appState: AppState) {
        guard appState.canExtractImageText,
              let imageURL = appState.imageURL,
              !appState.isExtractingText else { return }
        if let cached = appState.imageOCRText?.trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
            presentExtractedText(cached, isIncognito: appState.isIncognito)
            return
        }
        let isIncognito = appState.isIncognito
        appState.isExtractingText = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak appState] in
            let result = Result { try ImageOCRIndexer.recognize(url: imageURL) }
            let recognized = ((try? result.get()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                appState?.isExtractingText = false
                guard !recognized.isEmpty else {
                    let key: String
                    if case .failure = result { key = "Text Extraction Failed Toast" }
                    else { key = "No Text Found Toast" }
                    appState?.toast.show(NSLocalizedString(key, comment: ""), duration: .seconds(3))
                    return
                }
                guard let self else { return }
                // 回填缓存，后续提取与重开历史都无需再跑 OCR。
                appState?.imageOCRText = recognized
                appState?.hasExtractableImageText = true
                appState?.imageTextDetectedURL = imageURL
                appState?.saveState()
                self.presentExtractedText(recognized, isIncognito: isIncognito)
            }
        }
    }

    /// 把识别到的文字在新箔片中以纯文本打开，复用"新建空白箔"的窗口通道。
    private func presentExtractedText(_ recognized: String, isIncognito: Bool) {
        let state = AppState(isIncognito: isIncognito)
        state.openText(recognized, isMarkdown: false, isClipboard: false)
        showNewWindow(with: state)
    }

    @objc func extractImageSubjectAction() {
        guard let appState = activeReadingState else { return }
        extractImageSubject(from: appState)
    }

    /// 用系统 Vision 的前景实例掩码抠出主体，写成带透明的 PNG，再在新的无边框箔片里打开。
    /// 抠图已在图片载入检测时生成并缓存，这里直接复制；仅在缓存缺失时才重跑一次。
    func extractImageSubject(from appState: AppState) {
        guard appState.canExtractImageSubject,
              let sourceURL = appState.imageURL,
              !appState.isExtractingImageSubject else { return }
        let isIncognito = appState.isIncognito
        let newID = UUID()
        guard let destURL = appState.getCachedImageURL(for: newID, extension: "png") else {
            appState.toast.show(NSLocalizedString("Subject Extraction Failed Toast", comment: ""), duration: .seconds(3))
            return
        }
        let originalName = appState.originalImageName ?? sourceURL.lastPathComponent

        if let cachedCutout = appState.imageSubjectCutoutURL,
           FileManager.default.fileExists(atPath: cachedCutout.path) {
            appState.isExtractingImageSubject = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak appState] in
                let copied = Self.copyCacheFile(from: cachedCutout, to: destURL)
                DispatchQueue.main.async {
                    appState?.isExtractingImageSubject = false
                    guard copied else {
                        appState?.toast.show(NSLocalizedString("Subject Extraction Failed Toast", comment: ""), duration: .seconds(3))
                        return
                    }
                    guard let self else { return }
                    self.postExtractedSubjectFoofoil(id: newID, imageURL: destURL, originalName: originalName, isIncognito: isIncognito)
                }
            }
            return
        }

        appState.isExtractingImageSubject = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak appState] in
            let extracted = ImageSubjectExtractor.writeSubjectPNG(from: sourceURL, to: destURL)
            DispatchQueue.main.async {
                appState?.isExtractingImageSubject = false
                guard extracted else {
                    appState?.toast.show(NSLocalizedString("Subject Extraction Failed Toast", comment: ""), duration: .seconds(3))
                    return
                }
                guard let self else { return }
                self.postExtractedSubjectFoofoil(id: newID, imageURL: destURL, originalName: originalName, isIncognito: isIncognito)
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
    private func postExtractedSubjectFoofoil(id: UUID, imageURL: URL, originalName: String, isIncognito: Bool) {
        NotificationCenter.default.post(
            name: .createNewFoofoilFromImage,
            object: nil,
            userInfo: [
                "id": id,
                "imageURL": imageURL,
                "originalName": String(format: NSLocalizedString("Image Subject: %@", comment: ""), originalName),
                "isIncognito": isIncognito
            ]
        )
    }

    @objc func toggleSubtitlesAction() {
        guard let state = activeReadingState, state.isVideoDocument, state.subtitles.hasLoadedSubtitle else { return }
        state.subtitles.setVisible(state.subtitles.isHidden)
    }

    @objc func loadSubtitleFileAction() {
        guard let appState = activeReadingState, appState.isVideoDocument else { return }
        appState.subtitles.pickFile()
    }

    @objc func documentStyleAction() {
        guard let appState = activeReadingState else { return }
        if appState.isVideoDocument {
            SubtitleStylePanelController.shared.show(for: appState)
            return
        }
        guard appState.supportsContentBackgroundColor || appState.supportsDocumentTextStyling || appState.supportsContentSearch else { return }
        DocumentStylePanelController.shared.show(for: appState)
    }

    @objc func previousChapterAction() {
        activeAppState?.activateAdjacentChapter(delta: -1)
    }

    @objc func nextChapterAction() {
        activeAppState?.activateAdjacentChapter(delta: 1)
    }

    @objc func previousPDFPageAction() {
        postPDFNavigationNotification(.shouldGoToPreviousPDFPage)
    }

    @objc func nextPDFPageAction() {
        postPDFNavigationNotification(.shouldGoToNextPDFPage)
    }

    @objc func previousFileListItemAction() {
        activeReadingState?.activateAdjacentFileListItem(delta: -1)
    }

    @objc func nextFileListItemAction() {
        activeReadingState?.activateAdjacentFileListItem(delta: 1)
    }

    @objc func findContentAction() { activeReadingState?.contentSearch.open() }
    @objc func findContentNextAction() { activeReadingState?.contentSearch.advance(1) }
    @objc func findContentPreviousAction() { activeReadingState?.contentSearch.advance(-1) }

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
        guard let appState = activeReadingState, appState.isPDFDocument else { return }
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
        guard let appState = activeReadingState,
              appState.imageURL != nil && appState.webURL == nil,
              appState.effectiveShowBorder else { return }
        activeWindowController?.fitWindowToCurrentImageSize()
    }

    @objc func fitImageToWindowWidthAction() {
        guard let appState = activeReadingState,
              appState.imageURL != nil && appState.webURL == nil,
              appState.effectiveShowBorder else { return }
        activeWindowController?.fitImageToWindowWidth()
    }

    @objc func zoomOutWindowAction() {
        guard let appState = activeReadingState, !appState.isFullScreen else { return }
        let isImageMode = appState.usesImagePresentation && !appState.isQuickLookDocument
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
        guard let appState = activeReadingState, !appState.isFullScreen else { return }
        let isImageMode = appState.usesImagePresentation && !appState.isQuickLookDocument
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
nonisolated struct ClipboardOpenableContent: Equatable {
    enum Kind: Equatable {
        case folder, file, image, imageList, audio, audioList, appleMusic, video, videoList, pdf, web, htmlFragment, website, markdown, text

        /// 提示文案中的基础类型名（“打开剪贴板里的图片”中的“图片”）。
        var localizedName: String {
            switch self {
            case .folder: return NSLocalizedString("Clipboard Type Folder", comment: "")
            case .file: return NSLocalizedString("File", comment: "")
            case .image: return NSLocalizedString("Clipboard Type Image", comment: "")
            case .imageList: return NSLocalizedString("Image List", comment: "")
            case .audio: return NSLocalizedString("Clipboard Type Audio", comment: "")
            case .audioList: return NSLocalizedString("Audio List", comment: "")
            case .appleMusic: return "Apple Music"
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
    var fileName: String?

    init(_ kind: Kind, fileExtension: String? = nil) {
        self.kind = kind
        self.fileExtension = fileExtension
    }

    /// 主文件名最多显示 8 个中文或 16 个英文字符；混排按中文占两个单位计算，扩展名不计入预算。
    static func abbreviatedFileName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        let stem = suffix.isEmpty ? name : String(name.dropLast(suffix.count))
        var prefix = ""
        var units = 0
        for character in stem {
            let isHan = character.unicodeScalars.contains { scalar in
                switch scalar.value {
                case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                     0x20000...0x2FA1F, 0x30000...0x323AF: return true
                default: return false
                }
            }
            units += isHan ? 2 : 1
            guard units <= 16 else { return prefix + "…" + suffix }
            prefix.append(character)
        }
        return name
    }

    /// 单文件显示文件名，其他内容继续使用本地化类型名。
    var localizedName: String {
        if let fileName {
            return String(format: NSLocalizedString("Clipboard Quoted Filename Format", comment: ""),
                          Self.abbreviatedFileName(fileName))
        }
        let base = kind.localizedName
        guard let fileExtension, !fileExtension.isEmpty else { return base }
        return String(
            format: NSLocalizedString("Clipboard Type With Extension Format", comment: ""),
            "." + fileExtension,
            base
        )
    }

    /// 空箔横条使用完整文件名，由实际可用宽度截断，不套用总览的固定字数预算。
    func openingTitle(isIncognito: Bool, abbreviatesFileName: Bool = true) -> String {
        let name: String
        if !abbreviatesFileName, let fileName {
            name = String(format: NSLocalizedString("Clipboard Quoted Filename Format", comment: ""), fileName)
        } else {
            name = localizedName
        }
        return String(format: NSLocalizedString(isIncognito ? "Open Clipboard Item Incognito Format" : "Open Clipboard Item Format", comment: ""), name)
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
        guard var content = classifyFileURLs(urls) else { return nil }
        if urls.count == 1, content.kind != .folder {
            content.fileName = urls[0].lastPathComponent
        }
        return content
    }

    @MainActor
    private static func classifyFileURLs(_ urls: [URL]) -> ClipboardOpenableContent? {
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
        html: String?,
        appleMusicEnabled: Bool = true
    ) -> ClipboardOpenableContent? {
        let isDeclaredMarkdown = !(declaredMarkdown?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let text = isDeclaredMarkdown ? declaredMarkdown : plainText
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isDeclaredMarkdown || AppState.looksLikeMarkdown(text) { return ClipboardOpenableContent(.markdown) }
            if let url = AppState.websiteURL(fromClipboardText: text) {
                return ClipboardOpenableContent(!appleMusicEnabled || AppleMusicLink(url: url) == nil ? .website : .appleMusic)
            }
            if html != nil || AppState.looksLikeHTML(text) { return ClipboardOpenableContent(.htmlFragment) }
            return ClipboardOpenableContent(.text)
        }
        return html == nil ? nil : ClipboardOpenableContent(.htmlFragment)
    }
}
