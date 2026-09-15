//
//  FoilExposeController.swift
//  foofoil
//
//  Created by tolg on 2026/9/14.
//

import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// 索引到数字/字母快捷键的纯函数映射：0-8 → 1-9，9-34 → A-Z，35 起没有可用键（仍可点击选择）。
enum FoilExposeShortcut {
    static func key(forIndex index: Int) -> String? {
        guard index >= 0 else { return nil }
        if index < 9 { return String(index + 1) }
        guard index < 35 else { return nil }
        return String(UnicodeScalar(65 + (index - 9))!)
    }
}

/// 覆盖层中一个箔片的快照：收集自 AppDelegate.windowControllers，展示信息取自历史配置。
/// controller 为 nil 表示“新建空白箔”占位卡（无任何箔窗口时显示）。
struct FoilExposeItem: Identifiable {
    let id: UUID
    let controller: FloatingWindowController?
    let screen: NSScreen
    let title: String
    let symbolName: String
    let contentKind: HistoryContentKind
    let thumbnailPath: String?
    var shortcut: String?

    var window: NSWindow? { controller?.window }
    var isNewFoil: Bool { controller == nil }
}

/// 覆盖层的共享模型：每个屏幕一个面板视图，键盘监听与选择回调共用同一份条目。
@MainActor
final class FoilExposeModel: ObservableObject {
    let items: [FoilExposeItem]
    /// 大写快捷键到条目的映射；快捷键按屏幕独立编号，同一按键可能对应多个屏幕上的条目。
    let itemsByKey: [String: [FoilExposeItem]]
    var onSelect: (FoilExposeItem) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    init(items: [FoilExposeItem]) {
        self.items = items
        var byKey: [String: [FoilExposeItem]] = [:]
        for item in items {
            guard let shortcut = item.shortcut else { continue }
            byKey[shortcut.uppercased(), default: []].append(item)
        }
        self.itemsByKey = byKey
    }

    func items(for screen: NSScreen) -> [FoilExposeItem] {
        items.filter { $0.screen === screen }
    }

    /// 按键先转大写再查询；多屏键重复时优先命中 key 面板所在屏幕的条目。
    func item(forKey key: String, preferredScreen: NSScreen?) -> FoilExposeItem? {
        let candidates = itemsByKey[key.uppercased()] ?? []
        if let preferredScreen,
           let match = candidates.first(where: { $0.screen === preferredScreen }) {
            return match
        }
        return candidates.first
    }
}

/// 覆盖层面板：无边框、不抢激活，但需成为 key window 才能接收键盘事件。
final class FoilExposePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 自建 App Exposé：为每个屏幕铺一块覆盖层，展示本 App 全部箔片对应的历史缩略图。
/// 只复用历史缩略图，不抓新截图；不使用屏幕录制、辅助功能、输入监控或私有 API。
@MainActor
final class FoilExposeController {
    static let shared = FoilExposeController()

    private var panels: [FoilExposePanel] = []
    private var model: FoilExposeModel?
    private var keyMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    private init() {
        // 观察者与单例同生命周期；未展示时下面的处理会被各自的守卫拦下。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
    }

    var isShowing: Bool { model != nil }

    /// 启动入口：安装事件处理器并按当前配置注册“显示所有箔片”的全局热键。
    /// 经 Carbon RegisterEventHotKey，浮箔未激活时也能唤起覆盖层；不需要输入监控或辅助功能权限。
    func installGlobalHotKey() {
        installEventHandlerIfNeeded()
        applyConfiguredGlobalHotKey()
    }

    /// 快捷键配置变更后重新注册全局热键。
    /// 仅当组合键含 Control/Option 且能映射为 Carbon 键码时才全局注册，避免吞掉系统常用快捷键。
    func applyConfiguredGlobalHotKey() {
        installEventHandlerIfNeeded()
        if let hotKeyRef {
            _ = UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        guard let definition = KeyboardShortcutCatalog.definition(withID: "window.showAllFoils"),
              let shortcut = KeyboardShortcutStore.shared.shortcut(for: definition) else { return }
        let modifiers = shortcut.modifiers
        guard modifiers.contains(.control) || modifiers.contains(.option),
              let keyCode = shortcut.carbonKeyCode else { return }

        var hotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x464F_494C) /* 'FOIL' */, id: 1)
        let status = RegisterEventHotKey(
            keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard status == noErr else {
            NSLog("显示所有箔片：全局热键注册失败（%d）", status)
            return
        }
        hotKeyRef = hotKey
    }

    private func installEventHandlerIfNeeded() {
        guard hotKeyHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                MainActor.assumeIsolated {
                    FoilExposeController.shared.handleGlobalHotKey()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handler
        )
        guard status == noErr else {
            NSLog("显示所有箔片：全局热键事件处理器安装失败（%d）", status)
            return
        }
        hotKeyHandler = handler
    }

    /// 全局热键回调：与菜单动作相同，未展示时打开覆盖层，已展示时关闭。
    func handleGlobalHotKey() {
        toggle()
    }

    /// 菜单入口：未展示时打开覆盖层，已展示时关闭。
    func toggle() {
        isShowing ? dismiss() : show()
    }

