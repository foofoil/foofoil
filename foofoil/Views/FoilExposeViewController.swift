import AppKit
import Combine
import SwiftUI

/// 总览使用原生视图树；共享业务模型，滚动不向模型发布几何状态。
final class FoilExposeViewController: NSViewController, NSTextFieldDelegate {
    let model: FoilExposeModel
    let searchField = NSTextField()
    private let hint = NSTextField(labelWithString: NSLocalizedString("Search Foils Hint", comment: ""))
    private let searchBackground = NSView()
    private let searchPrompt = QuickOpenPromptHostingView(rootView: QuickOpenSearchPrompt(musicLibraryEnabled: false))
    private let searchIcon = NSImageView()
    private let scopeButton = ExposeActionButton()
    private let newFoilButton = ExposeActionButton()
    private let clipboardButton = ExposeActionButton()
    private let categories = NSStackView()
    private let categoryScroll = NSScrollView()
    private let scopePicker = NSStackView()
    private let toast = NSStackView()
    private let toastIcon = NSImageView()
    private let toastLabel = NSTextField(wrappingLabelWithString: "")
    private let grid: FoilExposeGrid
    private var subscriptions: Set<AnyCancellable> = []
    private var updatePending = false
    private var categorySignature: [String] = []
    private var scopeSignature: [String] = []
    private var lastFocusRequest: UInt64?
    private var lastToastID: UUID?
    private var isDismissing = false

