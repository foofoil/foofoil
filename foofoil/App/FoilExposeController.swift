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

/// 键盘高亮移动方向：左右逐项、上下按网格列数跨行；up/down 同时复用为整页滚动方向。
enum FoilExposeMoveDirection: Equatable {
    case up, down, left, right
}

/// 覆盖层的两个标签页：打开的箔片与历史记录。
enum FoilExposeTab: Int, CaseIterable {
    case openFoils
    case history

    var title: String {
        switch self {
        case .openFoils: return NSLocalizedString("Open Foils", comment: "")
        case .history: return NSLocalizedString("History", comment: "")
        }
    }
}

/// 覆盖层中一个箔片的快照：打开的箔片收集自 AppDelegate.windowControllers，展示信息取自历史配置。
/// controller 为 nil 表示占位卡（新建空白箔）或历史记录条目（isHistoryEntry）。
struct FoilExposeItem: Identifiable {
    let id: UUID
    let controller: FloatingWindowController?
    let isHistoryEntry: Bool
    let screen: NSScreen
    let title: String
    let symbolName: String
    let contentKind: HistoryContentKind
    let thumbnailPath: String?

    var window: NSWindow? { controller?.window }
    var isNewFoil: Bool { controller == nil && !isHistoryEntry }
}

/// 面板视图回传的整页滚动请求：token 区分相邻两次请求，screenID 限定只由目标屏幕的面板执行。
struct FoilExposePageScrollRequest: Equatable {
    let direction: FoilExposeMoveDirection
    let screenID: ObjectIdentifier
    let token: UUID
}

/// 覆盖层的共享模型：每个屏幕一个面板视图，键盘监听与选择回调共用同一份条目。
@MainActor
final class FoilExposeModel: ObservableObject {
    /// “打开的箔片”标签的条目。
    let items: [FoilExposeItem]
    /// “历史记录”标签的条目。
    let historyItems: [FoilExposeItem]
    /// 当前键盘高亮的条目下标（对应当前标签的条目数组）；默认高亮第一项。
    @Published var selectedIndex: Int = 0
    @Published var selectedTab: FoilExposeTab = .openFoils
    /// 最新的整页滚动请求；面板视图按 screenID 认领执行。
    @Published var pageScrollRequest: FoilExposePageScrollRequest?
    /// 网格实际列数，由面板视图从卡片外框推导回填，供上下移动跨行使用。
    var columnCount: Int = 4
    var onSelect: (FoilExposeItem) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    /// 每个屏幕当前可见条目的 id（按显示顺序），由面板视图随滚动实时回填；编号直选只命中可见项。
    private var visibleIDsByScreen: [ObjectIdentifier: [UUID]] = [:]

    init(items: [FoilExposeItem], historyItems: [FoilExposeItem]) {
        self.items = items
        self.historyItems = historyItems
    }

    var currentItems: [FoilExposeItem] {
        selectedTab == .openFoils ? items : historyItems
    }

    /// 当前标签里属于指定屏幕的条目，附带其在当前条目数组中的全局下标（键盘高亮使用）。
    func currentEntries(for screen: NSScreen) -> [(offset: Int, item: FoilExposeItem)] {
        switch selectedTab {
        case .openFoils:
            return items.enumerated().compactMap { entry in
                entry.element.screen === screen ? (entry.offset, entry.element) : nil
            }
        case .history:
            return historyItems.enumerated().map { ($0.offset, $0.element) }
        }
    }

    /// 高亮条目：越界时回退到第一项。
    var highlightedItem: FoilExposeItem? {
        let items = currentItems
        return items.indices.contains(selectedIndex) ? items[selectedIndex] : items.first
    }

    /// 切换标签页：重置高亮到第一项，并丢弃旧标签的可见编号。
    func switchTab(to tab: FoilExposeTab) {
        guard selectedTab != tab else { return }
        selectedTab = tab
        selectedIndex = 0
        visibleIDsByScreen = [:]
    }

    /// Tab 键循环切换标签页。
    func cycleTab(backward: Bool) {
        let all = FoilExposeTab.allCases
        guard let current = all.firstIndex(of: selectedTab) else { return }
        let next = backward ? (current + all.count - 1) % all.count : (current + 1) % all.count
        switchTab(to: all[next])
    }

    /// 移动键盘高亮，左右逐项、上下跨一行，越界时夹紧。
    func moveSelection(_ direction: FoilExposeMoveDirection) {
        guard !currentItems.isEmpty else { return }
        let columns = max(1, columnCount)
        let delta: Int
        switch direction {
        case .left: delta = -1
        case .right: delta = 1
        case .up: delta = -columns
        case .down: delta = columns
        }
        selectedIndex = min(max(0, selectedIndex + delta), currentItems.count - 1)
    }

    /// 面板视图回填本屏可见条目；随滚动实时更新。
    func setVisibleIDs(_ ids: [UUID], for screen: NSScreen) {
        visibleIDsByScreen[ObjectIdentifier(screen)] = ids
    }

