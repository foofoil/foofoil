import AppKit
import SwiftUI
import Combine

final class HistorySearchPanel: NSPanel {
    weak var searchModel: HistorySearchViewModel?
    var dismissSearch: (() -> Void)?
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, let model = searchModel else { super.sendEvent(event); return }
        let hasMarkedText = (firstResponder as? NSTextView)?.hasMarkedText() ?? false
        if hasMarkedText { super.sendEvent(event); return }
        if event.keyCode == 53 { dismissSearch?(); return }
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" { dismissSearch?(); return }
        if event.keyCode == 125 || (event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "n") { model.moveSelection(by: 1); return }
        if event.keyCode == 126 || (event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "p") { model.moveSelection(by: -1); return }
        if (event.keyCode == 36 || event.keyCode == 76) && !hasMarkedText { model.openSelected(); return }
        super.sendEvent(event)
    }
}

@MainActor
final class HistorySearchWindowController: NSWindowController, NSWindowDelegate {
    static let shared = HistorySearchWindowController()
    private let model = HistorySearchViewModel()
    private var sizeCancellable: AnyCancellable?
    private var isResizeScheduled = false
    private var isOpeningFile = false
    private var openingTask: Task<Void, Never>?

    private init() {
        let panel = HistorySearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 74),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.searchModel = model
        panel.contentViewController = NSHostingController(rootView: HistorySearchView(model: model))
        super.init(window: panel)
        panel.delegate = self
        panel.dismissSearch = { [weak self] in self?.dismiss() }
        model.chooseSearchFolders = { [weak self] in self?.chooseSearchFolders() }
        model.openFile = { [weak self] url in self?.openFile(url) }
        model.openResult = { id in
            (NSApplication.shared.delegate as? AppDelegate)?.openSearchResultInNewWindow(id: id)
        }
        model.openWebURL = { url in
            (NSApplication.shared.delegate as? AppDelegate)?.openWebURLInPreferredWindow(url)
        }
        sizeCancellable = model.objectWillChange.sink { [weak self] _ in
            self?.scheduleResizeToFit()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        show(mode: .history)
    }

    func showURLInput(initialQuery: String? = nil) {
        show(mode: .url, initialQuery: initialQuery)
    }

    private func show(mode: HistorySearchMode, initialQuery: String? = nil) {
        guard let panel = window else { return }

        let activeWindow: NSWindow? = {
            if let key = NSApp.keyWindow, key !== panel {
                return key
            }
            let delegate = NSApplication.shared.delegate as? AppDelegate
            return delegate?.windowControllers.first(where: { $0.window?.isKeyWindow == true })?.window
                ?? delegate?.windowControllers.first(where: { $0.window?.isVisible == true })?.window
        }()

        model.reset(mode: mode, initialQuery: initialQuery)
        NSApp.activate(ignoringOtherApps: true)

        let screen = activeWindow?.screen
            ?? NSApp.keyWindow?.screen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main

        let panelWidth = panel.frame.width
        let panelHeight = panel.frame.height

        var originX: CGFloat
        var originY: CGFloat

        if let activeWindow {
            let activeFrame = activeWindow.frame
            originX = activeFrame.midX - panelWidth / 2
            let activeMidY = activeFrame.midY
            let offset = activeFrame.height * 0.18
            originY = activeMidY + offset - panelHeight / 2
        } else if let visible = screen?.visibleFrame {
            originX = visible.midX - panelWidth / 2
            originY = visible.maxY - panelHeight - visible.height * 0.18
        } else {
            originX = 100
            originY = 100
        }

        if let visible = screen?.visibleFrame {
            let minX = visible.minX
            let maxX = max(minX, visible.maxX - panelWidth)
            let minY = visible.minY
            let maxY = max(minY, visible.maxY - panelHeight)

            originX = min(max(originX, minX), maxX)
            originY = min(max(originY, minY), maxY)
        }

        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        panel.makeKeyAndOrderFront(nil)
        resizeToFit()
    }

    func dismiss() {
        openingTask?.cancel()
        model.stop()
        window?.orderOut(nil)
    }

    /// 索引命中不等于文件授权；只在真正打开时尝试读取，失败再由系统面板授予访问。
    private func openFile(_ url: URL) {
        guard !isOpeningFile else { return }
        isOpeningFile = true
        model.stop()
        openingTask = Task { [self] in
            let folders = (try? SpotlightSearchFolders.shared.beginAccess()) ?? []
            let access = await Self.fileAccess(url)
            guard !Task.isCancelled else { releaseFolderAccess(folders); isOpeningFile = false; return }
            if access == .readable {
                acceptFile(url, folderScopes: folders)
                isOpeningFile = false
                return
            }
            releaseFolderAccess(folders)
            guard access == .needsPermission else {
                restoreSearch()
                model.openError = NSLocalizedString(access == .notDownloaded ? "Search File Not Downloaded" : "Search File Open Failed", comment: "")
                isOpeningFile = false
                return
            }
            let picker = NSOpenPanel()
            picker.canChooseDirectories = false
            picker.canChooseFiles = true
            picker.allowsMultipleSelection = false
            picker.directoryURL = url.deletingLastPathComponent()
            picker.nameFieldStringValue = url.lastPathComponent
            picker.message = NSLocalizedString("Search File Access Message", comment: "")
            picker.begin { [weak self] response in
                guard let self else { return }
                if response == .OK, let selected = picker.url {
                    self.acceptFile(selected, folderScopes: [])
                } else {
                    self.restoreSearch()
                }
                self.isOpeningFile = false
            }
        }
    }