    func show() {
        guard !isShowing,
              let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
        let items = Self.collectItems(from: appDelegate.windowControllers)
        // 没有任何箔窗口时也展示覆盖层：每个屏幕放一张“新建空白箔”占位卡。
        let model = FoilExposeModel(items: items.isEmpty ? Self.emptyStateItems() : items)
        model.onSelect = { [weak self] item in self?.select(item) }
        model.onDismiss = { [weak self] in self?.dismiss() }
        self.model = model

        // 先激活本 App，再铺非激活面板并指定鼠标所在屏幕的面板为 key window。
        // 全局热键冷触发时激活是异步完成的，handleDidBecomeActive 会补交键盘焦点。
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let panel = Self.makePanel(for: screen, model: model)
            panel.orderFront(nil)
            panels.append(panel)
        }
        if NSApp.isActive {
            focusPanelOnMouseScreen()
        }

        installKeyMonitor()
    }

    /// 让鼠标所在屏幕的覆盖层面板成为 key window，接收数字/字母选择。
    private func focusPanelOnMouseScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let hoveredPanel = panels.first { $0.screen?.frame.contains(mouseLocation) == true } ?? panels.first
        hoveredPanel?.makeKeyAndOrderFront(nil)
    }

    @objc private func handleDidBecomeActive() {
        guard isShowing else { return }
        focusPanelOnMouseScreen()
    }

    /// App 失去激活（如切到别的 App）时自动关闭覆盖层。
    @objc private func handleDidResignActive() {
        dismiss()
    }

    /// 收集当前全部箔片：按屏幕排序后统一分配快捷键，保证各屏幕角标顺序稳定。
    private static func collectItems(from windowControllers: [FloatingWindowController]) -> [FoilExposeItem] {
        let screens = NSScreen.screens
        var collected: [(screenIndex: Int, order: Int, item: FoilExposeItem)] = []
        for (order, controller) in windowControllers.enumerated() {
            guard let window = controller.window,
                  let screen = window.screen ?? NSScreen.main else { continue }
            let screenIndex = screens.firstIndex { $0 === screen } ?? 0
            // 历史读取失败时回退到 App State 自身，空白窗口也能得到正确的类型与标题。
            let config = HistoryRepository.shared.config(id: controller.appState.id)
                ?? controller.appState.toConfig()

            var title = config.historyMenuDisplayName
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = NSLocalizedString("Untitled Note", comment: "")
            }
            let contentKind = config.contentKind ?? HistoryContentKind.infer(from: config)
            // 音视频原文件不是图片；仅图片和 PDF 在缺少缩略图时回退到内容原路径。
            var thumbnailPath = config.thumbnailPath
            if thumbnailPath == nil, contentKind == .image || contentKind == .pdf {
                thumbnailPath = config.imagePath
            }

            collected.append((screenIndex, order, FoilExposeItem(
                id: controller.appState.id,
                controller: controller,
                screen: screen,
                title: title,
                symbolName: config.historyMenuSymbolName,
                contentKind: contentKind,
                thumbnailPath: thumbnailPath,
                shortcut: nil
            )))
        }

        // 快捷键按屏幕独立编号：每个屏幕的角标都从 1 开始，与该屏显示顺序一致。
        let grouped = Dictionary(grouping: collected) { $0.screenIndex }
            .sorted { $0.key < $1.key }
        return grouped.flatMap { _, entries in
            entries.sorted { $0.order < $1.order }.enumerated().map { index, entry -> FoilExposeItem in
                var item = entry.item
                item.shortcut = FoilExposeShortcut.key(forIndex: index)
                return item
            }
        }
    }

    /// 没有任何箔窗口时的覆盖层内容：每个屏幕一张“新建空白箔”占位卡，
    /// 出现在第一个箔将显示的位置，编号固定为 1（点击或按 1 新建空白箔）。
    private static func emptyStateItems() -> [FoilExposeItem] {
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        return screens.map { screen in
            FoilExposeItem(
                id: UUID(),
                controller: nil,
                screen: screen,
                title: NSLocalizedString("Untitled Note", comment: ""),
                symbolName: "plus",
                contentKind: .text,
                thumbnailPath: nil,
                shortcut: FoilExposeShortcut.key(forIndex: 0)
            )
        }
    }

    private static func makePanel(for screen: NSScreen, model: FoilExposeModel) -> FoilExposePanel {
        let panel = FoilExposePanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: FoilExposeView(model: model, screen: screen))
        return panel
    }

    /// 选择箔片：覆盖层先退场，再把目标窗口调度到最前；占位卡则新建一张空白箔。
    private func select(_ item: FoilExposeItem) {
        guard let controller = item.controller, let window = item.window else {
            dismiss()
            NSApp.activate(ignoringOtherApps: true)
            (NSApplication.shared.delegate as? AppDelegate)?.showNewWindow(with: AppState())
            return
        }
        dismiss()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        // 置顶箔片层级更高，兜底保证目标窗口可见。
        window.orderFrontRegardless()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.model != nil else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // 带修饰键的按键放行，让菜单快捷键（含再次触发的 ⌃⌥F）继续工作。
            if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
                return event
            }
            if event.keyCode == 53 { // Esc
                self.dismiss()
                return nil
            }
            // 未命中的无修饰按键静默吞掉，不发出系统提示音。
            guard let model = self.model,
                  let key = event.charactersIgnoringModifiers else { return nil }
            let keyScreen = self.panels.first { $0.isKeyWindow }?.screen
            guard let item = model.item(forKey: key, preferredScreen: keyScreen) else { return nil }
            self.select(item)
            return nil
        }
    }

    func dismiss() {
        guard model != nil || !panels.isEmpty else { return }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        model = nil
        let panels = self.panels
        self.panels = []
        for panel in panels {
            panel.orderOut(nil)
        }
    }
}

extension AppDelegate {
    /// “窗口”菜单的 Exposé 动作入口。
    @objc func showAllFoilsAction() {
        FoilExposeController.shared.toggle()
    }
}