    private func visibleKeyMap(for screen: NSScreen) -> [String: UUID] {
        guard let ids = visibleIDsByScreen[ObjectIdentifier(screen)] else { return [:] }
        var map: [String: UUID] = [:]
        for (index, id) in ids.enumerated() {
            guard let key = FoilExposeShortcut.key(forIndex: index) else { break }
            if map[key] == nil { map[key] = id }
        }
        return map
    }

    /// 按键先转大写再查询；优先命中 key 屏幕的可见编号，键重复时再扫描其他屏幕。
    func item(forKey key: String, preferredScreen: NSScreen?) -> FoilExposeItem? {
        let upper = key.uppercased()
        if let preferredScreen,
           let id = visibleKeyMap(for: preferredScreen)[upper],
           let match = currentItems.first(where: { $0.id == id }) {
            return match
        }
        for ids in visibleIDsByScreen.values {
            for (index, id) in ids.enumerated() {
                guard FoilExposeShortcut.key(forIndex: index)?.uppercased() == upper,
                      let match = currentItems.first(where: { $0.id == id }) else { continue }
                return match
            }
        }
        return nil
    }

    /// 发起整页滚动：由目标屏幕的面板滚动其内容，完成后把高亮重定位到可见第一项。
    func requestPageScroll(direction: FoilExposeMoveDirection, screen: NSScreen) {
        pageScrollRequest = FoilExposePageScrollRequest(
            direction: direction,
            screenID: ObjectIdentifier(screen),
            token: UUID()
        )
    }
}

/// 覆盖层面板：无边框、不抢激活，但需成为 key window 才能接收键盘事件。
final class FoilExposePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 自建 App Exposé：为每个屏幕铺一块覆盖层，分“打开的箔片”和“历史记录”两个标签页。
/// 打开的箔片展示各窗口的历史缩略图；历史记录展示全部历史配置，选中即恢复为新箔片。
/// 只复用历史缩略图，不抓新截图；不使用屏幕录制、辅助功能、输入监控或私有 API。
@MainActor
final class FoilExposeController {
    static let shared = FoilExposeController()

    private var panels: [FoilExposePanel] = []
    private var model: FoilExposeModel?
    private var keyMonitor: Any?
    private var showAllHotKeyRef: EventHotKeyRef?
    private var showHistoryHotKeyRef: EventHotKeyRef?
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

    /// 启动入口：安装事件处理器并按当前配置注册“显示所有箔片/历史箔片”的全局热键。
    /// 经 Carbon RegisterEventHotKey，浮箔未激活时也能唤起覆盖层；不需要输入监控或辅助功能权限。
    func installGlobalHotKey() {
        installEventHandlerIfNeeded()
        applyConfiguredGlobalHotKey()
    }

    /// 快捷键配置变更后重新注册全局热键。
    /// 仅当组合键含 Control/Option 且能映射为 Carbon 键码时才全局注册，避免吞掉系统常用快捷键。
    func applyConfiguredGlobalHotKey() {
        installEventHandlerIfNeeded()
        if let showAllHotKeyRef {
            _ = UnregisterEventHotKey(showAllHotKeyRef)
            self.showAllHotKeyRef = nil
        }
        if let showHistoryHotKeyRef {
            _ = UnregisterEventHotKey(showHistoryHotKeyRef)
            self.showHistoryHotKeyRef = nil
        }
        showAllHotKeyRef = registerGlobalHotKey(definitionID: "window.showAllFoils", id: 1)
        showHistoryHotKeyRef = registerGlobalHotKey(definitionID: "window.showHistoryFoils", id: 2)
    }

