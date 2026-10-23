import AppKit
import Combine

/// 总览使用原生视图树；共享业务模型，滚动不向模型发布几何状态。
final class FoilExposeViewController: NSViewController, NSTextFieldDelegate {
    let model: FoilExposeModel
    let searchField = NSTextField()
    private let heading = NSTextField(labelWithString:
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? "foofoil")
    private let hint = NSTextField(labelWithString: NSLocalizedString("Search Foils Hint", comment: ""))
    private let searchBackground = NSView()
    private let searchIcon = NSImageView()
    private let scopeButton = ExposeActionButton()
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
        for child in [grid, heading, hint, searchBackground, clipboardButton, scopePicker, toast] {
            root.addSubview(child)
        }
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        heading.textColor = .white
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
        scopeButton.perform = { [weak self] in self?.model.clearActiveScope(); self?.focusSearch() }
        scopeButton.setAccessibilityLabel(NSLocalizedString("Clear Search Scope", comment: ""))
        clipboardButton.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
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
        NotificationCenter.default.publisher(for: .keyboardShortcutsDidChange)
            .sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &subscriptions)
        synchronize()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusSearch()
    }

    private func scheduleUpdate() {
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updatePending = false
            self.synchronize()
        }
    }

    func synchronize() {
        let editor = searchField.currentEditor() as? NSTextView
        // 输入法组合文字归编辑器所有，其他模型通知不能重置候选输入或选区。
        if editor?.hasMarkedText() != true, searchField.stringValue != model.searchText {
            searchField.stringValue = model.searchText
            editor?.string = model.searchText
        }
        searchField.placeholderString = model.activeScope.map {
            String(format: NSLocalizedString("Search In Scope Placeholder", comment: ""), $0.displayName)
        } ?? NSLocalizedString("Search Foils Placeholder", comment: "")
        scopeButton.isHidden = model.activeScope == nil
        scopeButton.title = model.activeScope.map { $0.displayName + "  ×" } ?? ""
        scopeButton.setAccessibilityLabel(NSLocalizedString("Clear Search Scope", comment: ""))
        scopeButton.image = model.activeScope.flatMap { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: nil) }
        hint.isHidden = model.isPickingScope
        clipboardButton.isHidden = model.clipboardContent == nil
        if let content = model.clipboardContent {
            let title = String(format: NSLocalizedString("Open Clipboard Item Format", comment: ""), content.localizedName)
            let shortcut = KeyboardShortcutStore.shared.shortcut(for: KeyboardShortcutCatalog.openClipboardContent)?.displayString
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
    }

    private func updateCategories() {
        categoryScroll.isHidden = !model.showsHistorySection
        let values = model.visibleHistoryCategories
        let shortcut = KeyboardShortcutStore.shared.shortcut(forID: "history.toggleFavorite")?.displayString ?? ""
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
        scopePicker.isHidden = !model.isPickingScope
        let scopes = model.filteredScopes
        let signature = scopes.map { $0.id } + [String(model.highlightedScopeIndex), String(model.isPickingScope)]
        guard scopeSignature != signature else { return }
        scopeSignature = signature
        scopePicker.arrangedSubviews.forEach { scopePicker.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (index, scope) in scopes.enumerated() {
            let button = ExposeActionButton()
            button.title = scope.displayName + "    " + scope.englishName
            button.image = NSImage(systemSymbolName: scope.symbolName, accessibilityDescription: nil)
            button.isEmphasized = index == model.highlightedScopeIndex
            button.perform = { [weak self] in self?.model.selectScope(scope); self?.focusSearch() }
            button.widthAnchor.constraint(equalToConstant: 300).isActive = true
            scopePicker.addArrangedSubview(button)
        }
        if scopes.isEmpty {
            scopePicker.addArrangedSubview(NSTextField(labelWithString: NSLocalizedString("No Matching Scopes", comment: "")))
        }
        let tip = NSTextField(labelWithString: NSLocalizedString("Scope Hints Tip", comment: ""))
        tip.font = .systemFont(ofSize: 10)
        tip.textColor = .white.withAlphaComponent(0.55)
        scopePicker.addArrangedSubview(tip)
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
        let titleWidth = heading.intrinsicContentSize.width
        let scopeWidth: CGFloat = scopeButton.isHidden ? 0 : min(180, scopeButton.intrinsicContentSize.width)
        let searchWidth = min(480, 260 + scopeWidth)
        let left = max(20, (width - titleWidth - 14 - searchWidth) / 2)
        heading.frame = NSRect(x: left, y: 30, width: titleWidth, height: 32)
        searchBackground.frame = NSRect(x: left + titleWidth + 14, y: 30, width: max(80, min(searchWidth, width - left - titleWidth - 34)), height: 32)
        searchIcon.frame = NSRect(x: 12, y: 10, width: 12, height: 12)
        scopeButton.frame = NSRect(x: 31, y: 3, width: scopeWidth, height: 26)
        // 按原生单行文本的实际高度居中，让占位文字、光标和编辑文字共用同一基线。
        let fieldHeight = ceil(searchField.cell?.cellSize.height ?? 19)
        searchField.frame = NSRect(x: 31 + scopeWidth, y: (32 - fieldHeight) / 2,
                                   width: max(20, searchBackground.bounds.width - scopeWidth - 43), height: fieldHeight)
        hint.frame = NSRect(x: 20, y: 70, width: max(0, width - 40), height: 20)
        var top: CGFloat = 106
        if !clipboardButton.isHidden {
            let size = clipboardButton.intrinsicContentSize
            let inset = FoilExposeGridMetrics(width: width, compact: false).inset
            clipboardButton.frame = NSRect(x: max(inset, width - inset - size.width), y: top, width: size.width, height: 32)
            top += 44
        }
        grid.frame = NSRect(x: 0, y: top, width: width, height: max(0, view.bounds.height - top))
        let pickerSize = NSSize(width: 312, height: scopePicker.arrangedSubviews.reduce(12) {
            $0 + max(16, $1.intrinsicContentSize.height) + 2
        })
        scopePicker.frame = NSRect(x: searchBackground.frame.minX, y: 68, width: pickerSize.width, height: pickerSize.height)
        let toastSize = NSSize(width: min(max(100, width - 16), toastLabel.intrinsicContentSize.width + (toastIcon.isHidden ? 0 : 22) + 24),
                               height: max(34, toastLabel.intrinsicContentSize.height + 14))
        toast.frame = NSRect(x: (width - toastSize.width) / 2, y: 10, width: toastSize.width, height: toastSize.height)
    }

    func controlTextDidChange(_ obj: Notification) { model.searchText = searchField.stringValue }
    func controlTextDidEndEditing(_ obj: Notification) { model.requestSearchFieldFocus() }
    private func focusSearch() {
        guard let window = view.window else { return }
        if let editor = searchField.currentEditor(), window.firstResponder === editor { return }
        window.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        }
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
        return NSSize(width: ceil(text) + (image == nil ? 0 : 19) + keycap + 18, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
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
        text.draw(at: NSPoint(x: x, y: (bounds.height - text.size().height) / 2))
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
        layer?.backgroundColor = NSColor.white.withAlphaComponent(isEmphasized ? 0.2 : 0.07).cgColor
        setAccessibilityValue(isEmphasized ? 1 : 0)
        needsDisplay = true
    }
    @objc private func invoke() { perform?() }
}