    private func releaseFolderAccess(_ scopes: [URL]) {
        scopes.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    /// 打开请求被接受后继续持有目录授权，直到目标箔片装载结束或超时，
    /// 让扩展会话与媒体探测有时间把目录授权替换成自己的文件级安全范围。
    private func holdFolderAccessUntilSettled(_ scopes: [URL], target: AppState?) {
        guard !scopes.isEmpty else { return }
        Task { [scopes] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(target == nil ? 3 : 10))
            while ContinuousClock.now < deadline {
                if let target, !target.isLoading, target.hasOpenedContent { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            scopes.forEach { $0.stopAccessingSecurityScopedResource() }
        }
    }

    /// 目录授权只保证持有期间可读；转成文件级安全范围 URL 后，窗口与扩展会话各自持有授权。
    nonisolated static func fileScopedURL(for url: URL) -> URL? {
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func chooseSearchFolders() {
        guard !isOpeningFile else { return }
        isOpeningFile = true
        model.stop()
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = true
        picker.message = NSLocalizedString("Search Folders Message", comment: "")
        picker.begin { [weak self] response in
            guard let self else { return }
            var failed = false
            if response == .OK {
                do { try SpotlightSearchFolders.shared.replace(with: picker.urls) }
                catch { failed = true }
            }
            self.restoreSearch()
            if failed { self.model.openError = NSLocalizedString("Search Folder Access Failed", comment: "") }
            self.isOpeningFile = false
        }
    }

    nonisolated enum FileAccess: Sendable { case readable, needsPermission, unavailable, notDownloaded }

    @concurrent
    static func fileAccess(_ url: URL) async -> FileAccess {
        do {
            let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if values.ubiquitousItemDownloadingStatus == .notDownloaded { return .notDownloaded }
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
            return .readable
        } catch {
            let error = error as NSError
            if (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
                || (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code)) {
                return .needsPermission
            }
            return .unavailable
        }
    }

    private func acceptFile(_ url: URL, folderScopes: [URL]) {
        let scopedURL = Self.fileScopedURL(for: url) ?? url
        guard let delegate = NSApp.delegate as? AppDelegate else {
            releaseFolderAccess(folderScopes)
            restoreSearch()
            model.openError = NSLocalizedString("Search File Open Failed", comment: "")
            return
        }
        let target = delegate.availableBlankWindowController?.appState
        let knownWindows = Set(delegate.windowControllers.map(ObjectIdentifier.init))
        guard delegate.openGroupedFiles([scopedURL], into: target, append: false) else {
            releaseFolderAccess(folderScopes)
            restoreSearch()
            model.openError = NSLocalizedString("Search File Open Failed", comment: "")
            return
        }
        let openedState = target ?? delegate.windowControllers.first { !knownWindows.contains(ObjectIdentifier($0)) }?.appState
        dismiss()
        holdFolderAccessUntilSettled(folderScopes, target: openedState)
    }

    private func restoreSearch() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.resume()
    }

    private func resizeToFit() {
        guard let panel = window, let contentView = panel.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let height = min(650, max(74, contentView.fittingSize.height))
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: 620, height: height)
        frame.origin.y = top - height

        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            let minX = visible.minX
            let maxX = max(minX, visible.maxX - frame.width)
            let minY = visible.minY
            let maxY = max(minY, visible.maxY - frame.height)

            frame.origin.x = min(max(frame.origin.x, minX), maxX)
            frame.origin.y = min(max(frame.origin.y, minY), maxY)
        }

        guard abs(panel.frame.height - frame.height) > 0.5 || panel.frame != frame else { return }
        panel.setFrame(frame, display: true, animate: false)
    }

    /// 合并同一轮状态更新产生的多次布局请求，避免搜索框获得焦点时连续调整窗口位置。
    private func scheduleResizeToFit() {
        guard !isResizeScheduled else { return }
        isResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isResizeScheduled = false
            self.resizeToFit()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // 系统授权面板接管焦点时保留待打开操作，其余隐藏路径正常取消查询。
        if isOpeningFile { model.stop(); window?.orderOut(nil) }
        else { dismiss() }
    }
}
