//  AppDelegate.swift
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


public class AppDelegate: NSObject, NSApplicationDelegate {
    public var windowControllers: [FloatingWindowController] = []
    var historyMenu: NSMenu?
    var editMenu: NSMenu?
    var fileMenu: NSMenu?
    var goMenu: NSMenu?
    var goMenuItem: NSMenuItem?
    var viewMenu: NSMenu?
    var extensionMenu: NSMenu?
    var extensionMenuItem: NSMenuItem?
    var windowMenu: NSMenu?
    var contentModeCancellables = Set<AnyCancellable>()
    var appleMusicLinkTask: Task<Void, Never>?
    var didOpenFiles = false
    private var isTerminating = false
    /// hide: 漏掉的箔窗，在 didHide 里补 orderOut，unhide 时再还原。
    private var windowsLeftVisibleAfterHide: [NSWindow] = []

    public override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(updateAppleMusicAvailability), name: .appleMusicSearchDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleFileOpenFeedback(_:)), name: .fileOpenFeedback, object: nil)
    }

    /// 活跃窗口解析入口：正常运行取系统 key window；测试可注入固定窗口，避免依赖应用激活状态。
    var activeWindowProvider: () -> NSWindow? = { NSApplication.shared.keyWindow }

    // 获取当前活跃（Key）窗口对应的 AppState
    var activeWindowController: FloatingWindowController? {
        guard let keyWindow = activeWindowProvider() else { return nil }
        return windowControllers.first { $0.owns(keyWindow) }
    }

    var activeAppState: AppState? {
        return activeWindowController?.appState
    }

    /// 当前活跃箔片是否为无痕箔；无活跃箔片（例如总览、搜索窗口或系统面板）时为 false。
    var isActiveFoilIncognito: Bool {
        activeWindowController?.appState.isIncognito == true
    }

    /// 自动接管仅限普通空箔；无痕空箔不是普通打开操作的候选目标。
    var availableBlankWindowController: FloatingWindowController? {
        blankWindowController(isIncognito: false)
    }

    func blankWindowController(isIncognito: Bool) -> FloatingWindowController? {
        // 明确的无痕打开始终创建新箔，不自动占用任何现有空箔。
        guard !isIncognito else { return nil }
        if let activeWindowController, isBlank(activeWindowController.appState),
           !activeWindowController.appState.isIncognito { return activeWindowController }
        return windowControllers.first { isBlank($0.appState) && !$0.appState.isIncognito }
    }

    func isBlank(_ appState: AppState) -> Bool {
        appState.archiveSession == nil && !appState.isFileOpenFeedback && appState.appleMusicReference == nil && !appState.isCamera && appState.imageURL == nil
            && appState.webURL == nil
            && appState.textURL == nil
            && appState.extensionSession == nil
            && appState.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func activateWindow(_ controller: FloatingWindowController) {
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// 有箔片处于原生全屏时，其余箔片退出 all-spaces 常驻，避免浮在全屏箔的 Space 上方；
    /// 全屏结束后恢复常驻。窗口增删与箔片进出全屏时都会调用。
    func syncFoilSpaceJoining() {
        windowControllers.forEach { $0.updateSpaceJoiningBehavior() }
    }

    // 处理文件关联打开事件 (右键 "打开方式" 或者双击文件)
    // 始终新建箔片打开，避免替换当前箔片正在查看的内容。
    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        didOpenFiles = true
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        ShareDiagnostics.logger.notice("File receive: \(urls.count, privacy: .public) files, staged=\(urls.contains(where: ShareStaging.isStaged), privacy: .public)")
        if urls.contains(where: ShareStaging.isStaged) {
            Task { @MainActor [weak self] in
                do {
                    for isIncognito in [false, true] {
                        let batch = urls.filter { ShareStaging.isIncognito($0) == isIncognito }
                        guard !batch.isEmpty else { continue }
                        let imported = try await Task.detached { try SharedFileImport.persist(batch, isIncognito: isIncognito) }.value
                        ShareDiagnostics.logger.notice("Import complete: \(imported.count, privacy: .public) files, incognito=\(isIncognito, privacy: .public)")
                        self?.openFilesInNewFoil(imported, isIncognito: isIncognito)
                    }
                } catch {
                    ShareDiagnostics.logger.error("Import failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
                    let alert = NSAlert()
                    alert.messageText = NSLocalizedString("Share Import Failed", comment: "")
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        } else { openFilesInNewFoil(urls) }
    }

    /// 先建好新箔片作为目标，再走拖放管线：多文件分组时首个分组落入该箔片，
    /// 其余分组各自另开箔片，避免直接传 nil 目标时多出一扇空箔。
    func openFilesInNewFoil(_ urls: [URL], isIncognito: Bool = false) {
        let state = AppState(isIncognito: isIncognito)
        let remaining = state.filterFileOpenFailures(urls)
        ShareDiagnostics.logger.notice("File open: \(remaining.count, privacy: .public) of \(urls.count, privacy: .public) accepted, incognito=\(isIncognito, privacy: .public)")
        guard !remaining.isEmpty else { return }
        state.closesEmptyWindowAfterFileOpenFailure = true
        let controller = showNewWindow(with: state)
        openDroppedFiles(remaining, into: state, feedbackBatchID: state.fileOpenFeedbackBatchID)
        // 没有可打开的文件时收回空白箔；目录扫描与音视频可播性判定是异步的，
        // 完成前状态为空但不能关，等在途打开结束后再判定，避免关掉在途内容或留下空箔。
        closeFoilIfStillBlank(controller, for: state)
    }

    func closeFoilIfStillBlank(_ controller: FloatingWindowController, for state: AppState) {
        guard state.pendingContentOpenCount == 0 else {
            // 订阅随窗口释放，首个完成通知后自动取消，避免闭包捕获后再修改观察令牌。
            controller.pendingBlankCloseCancellable = NotificationCenter.default
                .publisher(for: .contentOpenDidSettle, object: state)
                .first()
                .sink { [weak self, weak controller, weak state] _ in
                    guard let self, let controller, let state else { return }
                    controller.pendingBlankCloseCancellable = nil
                    self.closeFoilIfStillBlank(controller, for: state)
                }
            return
        }
        // 目录扫描在途时保持现状：与既有行为一致，扫描结果自行决定是否呈现内容。
        guard state.activeDirectoryDropScan == nil, isBlank(state) else { return }
        controller.close()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 活跃窗口切换时立即同步 PDF 专用菜单，避免等待用户打开任意菜单后才更新。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyWindowChanged),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyWindowChanged),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )

        // 注册截屏新窗口通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCreateNewFoofoilFromImage(_:)),
            name: .createNewFoofoilFromImage,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenGroupedFiles(_:)),
            name: .openGroupedFiles,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardShortcutsDidChange),
            name: .keyboardShortcutsDidChange,
            object: nil
        )

        // 注册后系统可立即投递服务请求，因此先完成打开流程依赖的通知注册。
        NSApp.servicesProvider = self

        // 1. 启动时，如果尚未通过打开文件创建过窗口，且当前窗口列表为空，按启动行为偏好处理
        if !didOpenFiles && windowControllers.isEmpty {
            switch SettingsStore.shared.startupBehavior {
            case .newWindow:
                let state = AppState()
                let controller = FloatingWindowController(appState: state)
                addWindowController(controller)
                controller.showWindow(nil)
            case .restoreWindows:
                let savedConfigs = SettingsStore.shared.lastOpenWindowConfigs.filter { SettingsStore.shared.appleMusicLibraryEnabled || $0.appleMusicReference == nil }
                if !savedConfigs.isEmpty {
                    for config in savedConfigs {
                        if SettingsStore.shared.automaticallyRemoveMissingHistory, config.resolvingFileReferences().missing {
                            HistoryManager.shared.removeFromHistory(config, preservingLegacyBody: true)
                            continue
                        }
                        let state = AppState()
                        guard state.loadConfig(config) else { continue }
                        let controller = FloatingWindowController(appState: state)
                        if config.windowFrame == nil { controller.window?.center() }
                        addWindowController(controller)
                        controller.showWindow(nil)
                    }
                } else {
                    let state = AppState()
                    let controller = FloatingWindowController(appState: state)
                    addWindowController(controller)
                    controller.showWindow(nil)
                }
            case .nothing:
                break
            }
        }

        // 2. 动态创建 macOS 菜单项 (延时到主线程下一个循环，确保在 SwiftUI 初始化菜单之后执行)
        // 全局热键 ⌃⇧⎋ 在启动时注册，浮箔未激活时也能唤起“浮箔总览”。
        FoilExposeController.shared.installGlobalHotKey()
        DispatchQueue.main.async {
            self.setupMainMenu()
            self.updateHistoryMenu()
            if ExtensionProductPolicy.exposesUserManagement, SettingsStore.shared.extensionAutoCheckUpdates {
                Task {
                    await ExtensionHost.shared.manager.refreshCatalog()
                }
            }
        }
    }

    /// 无痕箔仅活在本次运行中，不参与退出时的窗口恢复快照。
    var restorableWindowConfigs: [WindowConfig] {
        windowControllers.filter { !$0.appState.isFileOpenFeedback && !$0.appState.isIncognito && !$0.appState.isArchivePreview && $0.appState.archiveSession?.hasTemporarySource != true && !HistoryRepository.shared.wasDeleted($0.appState.id) }.map { $0.appState.toConfig() }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        // 保存当前活跃窗口配置，用于下次启动恢复
        for controller in windowControllers { controller.appState.persistManagedTextIfNeeded(createIfNeeded: true) }
        ContentCache.shared.flushBodyWrites()
        let activeConfigs = restorableWindowConfigs
        SettingsStore.shared.lastOpenWindowConfigs = activeConfigs

        HistoryManager.shared.flushPendingListSaves()
        ContentCache.shared.flushBodyWrites()
        // 进程退出只会自动归还 hog，不会恢复采样率；先停 PCM 引擎，再等待扩展恢复设备。
        AppleMusicPlaybackController.stopIfActive()
        AudioPlaybackController.stopAllOutputsForTermination()
        Task { @MainActor in
            await ExtensionHost.shared.shutdownAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 最后一个窗口关闭后，不要退出应用，保持无窗口活动状态
        return false
    }

    /// hide: 不会收起 canHide ivar 为 false 的子窗口；音频箔的 hover 监听还可能在隐藏后把箔再 orderFront 回来。
    public func applicationWillHide(_ notification: Notification) {
        for controller in windowControllers {
            controller.prepareForApplicationHide()
        }
    }

    public func applicationDidHide(_ notification: Notification) {
        windowsLeftVisibleAfterHide = NSApp.windows.filter(\.isVisible)
        for window in windowsLeftVisibleAfterHide {
            window.orderOut(nil)
        }
    }

    public func applicationDidUnhide(_ notification: Notification) {
        let extra = windowsLeftVisibleAfterHide
        windowsLeftVisibleAfterHide.removeAll()
        for window in extra where !window.isVisible {
            window.orderFront(nil)
        }
        for controller in windowControllers {
            controller.restoreAfterApplicationUnhide()
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            newWindowAction()
        }
        return true
    }

    public func removeWindowController(_ controller: FloatingWindowController) {
        guard let index = windowControllers.firstIndex(where: { $0 === controller }) else { return }
        ContentCache.shared.retire(controller.appState.cachedContentPaths)
        windowControllers.remove(at: index)
        ContentCache.shared.protect(Set(windowControllers.map { $0.appState.id }), paths: Set(windowControllers.flatMap { $0.appState.cachedContentPaths }))
        syncFoilSpaceJoining()
    }

    /// 取色面板是应用级单例：记录它当前服务的那扇箔，关闭该箔时一并收起，避免取色落到其他窗口。
    weak var colorPanelOwner: AppState?

    /// 收起属于该箔的文档样式面板；面板不属于它时不动。
    func dismissDocumentStylePanel(ownedBy appState: AppState) {
        DocumentStylePanelController.shared.dismiss(ownedBy: appState)
        SubtitleStylePanelController.shared.dismiss(ownedBy: appState)
    }

    /// 收起属于该箔的取色面板；面板不属于它时不动（可能正被另一扇箔使用）。
    func dismissColorPanel(ownedBy appState: AppState) {
        guard colorPanelOwner === appState else { return }
        colorPanelOwner = nil
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.accessoryView = nil
        panel.close()
    }

    func addWindowController(_ controller: FloatingWindowController) {
        windowControllers.append(controller)
        ContentCache.shared.protect(Set(windowControllers.map { $0.appState.id }), paths: Set(windowControllers.flatMap { $0.appState.cachedContentPaths }))
        syncFoilSpaceJoining()

        // 内容在当前窗口内切换时（例如通过“打开”或拖放）也立即更新 PDF 专用菜单。
        controller.appState.$imageURL
            .sink { [weak self, weak controller] _ in
                guard let self, let controller, self.activeWindowController === controller else { return }
                self.updateGoMenuVisibility()
                self.updateExtractTextMenuItem()
                self.updateExtractImageSubjectMenuItem()
            }
            .store(in: &contentModeCancellables)

        controller.appState.$fileList
            .sink { [weak self, weak controller] _ in
                guard let self, let controller, self.activeWindowController === controller else { return }
                self.updateGoMenuVisibility()
                self.updateExtractTextMenuItem()
                self.updateExtractImageSubjectMenuItem()
            }
            .store(in: &contentModeCancellables)

        controller.appState.$extensionSession
            .sink { [weak self, weak controller] _ in
                guard let self, let controller, self.activeWindowController === controller else { return }
                self.updateExtensionMenuVisibility()
                self.updateExtractTextMenuItem()
                self.updateExtractImageSubjectMenuItem()
            }
            .store(in: &contentModeCancellables)

        // 只读正文与可编辑文本的切换决定上下键归属（滚动或切项），需同步“前往”菜单键位。
        Publishers.Merge(controller.appState.$textURL.map { _ in () }, controller.appState.$isMarkdownPreview.map { _ in () })
            .sink { [weak self, weak controller] _ in
                DispatchQueue.main.async {
                    guard let self, let controller, self.activeWindowController === controller else { return }
                    self.updateGoMenuVisibility()
                }
            }
            .store(in: &contentModeCancellables)

        // MusicKit 队列异步投影完成后刷新通用导航快捷键；@Published 发出时状态尚未提交。
        controller.appState.$builtInNavigatorContributions
            .sink { [weak self, weak controller] _ in
                DispatchQueue.main.async {
                    guard let self, let controller, self.activeWindowController === controller else { return }
                    self.updateGoMenuVisibility()
                }
            }
            .store(in: &contentModeCancellables)

        // PPT 目录在后台读取完后才可翻页，提交页列表后再同步图片共用的“前往”菜单。
        controller.appState.pptxNavigationController.$slides
            .sink { [weak self, weak controller] _ in
                DispatchQueue.main.async {
                    guard let self, let controller, self.activeWindowController === controller else { return }
                    self.updateGoMenuVisibility()
                }
            }
            .store(in: &contentModeCancellables)

        // 主体检测要等图片载入后才有结论：结论落地时刷新菜单项的可用性与键位。
        controller.appState.$hasExtractableImageSubject
            .sink { [weak self, weak controller] _ in
                guard let self, let controller, self.activeWindowController === controller else { return }
                self.updateExtractImageSubjectMenuItem()
            }
            .store(in: &contentModeCancellables)

        // 文字检测同样在图片载入后才出结论：结论落地时刷新"提取文字"的可用性与键位。
        controller.appState.$hasExtractableImageText
            .sink { [weak self, weak controller] _ in
                guard let self, let controller, self.activeWindowController === controller else { return }
                self.updateExtractTextMenuItem()
            }
            .store(in: &contentModeCancellables)
    }

    @objc func handleKeyWindowChanged(_ notification: Notification) {
        // 交由下一轮事件循环执行，确保 AppKit 已更新 keyWindow。
        DispatchQueue.main.async { [weak self] in
            self?.updateGoMenuVisibility()
            self?.updateExtensionMenuVisibility()
            self?.updateExtractTextMenuItem()
            self?.updateExtractImageSubjectMenuItem()
        }
    }
}