    private func registerGlobalHotKey(definitionID: String, id: UInt32) -> EventHotKeyRef? {
        guard let definition = KeyboardShortcutCatalog.definition(withID: definitionID),
              let shortcut = KeyboardShortcutStore.shared.shortcut(for: definition) else { return nil }
        let modifiers = shortcut.modifiers
        guard modifiers.contains(.control) || modifiers.contains(.option),
              let keyCode = shortcut.carbonKeyCode else { return nil }

        var hotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x464F_494C) /* 'FOIL' */, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard status == noErr else {
            NSLog("显示所有箔片：全局热键注册失败（%d，命令 %@）", status, definitionID)
            return nil
        }
        return hotKey
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
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                MainActor.assumeIsolated {
                    if hotKeyID.id == 2 {
                        FoilExposeController.shared.handleHistoryHotKey()
                    } else {
                        FoilExposeController.shared.handleGlobalHotKey()
                    }
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

    /// “显示历史箔片”入口：未展示时直接以历史记录标签打开；已展示时切到该标签，再按一次退出。
    func handleHistoryHotKey() {
        if isShowing {
            if model?.selectedTab == .history {
                dismiss()
            } else {
                model?.switchTab(to: .history)
            }
        } else {
            show(selectedTab: .history)
        }
    }

    /// 菜单入口：未展示时打开覆盖层，已展示时关闭。
    func toggle() {
        isShowing ? dismiss() : show()
    }

    func show(selectedTab tab: FoilExposeTab = .openFoils) {
        guard !isShowing,
              let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
        // 没有任何箔窗口时也展示覆盖层：每个屏幕放一张“新建空白箔”占位卡。
        let model = FoilExposeModel(
            items: Self.collectItems(from: appDelegate.windowControllers),
            historyItems: Self.collectHistoryItems()
        )
        model.selectedTab = tab
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

    /// 让鼠标所在屏幕的覆盖层面板成为 key window，接收键盘操作。
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

    /// 收集当前全部箔片：按屏幕排序后统一排序，展示信息取自历史配置。
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
                isHistoryEntry: false,
                screen: screen,
                title: title,
                symbolName: config.historyMenuSymbolName,
                contentKind: contentKind,
                thumbnailPath: thumbnailPath
            )))
        }

        // 按屏幕分组排序：每个屏幕的显示顺序都从该屏的第一个窗口开始，与编号一致。
        let grouped = Dictionary(grouping: collected) { $0.screenIndex }
            .sorted { $0.key < $1.key }
        return grouped.flatMap { _, entries in
            entries.sorted { $0.order < $1.order }.map(\.item)
        }
    }

    /// 历史记录标签的条目：最近的历史配置，点击/回车恢复为新箔片窗口。
    private static func collectHistoryItems() -> [FoilExposeItem] {
        HistoryRepository.shared.recent(limit: 500).map { config in
            let contentKind = config.contentKind ?? HistoryContentKind.infer(from: config)
            var thumbnailPath = config.thumbnailPath
            if thumbnailPath == nil, contentKind == .image || contentKind == .pdf {
                thumbnailPath = config.imagePath
            }
            var title = config.historyMenuDisplayName
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = NSLocalizedString("Untitled Note", comment: "")
            }
            return FoilExposeItem(
                id: config.id,
                controller: nil,
                isHistoryEntry: true,
                screen: NSScreen.main ?? NSScreen(),
                title: title,
                symbolName: config.historyMenuSymbolName,
                contentKind: contentKind,
                thumbnailPath: thumbnailPath
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

    /// 选择箔片：覆盖层先退场，再把目标窗口调度到最前；占位卡新建空白箔，历史条目恢复历史内容。
    private func select(_ item: FoilExposeItem) {
        guard let controller = item.controller, let window = item.window else {
            dismiss()
            NSApp.activate(ignoringOtherApps: true)
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            if item.isHistoryEntry {
                appDelegate?.openSearchResultInNewWindow(id: item.id)
            } else {
                appDelegate?.showNewWindow(with: AppState())
            }
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
            guard let self, let model = self.model else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // 带命令/选项修饰键的按键放行，让菜单快捷键（含再次触发的 ⌃⇧⎋ / ⌥⇧⎋）继续工作。
            if modifiers.contains(.command) || modifiers.contains(.option) {
                return event
            }
            if event.keyCode == 53 { // Esc
                self.dismiss()
                return nil
            }
            // Ctrl+P/N/F/B：emacs 风格移动高亮；其余带 Control 的组合放行给菜单快捷键。
            if modifiers.contains(.control) {
                guard let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
                switch key {
                case "p": model.moveSelection(.up)
                case "n": model.moveSelection(.down)
                case "b": model.moveSelection(.left)
                case "f": model.moveSelection(.right)
                default: return event
                }
                return nil
            }
            let keyScreen = self.panels.first { $0.isKeyWindow }?.screen
            // ⇧↑/⇧↓ 与 PageUp/PageDown 等价：整页滚动，完成后高亮重定位到可见第一项。
            if modifiers.contains(.shift), event.keyCode == 125 || event.keyCode == 126 {
                if let keyScreen {
                    model.requestPageScroll(direction: event.keyCode == 126 ? .up : .down, screen: keyScreen)
                }
                return nil
            }
            switch event.keyCode {
            case 48: // Tab / Shift+Tab：循环切换标签页
                model.cycleTab(backward: modifiers.contains(.shift))
            case 116, 121: // PageUp / PageDown：整页滚动
                if let keyScreen {
                    model.requestPageScroll(direction: event.keyCode == 116 ? .up : .down, screen: keyScreen)
                }
            case 36, 76: // 回车打开高亮箔片
                guard let highlighted = model.highlightedItem else { return nil }
                self.select(highlighted)
            case 123: model.moveSelection(.left)   // ←
            case 124: model.moveSelection(.right)  // →
            case 125: model.moveSelection(.down)   // ↓
            case 126: model.moveSelection(.up)     // ↑
            default:
                // 编号/字母直选只命中当前可见项；未命中的无修饰按键静默吞掉，不发出系统提示音。
                guard let key = event.charactersIgnoringModifiers,
                      let item = model.item(forKey: key, preferredScreen: keyScreen) else { return nil }
                self.select(item)
            }
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

    /// “窗口”菜单的“显示历史箔片”动作入口。
    @objc func showHistoryFoilsAction() {
        FoilExposeController.shared.handleHistoryHotKey()
    }
}
