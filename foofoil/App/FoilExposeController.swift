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

/// 覆盖层中一个箔片的快照：打开的箔片收集自 AppDelegate.windowControllers，展示信息取自历史配置。
/// controller 为 nil 表示占位卡（新建空白箔）或历史记录条目（isHistoryEntry）。
struct FoilExposeItem: Identifiable {
    let id: UUID
    let controller: FloatingWindowController?
    let isHistoryEntry: Bool
    let title: String
    let symbolName: String
    let contentKind: HistoryContentKind
    let thumbnailPath: String?

    var window: NSWindow? { controller?.window }
    var isNewFoil: Bool { controller == nil && !isHistoryEntry }

    /// 关键字匹配：标题不区分大小写与变音符号的包含匹配。
    func matches(query: String) -> Bool {
        title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// 面板视图回传的整页滚动请求：token 区分相邻两次请求。
struct FoilExposePageScrollRequest: Equatable {
    let direction: FoilExposeMoveDirection
    let token: UUID
}

/// 覆盖层的共享模型：覆盖层只在当前活跃显示器上展示一块面板，键盘监听与选择回调共用同一份条目。
/// 打开的箔片在前、历史记录在后的统一列表；关键字搜索即时过滤，输入状态与结果展示分离。
@MainActor
final class FoilExposeModel: ObservableObject {
    /// 打开的箔片条目。
    let items: [FoilExposeItem]
    /// 历史记录条目。
    let historyItems: [FoilExposeItem]
    /// 当前键盘高亮的条目下标（对应 currentItems）；默认高亮第一项。
    @Published var selectedIndex: Int = 0
    /// 搜索关键字；输入时即时过滤，退出输入后关键字与过滤结果仍保留。
    @Published var searchText: String = "" {
        didSet {
            // 过滤结果变化后回到第一项，避免高亮落在已被过滤掉的条目上。
            if selectedIndex != 0 { selectedIndex = 0 }
        }
    }
    /// 是否处于搜索输入状态：Esc 只退出输入并保留关键字，不关闭覆盖层。
    @Published var isSearching: Bool = false
    /// 搜索输入框聚焦请求序号：面板稍后成为 key window 或 FocusState 落空时，视图据此重新聚焦。
    @Published var searchFieldFocusRequest: UInt64 = 0
    /// 最新的整页滚动请求；面板视图认领执行。
    @Published var pageScrollRequest: FoilExposePageScrollRequest?
    /// 网格实际列数，由面板视图从卡片外框推导回填，供上下移动跨行使用。
    var columnCount: Int = 4
    var onSelect: (FoilExposeItem) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    /// 面板视图当前可见条目的 id（按显示顺序），随滚动实时回填；编号直选只命中可见项。
    private var visibleIDs: [UUID] = []

    init(items: [FoilExposeItem], historyItems: [FoilExposeItem]) {
        self.items = items
        self.historyItems = historyItems
    }

    /// 去掉首尾空白后的搜索关键字；空字符串表示不过滤。
    var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 打开的箔片在前、历史记录在后的完整列表；已在打开的箔片中出现的条目不再重复显示；
    /// 有关键字时只保留标题匹配项。
    var currentItems: [FoilExposeItem] {
        let openIDs = Set(items.map(\.id))
        let combined = items + historyItems.filter { !openIDs.contains($0.id) }
        guard !searchQuery.isEmpty else { return combined }
        return combined.filter { $0.matches(query: searchQuery) }
    }

    /// 高亮条目：越界时回退到第一项。
    var highlightedItem: FoilExposeItem? {
        let items = currentItems
        return items.indices.contains(selectedIndex) ? items[selectedIndex] : items.first
    }

    /// 按 / 进入关键字输入状态；已有结果时保留关键字继续编辑。
    func beginSearch() {
        isSearching = true
    }

    /// 请求视图把第一响应者交给搜索输入框；面板刚成为 key window 时补一次聚焦。
    func requestSearchFieldFocus() {
        searchFieldFocusRequest &+= 1
    }

    /// Esc 退出搜索输入：保留关键字与过滤结果，编号直选恢复为无修饰键。
    func endSearch() {
        isSearching = false
    }

    /// 清除关键字并退出搜索输入，恢复完整列表。
    func clearSearch() {
        searchText = ""
        isSearching = false
        selectedIndex = 0
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

    /// Ctrl+A：高亮移到当前行首。行号 = 当前下标 / 列数，行首 = 行号 × 列数。
    func moveSelectionToRowStart() {
        guard !currentItems.isEmpty else { return }
        let columns = max(1, columnCount)
        let row = selectedIndex / columns
        selectedIndex = min(row * columns, currentItems.count - 1)
    }

    /// Ctrl+E：高亮移到当前行尾；末行可能不满一整行，夹紧到最后一个条目。
    func moveSelectionToRowEnd() {
        guard !currentItems.isEmpty else { return }
        let columns = max(1, columnCount)
        let row = selectedIndex / columns
        selectedIndex = min(row * columns + columns - 1, currentItems.count - 1)
    }

    /// 面板视图回填当前可见条目；随滚动实时更新。
    func setVisibleIDs(_ ids: [UUID]) {
        visibleIDs = ids
    }

    private var visibleKeyMap: [String: UUID] {
        var map: [String: UUID] = [:]
        for (index, id) in visibleIDs.enumerated() {
            guard let key = FoilExposeShortcut.key(forIndex: index) else { break }
            if map[key] == nil { map[key] = id }
        }
        return map
    }

    /// 按键先转大写再查询；编号直选只命中当前可见条目。
    func item(forKey key: String) -> FoilExposeItem? {
        let upper = key.uppercased()
        guard let id = visibleKeyMap[upper],
              let match = currentItems.first(where: { $0.id == id }) else { return nil }
        return match
    }

    /// 发起整页滚动：由面板滚动其内容，完成后把高亮重定位到可见第一项。
    func requestPageScroll(direction: FoilExposeMoveDirection) {
        pageScrollRequest = FoilExposePageScrollRequest(
            direction: direction,
            token: UUID()
        )
    }
}

/// 覆盖层面板：无边框、不抢激活，但需成为 key window 才能接收键盘事件。
final class FoilExposePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 自建 App Exposé：为每个屏幕铺一块覆盖层，打开的箔片在前、历史记录另起一行在后（半透明区分）。
/// 打开的箔片展示各窗口的历史缩略图；历史记录展示全部历史配置，选中即恢复为新箔片。
/// 支持 “/” 进入的关键字搜索，搜索输入时数字/字母直选改用 ⌃ 修饰。
/// 只复用历史缩略图，不抓新截图；不使用屏幕录制、辅助功能、输入监控或私有 API。
@MainActor
final class FoilExposeController {
    static let shared = FoilExposeController()

    private var panels: [FoilExposePanel] = []
    private var model: FoilExposeModel?
    private var keyMonitor: Any?
    private var showAllHotKeyRef: EventHotKeyRef?
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

    /// 启动入口：安装事件处理器并按当前配置注册“浮箔总览”的全局热键。
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
        showAllHotKeyRef = registerGlobalHotKey(definitionID: "window.showAllFoils", id: 1)
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
            NSLog("浮箔总览：全局热键注册失败（%d，命令 %@）", status, definitionID)
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
            NSLog("浮箔总览：全局热键事件处理器安装失败（%d）", status)
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
        // 没有任何箔窗口时也展示覆盖层：每个屏幕放一张“新建空白箔”占位卡。
        let model = FoilExposeModel(
            items: Self.collectItems(from: appDelegate.windowControllers),
            historyItems: Self.collectHistoryItems()
        )
        model.onSelect = { [weak self] item in self?.select(item) }
        model.onDismiss = { [weak self] in self?.dismiss() }
        self.model = model

        // 先激活本 App，再在当前活跃显示器上铺一块非激活面板并指定它为 key window。
        // 全局热键冷触发时激活是异步完成的，handleDidBecomeActive 会补交键盘焦点。
        NSApp.activate(ignoringOtherApps: true)
        if let screen = Self.activeScreen() {
            let panel = Self.makePanel(for: screen, model: model)
            panel.orderFront(nil)
            panels.append(panel)
        }
        if NSApp.isActive {
            focusPanel()
        }

        installKeyMonitor()
    }

    /// 覆盖层只铺在当前活跃显示器：优先本 App 的 key/main 窗口所在屏幕（菜单或前台触发），
    /// 其次鼠标所在屏幕（全局热键冷启动时本 App 没有活跃窗口），最后主屏。
    private static func activeScreen() -> NSScreen? {
        if let screen = (NSApp.keyWindow ?? NSApp.mainWindow)?.screen {
            return screen
        }
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// 让覆盖层面板成为 key window，接收键盘操作。
    private func focusPanel() {
        panels.first?.makeKeyAndOrderFront(nil)
        // 按 / 时面板可能尚未成为 key（全局热键冷启动的激活是异步的），成为 key 后补一次输入框聚焦。
        if model?.isSearching == true {
            model?.requestSearchFieldFocus()
        }
    }

    @objc private func handleDidBecomeActive() {
        guard isShowing else { return }
        focusPanel()
    }

    /// App 失去激活（如切到别的 App）时自动关闭覆盖层。
    @objc private func handleDidResignActive() {
        dismiss()
    }

    /// 收集当前全部箔片：保持窗口控制器顺序，不区分窗口所在屏幕。
    private static func collectItems(from windowControllers: [FloatingWindowController]) -> [FoilExposeItem] {
        windowControllers.compactMap { controller -> FoilExposeItem? in
            guard controller.window != nil else { return nil }
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

            return FoilExposeItem(
                id: controller.appState.id,
                controller: controller,
                isHistoryEntry: false,
                title: title,
                symbolName: config.historyMenuSymbolName,
                contentKind: contentKind,
                thumbnailPath: thumbnailPath
            )
        }
    }

    /// 历史记录条目：最近的历史配置，附在打开的箔片之后，点击/回车恢复为新箔片窗口。
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
        panel.contentView = NSHostingView(rootView: FoilExposeView(model: model))
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
            let key = event.charactersIgnoringModifiers?.lowercased()
            let onlyCommand = modifiers.contains(.command)
                && !modifiers.contains(.control) && !modifiers.contains(.option) && !modifiers.contains(.shift)
            let commandShift = modifiers.contains(.command) && modifiers.contains(.shift)
                && !modifiers.contains(.control) && !modifiers.contains(.option)
            let hasCommand = modifiers.contains(.command)
            let hasOption = modifiers.contains(.option)
            let hasControl = modifiers.contains(.control)
            // 输入法正在组合文字时，Esc / 回车 / Tab 留给输入法自己处理（取消候选、上屏）。
            let isComposing = (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
            // ⌘O/⌘P/⌘L/⌘⇧V 会打开文件对话框、历史搜索等新视图：先收起覆盖层再放行给菜单，
            // 避免打开的内容被覆盖层挡住。
            if onlyCommand, key == "o" || key == "p" || key == "l" {
                self.dismiss()
                return event
            }
            if commandShift, key == "v" {
                self.dismiss()
                return event
            }
            // 其余带命令修饰键的按键放行，让菜单快捷键（含再次触发的 ⌃⇧⎋ / ⌥⇧⎋）继续工作。
            if hasCommand {
                return event
            }
            // 带 ⌥ 的按键放行给菜单快捷键（如再次触发的 ⌥⇧⎋）。
            if hasOption {
                return event
            }
            if event.keyCode == 53 { // Esc：搜索状态下只退出搜索输入，否则关闭覆盖层
                if model.isSearching {
                    if isComposing { return event }
                    model.endSearch()
                    return nil
                }
                self.dismiss()
                return nil
            }
            // 搜索输入时 ⌃ 组合优先用于数字/字母直选；未命中条目的 ⌃ 组合交给输入框做文本编辑（如 ⌃A/E），
            // 非搜索状态沿用行首/行尾与方向移动。
            if hasControl {
                if model.isSearching {
                    if let key = event.charactersIgnoringModifiers,
                       let item = model.item(forKey: key) {
                        self.select(item)
                        return nil
                    }
                    return event
                }
                guard let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
                switch key {
                case "a": model.moveSelectionToRowStart()
                case "e": model.moveSelectionToRowEnd()
                case "p": model.moveSelection(.up)
                case "n": model.moveSelection(.down)
                case "b": model.moveSelection(.left)
                case "f": model.moveSelection(.right)
                default: return event
                }
                return nil
            }
            // ⇧↑/⇧↓ 与 PageUp/PageDown 等价：整页滚动，完成后高亮重定位到可见第一项。
            if modifiers.contains(.shift), event.keyCode == 125 || event.keyCode == 126 {
                model.requestPageScroll(direction: event.keyCode == 126 ? .up : .down)
                return nil
            }
            switch event.keyCode {
            case 48: // Tab：标签页已取消，吞掉以免焦点移出覆盖层；输入法组合时放行
                if model.isSearching, isComposing { return event }
                return nil
            case 116, 121: // PageUp / PageDown：整页滚动
                model.requestPageScroll(direction: event.keyCode == 116 ? .up : .down)
            case 36, 76: // 回车打开高亮箔片
                if model.isSearching, isComposing { return event }
                guard let highlighted = model.highlightedItem else { return nil }
                self.select(highlighted)
            case 123: model.moveSelection(.left)   // ←
            case 124: model.moveSelection(.right)  // →
            case 125: model.moveSelection(.down)   // ↓
            case 126: model.moveSelection(.up)     // ↑
            default:
                // 搜索输入状态：其余按键交给输入框，关键字实时过滤。
                if model.isSearching { return event }
                // 无修饰键的 / 进入搜索输入状态。
                if event.characters == "/" {
                    model.beginSearch()
                    return nil
                }
                // 编号/字母直选只命中当前可见项；未命中的无修饰按键静默吞掉，不发出系统提示音。
                guard let key = event.charactersIgnoringModifiers,
                      let item = model.item(forKey: key) else { return nil }
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
    /// “窗口”菜单的浮箔总览动作入口。
    @objc func showAllFoilsAction() {
        FoilExposeController.shared.toggle()
    }
}