    init(model: FoilExposeModel) {
        self.model = model
        grid = FoilExposeGrid(model: model)
        super.init(nibName: nil, bundle: nil)
        grid.historyFilters = categoryScroll
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = ExposeBackgroundView()
        root.focusSearch = { [weak self] in self?.focusSearch() }
        view = root
        let material = NSVisualEffectView()
        material.material = .underWindowBackground
        material.blendingMode = .behindWindow
        material.state = .active
        material.frame = root.bounds
        material.autoresizingMask = [.width, .height]
        root.addSubview(material)
        let shade = NSView()
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
        shade.frame = root.bounds
        shade.autoresizingMask = [.width, .height]
        root.addSubview(shade)
        for child in [grid, hint, searchBackground, newFoilButton, clipboardButton, scopePicker, toast] {
            root.addSubview(child)
        }
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = .white.withAlphaComponent(0.62)
        hint.alignment = .center
        searchBackground.wantsLayer = true
        searchBackground.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        searchBackground.layer?.cornerRadius = 16
        searchBackground.layer?.borderColor = NSColor.white.withAlphaComponent(0.32).cgColor
        searchBackground.layer?.borderWidth = 1
        searchBackground.appearance = NSAppearance(named: .darkAqua)
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.usesSingleLineMode = true
        searchField.drawsBackground = false
        searchField.font = .systemFont(ofSize: 14)
        searchField.textColor = .white
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("expose.search")
        searchField.setAccessibilityLabel(NSLocalizedString("Search Foils Placeholder", comment: ""))
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .white.withAlphaComponent(0.55)
        searchIcon.imageScaling = .scaleProportionallyUpOrDown
        searchBackground.addSubview(searchIcon)
        searchBackground.addSubview(scopeButton)
        searchBackground.addSubview(searchField)
        searchPrompt.appearance = NSAppearance(named: .darkAqua)
        searchBackground.addSubview(searchPrompt)
        scopeButton.perform = { [weak self] in self?.model.clearActiveScope(); self?.focusSearch() }
        scopeButton.setAccessibilityLabel(NSLocalizedString("Clear Search Scope", comment: ""))
        newFoilButton.image = NSImage(systemSymbolName: "plus.rectangle.on.rectangle", accessibilityDescription: nil)
        newFoilButton.font = .systemFont(ofSize: 13, weight: .medium)
        newFoilButton.textOpacity = 0.88
        newFoilButton.setAccessibilityIdentifier("expose.newFoil")
        newFoilButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        newFoilButton.layer?.borderWidth = 1
        newFoilButton.perform = { [weak model] in model?.onNewFoil() }
        clipboardButton.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        clipboardButton.focusRingType = .none
        clipboardButton.textOpacity = 0.88
        clipboardButton.font = .systemFont(ofSize: 13, weight: .medium)
        clipboardButton.setAccessibilityIdentifier("expose.clipboard")
        clipboardButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        clipboardButton.layer?.borderWidth = 1
        clipboardButton.perform = { [weak model] in model?.onOpenClipboard() }
        categoryScroll.drawsBackground = false
        categoryScroll.hasHorizontalScroller = false
        categoryScroll.setAccessibilityIdentifier("expose.historyFilters")
        categoryScroll.scrollerStyle = .overlay
        categoryScroll.automaticallyAdjustsContentInsets = false
        categories.frame = NSRect(x: 0, y: 0, width: 4000, height: 32)
        categories.orientation = .horizontal
        categories.spacing = 6
        categoryScroll.documentView = categories
        scopePicker.frame = NSRect(x: 0, y: 0, width: 312, height: 1000)
        scopePicker.orientation = .vertical
        scopePicker.alignment = .leading
        scopePicker.spacing = 2
        scopePicker.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        scopePicker.wantsLayer = true
        scopePicker.layer?.cornerRadius = 10
        scopePicker.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        scopePicker.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        scopePicker.layer?.borderWidth = 1
        toast.frame = NSRect(x: 0, y: 0, width: 2000, height: 48)
        toast.orientation = .horizontal
        toast.spacing = 6
        toast.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        toast.wantsLayer = true
        toast.layer?.cornerRadius = 17
        toast.layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.98).cgColor
        toastLabel.textColor = .white
        toastLabel.font = .systemFont(ofSize: 13, weight: .medium)
        toastLabel.maximumNumberOfLines = 2
        toastIcon.contentTintColor = .white
        toastIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        toastIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        toast.addArrangedSubview(toastIcon)
        toast.addArrangedSubview(toastLabel)
        // objectWillChange 在赋值前发出；合并到下一次主循环再读取完整状态。
        model.objectWillChange.sink { [weak self] in self?.scheduleUpdate() }.store(in: &subscriptions)
        model.toast.objectWillChange.sink { [weak self] in self?.scheduleUpdate() }.store(in: &subscriptions)
        // 面板稍后成为 key（包括跨屏激活）时立即恢复输入，不依赖模型刷新时序。
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] notification in
                guard let self, let window = self.viewIfLoaded?.window,
                      notification.object as? NSWindow === window else { return }
                self.focusSearch()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .keyboardShortcutsDidChange)
            .sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &subscriptions)
        synchronize()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusSearch()
    }

    private func scheduleUpdate() {
        guard !isDismissing, !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updatePending = false
            self.synchronize()
        }
    }

    func synchronize() {
        guard !isDismissing else { return }
        let editor = searchField.currentEditor() as? NSTextView
        // 输入法组合文字归编辑器所有，其他模型通知不能重置候选输入或选区。
        if editor?.hasMarkedText() != true, searchField.stringValue != model.searchText {
            searchField.stringValue = model.searchText
            editor?.string = model.searchText
        }
        let placeholder = model.activeScope.map {
            $0.inputPlaceholder
        } ?? ""
        // AppKit 改写占位文字会重启 field editor；只提交最终值且跳过同值，
        // 避免编辑结束 → 请求聚焦 → 刷新占位文字的输入服务重建循环。
        if searchField.placeholderString != placeholder {
            searchField.placeholderString = placeholder
        }
        searchPrompt.rootView = QuickOpenSearchPrompt(musicLibraryEnabled: SettingsStore.shared.appleMusicSearchEnabled) { [weak self] in
            self?.model.searchText = "/"
            self?.focusSearch()
        }
        searchPrompt.isHidden = !model.searchText.isEmpty || model.activeScope != nil
        searchField.setAccessibilityLabel(QuickOpenSearchPrompt.title(musicLibraryEnabled: SettingsStore.shared.appleMusicSearchEnabled))
        scopeButton.isHidden = model.activeScope == nil
        scopeButton.title = model.activeScope.map { $0.displayName + "  ×" } ?? ""
        scopeButton.setAccessibilityLabel(NSLocalizedString("Clear Search Scope", comment: ""))
        scopeButton.image = model.activeScope.flatMap { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: nil) }
        hint.isHidden = model.isChoosingScope
        newFoilButton.title = NSLocalizedString(model.isOptionPressed ? "New Incognito Foil" : "New foofoil", comment: "")
        newFoilButton.shortcutText = model.isOptionPressed ? "⇧⌘N" : "⌘N"
        clipboardButton.isHidden = model.clipboardContent == nil || model.activeScope == .clipboard
        if let content = model.clipboardContent {
            let title = model.isOptionPressed
                ? NSLocalizedString("Open Clipboard Incognito", comment: "")
                : String(format: NSLocalizedString("Open Clipboard Item Format", comment: ""), content.localizedName)
            let shortcut = (model.isOptionPressed
                ? KeyboardShortcutStore.shared.incognitoShortcut(forID: "file.openClipboardContent")
                : KeyboardShortcutStore.shared.shortcut(for: KeyboardShortcutCatalog.openClipboardContent))?.displayString
            clipboardButton.title = title
            clipboardButton.shortcutText = shortcut
        }
        updateCategories()
        updateScopes()
        updateToast()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        grid.update(model: model)
        if lastFocusRequest != model.searchFieldFocusRequest {
            lastFocusRequest = model.searchFieldFocusRequest
            focusSearch()
        }
        searchBackground.layer?.borderWidth = 2
        searchBackground.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
    }

    private func updateCategories() {
        categoryScroll.isHidden = !model.showsHistorySection
        let values = model.visibleHistoryCategories
        let shortcut = KeyboardShortcutStore.shared.shortcut(forID: "history.filterFavorites")?.displayString ?? ""
        let signature = values.map { "\($0.rawValue):\(model.historyCount(in: $0))" }
            + [model.historyCategory.rawValue, String(model.pinnedOnly), shortcut]
        guard categorySignature != signature else { return }
        categorySignature = signature
        categories.arrangedSubviews.forEach { categories.removeArrangedSubview($0); $0.removeFromSuperview() }
        for category in values {
            let button = ExposeActionButton()
            button.setAccessibilityIdentifier("expose.category." + category.rawValue)
            button.title = NSLocalizedString(category.localizationKey, comment: "") + "  \(model.historyCount(in: category).formatted())"
            button.image = NSImage(systemSymbolName: category.symbolName, accessibilityDescription: nil)
            button.isEmphasized = model.historyCategory == category
            button.perform = { [weak self] in self?.model.historyCategory = category; self?.focusSearch() }
            let menu = NSMenu()
            let clear = NSMenuItem(title: category.clearHistoryTitle, action: #selector(clearCategory(_:)), keyEquivalent: "")
            clear.target = self
            clear.representedObject = category.rawValue
            menu.addItem(clear)
            button.menu = menu
            categories.addArrangedSubview(button)
        }
        let favorite = ExposeActionButton()
        favorite.setAccessibilityIdentifier("expose.favorites")
        favorite.title = [NSLocalizedString("Favorited History", comment: ""), shortcut].filter { !$0.isEmpty }.joined(separator: "  ")
        favorite.image = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: nil)
        favorite.isEmphasized = model.pinnedOnly
        favorite.perform = { [weak self] in self?.model.pinnedOnly.toggle(); self?.focusSearch() }
        categories.addArrangedSubview(favorite)
        let width = categories.arrangedSubviews.reduce(0) { $0 + $1.intrinsicContentSize.width }
            + CGFloat(max(0, categories.arrangedSubviews.count - 1)) * categories.spacing
        categories.frame = NSRect(x: 0, y: 0, width: width, height: 32)
        categoryScroll.superview?.needsLayout = true
    }

    private func updateScopes() {
        scopePicker.isHidden = !model.isChoosingScope
        let scopes = model.filteredScopes
        let signature = scopes.map { $0.id }
            + [model.directAction?.id ?? "-", String(model.highlightedScopeIndex), String(model.isChoosingScope), String(model.isOptionPressed)]
        guard scopeSignature != signature else { return }
        scopeSignature = signature
        scopePicker.arrangedSubviews.forEach { scopePicker.removeArrangedSubview($0); $0.removeFromSuperview() }
        // 直接输入的路径/网址借用范围下拉框，作为唯一且默认高亮的打开项。
        if let directAction = model.directAction {
            addDirectActionButton(directAction)
            return
        }
        for (index, scope) in scopes.enumerated() {
            let button = ExposeActionButton()
            button.scopeRow = true
            button.title = model.scopeTitle(scope)
            button.scopeSuffix = scope.isEnableAction ? nil : scope.englishName
            button.toolTip = model.scopeTitle(scope)
            button.setAccessibilityIdentifier("expose.scope." + scope.id)
            button.isEnabled = model.isScopeEnabled(scope)
            button.image = NSImage(systemSymbolName: scope.symbolName, accessibilityDescription: nil)
            button.isEmphasized = index == model.highlightedScopeIndex
            button.perform = { [weak self] in self?.model.selectScope(scope); self?.focusSearch() }
            button.widthAnchor.constraint(equalToConstant: scopePickerWidth - 12).isActive = true
            scopePicker.addArrangedSubview(button)
        }
        if scopes.isEmpty {
            let notice = NSTextField(labelWithString: NSLocalizedString("No Matching Scopes", comment: ""))
            notice.textColor = .white.withAlphaComponent(0.75)
            notice.setAccessibilityIdentifier("expose.scope.noMatches")
            scopePicker.addArrangedSubview(notice)
        }
    }

    /// 直接打开项使用与范围列表相同的下拉框外观；完整路径或网址放在帮助提示中。
    private func addDirectActionButton(_ action: DirectSearchAction) {
        let button = ExposeActionButton()
        let width = scopePickerWidth - 12
        let title: String
        let tooltip: String
        switch action {
        case .file(let file):
            let key = file.isDirectory ? "Open Folder Search Result Format" : "Open File Search Result Format"
            title = String(format: NSLocalizedString(key, comment: ""), file.name)
            tooltip = file.url.path
            button.setAccessibilityIdentifier("expose.scope.openFile")
            button.image = NSImage(systemSymbolName: file.symbolName, accessibilityDescription: nil)
        case .url(let url):
            title = String(format: NSLocalizedString("Open URL Search Result Format", comment: ""), url.absoluteString)
            tooltip = url.absoluteString
            button.setAccessibilityIdentifier("expose.scope.openURL")
            button.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        }
        button.title = fittedTitle(title, width: max(40, width - 37))
        button.toolTip = tooltip
        button.isEmphasized = true
        button.perform = { [weak self] in self?.model.openDirectAction(); self?.focusSearch() }
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        scopePicker.addArrangedSubview(button)
    }

    /// 直接打开项的名字可能很长，按按钮实际可用宽度截断，避免文字溢出下拉框。
    private func fittedTitle(_ title: String, width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        guard (title as NSString).size(withAttributes: attributes).width > width else { return title }
        var text = title
        while text.count > 1 {
            text.removeLast()
            let candidate = text + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= width { return candidate }
        }
        return "…"
    }

    private var scopePickerWidth: CGFloat {
        guard model.directAction != nil else { return 312 }
        return max(312, min(520, view.bounds.width - 40))
    }

    private func updateToast() {
        let message = model.toast.message
        toast.isHidden = message == nil
        toastLabel.stringValue = message?.text ?? ""
        toastIcon.image = message?.usesIncognitoIcon == true ? IncognitoFoilIcon.image
            : message?.symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        toastIcon.isHidden = toastIcon.image == nil
        if let message, message.id != lastToastID {
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
                .announcement: message.text, .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ])
        }
        lastToastID = message?.id
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width
        // 按钮随内容变化，但最多占顶部可用宽度的一半；搜索框吸收剩余空间。
        let rowWidth = max(0, min(1000, width - 40))
        let buttonWidth = clipboardButton.isHidden ? 0 : min(clipboardButton.intrinsicContentSize.width, rowWidth * 0.5)
        let gap: CGFloat = clipboardButton.isHidden ? 0 : 12
        let newWidth = min(newFoilButton.intrinsicContentSize.width, rowWidth * 0.3)
        let searchWidth = max(0, rowWidth - buttonWidth - gap - newWidth - 12)
        let left = (width - rowWidth) / 2
        let scopeWidth: CGFloat = scopeButton.isHidden ? 0 : min(180, max(0, searchWidth - 100), scopeButton.intrinsicContentSize.width)
        searchBackground.frame = NSRect(x: left, y: 30, width: searchWidth, height: 32)
        newFoilButton.frame = NSRect(x: left + searchWidth + 12, y: 30, width: newWidth, height: 32)
        clipboardButton.frame = NSRect(x: left + searchWidth + 12 + newWidth + gap, y: 30, width: buttonWidth, height: 32)
        searchIcon.frame = NSRect(x: 12, y: 10, width: 12, height: 12)
        scopeButton.frame = NSRect(x: 31, y: 3, width: scopeWidth, height: 26)
        // 按原生单行文本的实际高度居中，让占位文字、光标和编辑文字共用同一基线。
        let fieldHeight = ceil(searchField.cell?.cellSize.height ?? 19)
        searchField.frame = NSRect(x: 31 + scopeWidth, y: (32 - fieldHeight) / 2,
                                   width: max(20, searchBackground.bounds.width - scopeWidth - 43), height: fieldHeight)
        searchPrompt.frame = searchField.frame
        hint.frame = NSRect(x: 20, y: 70, width: max(0, width - 40), height: 20)
        grid.frame = NSRect(x: 0, y: 106, width: width, height: max(0, view.bounds.height - 106))
        let pickerSize = NSSize(width: scopePickerWidth, height: scopePicker.arrangedSubviews.reduce(12) {
            $0 + max(16, $1.intrinsicContentSize.height) + 2
        })
        scopePicker.frame = NSRect(x: searchBackground.frame.minX, y: 68, width: pickerSize.width, height: pickerSize.height)
        let toastSize = NSSize(width: min(max(100, width - 16), toastLabel.intrinsicContentSize.width + (toastIcon.isHidden ? 0 : 22) + 24),
                               height: max(34, toastLabel.intrinsicContentSize.height + 14))
        toast.frame = NSRect(x: (width - toastSize.width) / 2, y: 10, width: toastSize.width, height: toastSize.height)
    }

    func controlTextDidChange(_ obj: Notification) { model.searchText = searchField.stringValue }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard canFocusSearch else { return }
        model.requestSearchFieldFocus()
    }
    private var canFocusSearch: Bool {
        guard !isDismissing, isViewLoaded, let window = view.window else { return false }
        return window.isVisible && window.isKeyWindow && window.attachedSheet == nil
    }
    private func focusSearch() {
        guard canFocusSearch, let window = view.window else { return }
        if let editor = searchField.currentEditor(), window.firstResponder === editor { return }
        window.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
    }

    /// 先停掉焦点恢复，再结束编辑，避免隐藏面板时重新激活系统输入 UI。
    func prepareForDismissal() {
        isDismissing = true
        subscriptions.removeAll()
        viewIfLoaded?.window?.endEditing(for: searchField)
    }
    @objc private func clearCategory(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let category = FoilExposeHistoryCategory(rawValue: raw) else { return }
        model.onClearHistory(category)
    }
}

private final class ExposeBackgroundView: NSView {
    var focusSearch: (() -> Void)?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { focusSearch?() }
}

private final class ExposeActionButton: NSButton {
    override var title: String {
        didSet { setAccessibilityLabel(title); invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var perform: (() -> Void)?
    var scopeRow = false {
        didSet {
            font = .systemFont(ofSize: 13)
            layer?.cornerRadius = 8
            invalidateIntrinsicContentSize()
            updateStyle()
        }
    }
    var scopeSuffix: String? { didSet { needsDisplay = true } }
    var isEmphasized = false { didSet { updateStyle() } }
    override var acceptsFirstResponder: Bool { false }
    init() {
        super.init(frame: .zero)
        bezelStyle = .recessed
        isBordered = false
        font = .systemFont(ofSize: 12, weight: .medium)
        imagePosition = .imageLeading
        contentTintColor = .white
        wantsLayer = true
        layer?.cornerRadius = 16
        target = self
        action = #selector(invoke)
        updateStyle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var textOpacity: CGFloat = 0.65
    var shortcutText: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)]).width
        let keycap = shortcutText.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold)]).width + 20 } ?? 0
        return NSSize(width: ceil(text) + (image == nil ? 0 : 19) + keycap + 18, height: scopeRow ? 36 : 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        if scopeRow {
            let textColor = NSColor.white.withAlphaComponent(0.95)
            let secondaryColor = NSColor.white.withAlphaComponent(0.55)
            if let image {
                let symbol = image.withSymbolConfiguration(.init(paletteColors: [secondaryColor])) ?? image
                symbol.draw(in: NSRect(x: 14, y: (bounds.height - 16) / 2, width: 16, height: 16),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let suffix = scopeSuffix.map { NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: secondaryColor]) }
            let suffixWidth = suffix.map { $0.size().width } ?? 0
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: textColor, .paragraphStyle: paragraph])
            text.draw(in: NSRect(x: 42, y: (bounds.height - text.size().height) / 2,
                                 width: max(0, bounds.width - 54 - (suffixWidth > 0 ? suffixWidth + 10 : 0)), height: text.size().height))
            if let suffix {
                suffix.draw(at: NSPoint(x: bounds.width - 12 - suffixWidth, y: (bounds.height - suffix.size().height) / 2))
            }
            return
        }
        // NSButton 的默认 imageLeading 会贴住边缘，显式绘制内边距但保留原生点击和菜单行为。
        let color = NSColor.white.withAlphaComponent(isHighlighted ? 1 : (isEmphasized ? 0.95 : textOpacity))
        var x: CGFloat = 9
        if let image {
            let symbol = image.withSymbolConfiguration(.init(paletteColors: [color])) ?? image
            symbol.draw(in: NSRect(x: x, y: (bounds.height - 14) / 2, width: 14, height: 14),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += 19
        }
        let text = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 12), .foregroundColor: color])
        let keyWidth = shortcutText.map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold)]).width + 29 } ?? 9
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let fitted = NSMutableAttributedString(attributedString: text)
        fitted.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: fitted.length))
        fitted.draw(in: NSRect(x: x, y: (bounds.height - text.size().height) / 2,
                              width: max(0, bounds.width - x - keyWidth), height: text.size().height))
        if let shortcutText {
            let key = NSAttributedString(string: shortcutText, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: color])
            let rect = NSRect(x: bounds.width - key.size().width - 19, y: (bounds.height - 22) / 2, width: key.size().width + 10, height: 22)
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            NSColor.white.withAlphaComponent(0.18).setFill(); path.fill()
            NSColor.white.withAlphaComponent(0.38).setStroke(); path.lineWidth = 1; path.stroke()
            key.draw(at: NSPoint(x: rect.minX + 5, y: (bounds.height - key.size().height) / 2))
        }
    }

    private func updateStyle() {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(isEmphasized ? 0.2 : (scopeRow ? 0 : 0.07)).cgColor
        setAccessibilityValue(isEmphasized ? 1 : 0)
        needsDisplay = true
    }
    @objc private func invoke() { perform?() }
}
