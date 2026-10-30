import AppKit
import Combine

/// 固定网格只由可用宽度决定；滚动不重新测量每张卡片的全局坐标。
struct FoilExposeGridMetrics {
    let columns: Int
    let itemSize: NSSize
    let inset: CGFloat

    init(width: CGFloat, compact: Bool) {
        let available = max(1, min(1240, width) - 88)
        let spacing: CGFloat = compact ? 10 : 18
        let minimum: CGFloat = compact ? 320 : 212
        columns = max(1, Int((available + spacing) / (minimum + spacing)))
        let itemWidth = min(compact ? 620 : 300,
                            (available - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        itemSize = NSSize(width: itemWidth, height: compact ? 58 : itemWidth + 28)
        inset = max(0, (width - (CGFloat(columns) * itemWidth + CGFloat(columns - 1) * spacing)) / 2)
    }

    /// 终端卡片统一使用两列宽度；新建项由独立分区保持独占一行。
    init(terminalWidth width: CGFloat) {
        let available = max(1, min(1240, width) - 88)
        columns = 2
        itemSize = NSSize(width: max(1, (available - 10) / 2), height: 80)
        inset = max(0, (width - available) / 2)
    }
}

/// 选中项的滚动策略：完全可见不动；只露出一部分时最小滚动到完整可见；完全在视口外时居中。
enum FoilExposeGridScrollTarget {
    static func originY(itemFrame: NSRect, visibleRect: NSRect, maximum: CGFloat, revealTop: Bool = false) -> CGFloat? {
        if revealTop { return visibleRect.minY > 0 ? 0 : nil }
        guard !visibleRect.contains(itemFrame) else { return nil }
        let target: CGFloat
        if itemFrame.intersects(visibleRect) {
            target = itemFrame.minY < visibleRect.minY
                ? itemFrame.minY
                : itemFrame.maxY - visibleRect.height
        } else {
            target = itemFrame.midY - visibleRect.height / 2
        }
        return min(maximum, max(0, target))
    }
}

/// 整页滚动后的高亮落点：优先选完整可见的第一项，没有时退回第一个相交项。
enum FoilExposeGridPageSelection {
    static func firstIndex(candidates: [(index: Int, frame: NSRect)], visibleRect: NSRect) -> Int? {
        (candidates.first { visibleRect.contains($0.frame) } ?? candidates.first)?.index
    }
}

/// 原生总览滚动区：卡片、排版和滚动均由 AppKit 承担。
final class FoilExposeGrid: NSScrollView {
    private let coordinator: Coordinator
    var historyFilters: NSScrollView? {
        didSet { coordinator.historyFilters = historyFilters }
    }

    init(model: FoilExposeModel) {
        coordinator = Coordinator(model: model)
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        scrollerStyle = .overlay
        automaticallyAdjustsContentInsets = false
        let collection = ExposeCollectionView()
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.collectionViewLayout = ExposeFlowLayout()
        collection.dataSource = coordinator
        collection.delegate = coordinator
        collection.register(ExposeCollectionItem.self, forItemWithIdentifier: .exposeCard)
        collection.register(ExposeAuthorizationItem.self, forItemWithIdentifier: .exposeAuthorization)
        collection.register(ExposeSectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: .exposeHeader)
        collection.frame = NSRect(origin: .zero, size: contentSize)
        collection.autoresizingMask = [.width]
        documentView = collection
        coordinator.collection = collection
        coordinator.scroll = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(model: FoilExposeModel) { coordinator.update(model: model) }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = frame.width != newSize.width
        super.setFrameSize(newSize)
        // 窗口首次布置和屏幕宽度变化才重算列数，滚动不经过这里。
        if widthChanged { coordinator.update(model: coordinator.model) }
    }


    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        struct Entry {
            var foil: FoilExposeItem?
            var index: Int?
            var title: String
            var subtitle = ""
            var symbol = "doc"
            var action: (() -> Void)?
            var key: String {
                // 更新只随模型变化执行；滚动不会重新生成或比较这些数据。
                [foil?.id.uuidString ?? "", title, subtitle, symbol, foil?.thumbnailPath ?? "",
                 foil?.bodyPreview ?? "", String(foil?.historyIsPinned ?? false), String(foil?.isClipboardContent ?? false), String(foil?.clipboardEntry?.isCurrentClipboard ?? false), foil?.clipboardEntry?.sourceBundleIdentifier ?? "",
                 String(foil?.controller?.appState.isIncognito ?? false), String(foil?.hasHistoryRecord ?? false),
                 String(foil?.canRenameTitle ?? false), String(foil?.isHistoryEntry ?? false), String(index ?? -1)].joined(separator: "\u{1F}")
            }
        }
        struct Section {
            let title: String
            let compact: Bool
            var count: Int? = nil
            var symbol = "doc"
            var tint: NSColor = .white.withAlphaComponent(0.7)
            var terminalLayout = false
            var isHistory = false
            var isClipboardAuthorization = false
            var moreTitle: String? = nil
            var moreAction: (() -> Void)? = nil
            var entries: [Entry]
        }
        var model: FoilExposeModel
        weak var collection: NSCollectionView?
        weak var scroll: NSScrollView?
        var historyFilters: NSScrollView?
        private weak var historyHeader: ExposeSectionHeader?
        private var sections: [Section] = []
        private var signature: [[String]] = []
        private var previousSelection: Int?
        private var previousRevealRequest: UInt64?
        private var previousCategory: FoilExposeHistoryCategory?
        private var previousQuery: String?
        private var pageToken: UUID?

        init(model: FoilExposeModel) { self.model = model }

        func update(model: FoilExposeModel) {
            self.model = model
            guard let collection, let scroll else { return }
            model.columnCount = FoilExposeGridMetrics(width: scroll.contentSize.width, compact: false).columns
            model.musicColumnCount = FoilExposeGridMetrics(width: scroll.contentSize.width, compact: true).columns
            let items = model.currentItems
            func foilEntries(_ indices: [Int]) -> [Entry] {
                indices.map { index in
                    let item = items[index]
                    return Entry(foil: item, index: index, title: item.title,
                                 subtitle: item.terminalConfiguration?.historySubtitle ?? item.musicItem?.searchSubtitle ?? "", symbol: item.symbolName,
                                 action: { model.activateItem(item) })
                }
            }
            var next: [Section] = []
            if model.isInlineOpeningScope {
                let scope = model.activeScope!
                var entries = foilEntries(Array(items.indices))
                if entries.isEmpty { entries = [Entry(title: NSLocalizedString("No Search Results", comment: ""))] }
                if scope == .terminal {
                    next.append(Section(title: scope.displayName, compact: true, symbol: scope.symbolName,
                                        terminalLayout: true, entries: Array(entries.prefix(1))))
                    if entries.count > 1 {
                        next.append(Section(title: "", compact: true, symbol: scope.symbolName,
                                            terminalLayout: true, entries: Array(entries.dropFirst())))
                    }
                } else {
                    next.append(Section(title: scope.displayName, compact: false, symbol: scope.symbolName, entries: entries))
                }
            }
            let open = items.indices.filter { !items[$0].isHistoryEntry && items[$0].musicItem == nil && items[$0].clipboardEntry == nil }
            if !model.isInlineOpeningScope && !open.isEmpty { next.append(Section(title: NSLocalizedString("Expose Open Section", comment: ""), compact: false, count: open.filter { !items[$0].isNewFoil }.count, symbol: "macwindow", tint: .systemMint, entries: foilEntries(open))) }
            if model.showsHistorySection {
                let history = items.indices.filter { items[$0].isHistoryEntry }
                var entries = foilEntries(history)
                if entries.isEmpty { entries = [Entry(title: NSLocalizedString("Expose History Category Empty", comment: ""))] }
                next.append(Section(title: NSLocalizedString("Expose History Section", comment: ""), compact: history.isEmpty, count: model.historyCount(in: model.historyCategory), symbol: "clock.arrow.circlepath", isHistory: true,
                                    moreTitle: model.canShowMoreHistory ? NSLocalizedString("Search More History", comment: "") : nil,
                                    moreAction: model.canShowMoreHistory ? { model.selectScope(.history) } : nil, entries: entries))
            }
            if model.showsClipboardSection {
                let indices = items.indices.filter { items[$0].clipboardEntry != nil }
                var entries = foilEntries(indices)
                if model.clipboardSearch.isLoading { entries.append(Entry(title: NSLocalizedString("Clipboard History Loading", comment: ""))) }
                else if entries.isEmpty && model.activeScope == .clipboard { entries.append(Entry(title: NSLocalizedString("No Search Results", comment: ""))) }
                if model.activeScope == .clipboard {
                    if model.clipboardSearch.access == .unavailable {
                        entries.append(Entry(title: NSLocalizedString("Clipboard History Unavailable", comment: "")))
                        entries.append(Entry(title: NSLocalizedString("Retry File Search", comment: ""), action: { model.clipboardSearch.refresh() }))
                    }
                }
                if let notice = model.clipboardSearch.copyError { entries.append(Entry(title: notice)) }
                if !entries.isEmpty || model.activeScope == .clipboard || model.clipboardSearch.access == .needsAuthorization {
                    next.append(Section(title: NSLocalizedString("Clipboard Search Scope", comment: ""), compact: true,
                                        count: model.clipboardCount, symbol: "doc.on.clipboard", tint: .systemCyan,
                                        moreTitle: model.canShowMoreClipboard ? NSLocalizedString("More Clipboard History", comment: "") : nil,
                                        moreAction: model.canShowMoreClipboard ? { let query = model.searchQuery; model.selectScope(.clipboard); model.searchText = query } : nil, entries: entries))
                }
                if model.clipboardSearch.access == .needsAuthorization {
                    next.append(Section(title: "", compact: true, isClipboardAuthorization: true,
                                        entries: [Entry(title: NSLocalizedString("Clipboard History Authorization Instructions", comment: ""))]))
                }
            }
            if !model.isInlineOpeningScope && model.activeScope != nil && model.activeScope != .history && model.activeScope != .clipboard && model.searchQuery.isEmpty {
                next.append(Section(title: "", compact: true, entries: [Entry(title: NSLocalizedString("Enter Keywords to Search Scope", comment: ""), symbol: "magnifyingglass")]))
            }
            if model.showsFileResults {
                var entries = model.visibleFiles.enumerated().map { offset, file in
                    Entry(index: items.count + offset, title: file.name, subtitle: file.url.deletingLastPathComponent().path,
                          symbol: file.symbolName, action: { model.onOpenFile(file.url) })
                }
                if model.canExpandFileResults {
                    entries.append(Entry(title: NSLocalizedString(model.resultFilter.moreFilesLocalizationKey, comment: ""),
                                         symbol: "ellipsis", action: { model.expandFileResults() }))
                }
                if model.isFileSearching {
                    entries.append(Entry(title: NSLocalizedString(model.resultFilter.searchingFilesLocalizationKey, comment: ""), symbol: "magnifyingglass"))
                } else if let status = model.fileStatus {
                    entries.append(Entry(title: NSLocalizedString(status.localizationKey, comment: "")))
                    entries.append(Entry(title: NSLocalizedString(status == .disabled ? "Enable File Search" : "Retry File Search", comment: ""),
                                         action: { if status == .disabled { model.enableFileSearch() } else { model.restartFileSearch() } }))
                } else if entries.isEmpty {
                    entries.append(Entry(title: NSLocalizedString(model.resultFilter.noFilesLocalizationKey, comment: "")))
                }
                if let notice = model.fileSearchNotice { entries.append(Entry(title: notice)) }
                next.append(Section(title: NSLocalizedString(model.resultFilter.fileSectionLocalizationKey, comment: ""), compact: true, count: model.visibleFiles.count, symbol: "doc.text.magnifyingglass", tint: .systemCyan, entries: entries))
            }
            if model.showsMusicResults {
                for category in AppleMusicSearchCategory.allCases where model.resultFilter.includes(category) {
                    let indices = items.indices.filter { items[$0].musicItem?.searchCategory == category }
                    guard !indices.isEmpty else { continue }
                    var entries = foilEntries(indices)
                    if model.canExpandMusicResults(in: category) {
                        entries.append(Entry(title: NSLocalizedString(category.moreLocalizationKey, comment: ""), symbol: "ellipsis",
                                             action: { model.expandMusicResults(in: category) }))
                    }
                    next.append(Section(title: NSLocalizedString(category.sectionLocalizationKey, comment: ""), compact: true, count: indices.count, symbol: category.symbolName, tint: .systemPink, entries: entries))
                }
                let status = model.isMusicSearching ? NSLocalizedString("Searching Music Library", comment: "")
                    : (!model.isMusicAuthorized ? NSLocalizedString("Music Search Authorization Note", comment: "") : model.musicError)
                if let status {
                    next.append(Section(title: "", compact: true, entries: [Entry(title: status)]))
                } else if model.visibleMusicItems.isEmpty {
                    next.append(Section(title: "", compact: true, entries: [Entry(title: NSLocalizedString("Music No Search Results", comment: ""))]))
                }
            }
            if model.showsResultLimitNotice {
                next.append(Section(title: "", compact: true, entries: [Entry(title: String(format: NSLocalizedString("Search Result Limit Notice Format", comment: ""), model.displayedResultCount))]))
            }
            if next.isEmpty {
                next = [Section(title: "", compact: true, entries: [Entry(title: NSLocalizedString("No Foils on This Screen", comment: ""))])]
            }
            let nextSignature = next.map { [$0.title, String($0.compact), String($0.terminalLayout), String($0.count ?? -1), String($0.isClipboardAuthorization), $0.moreTitle ?? ""] + $0.entries.map(\.key) }
            // 不在选中项、焦点或滚动变化时 reloadData，保留复用卡片和已解码图片。
            let changed = nextSignature != signature
            sections = next
            if changed {
                signature = nextSignature
                collection.reloadData()
                collection.layoutSubtreeIfNeeded()
            }
            historyHeader?.needsLayout = true
            let metrics = FoilExposeGridMetrics(width: scroll.contentSize.width, compact: false)
            let musicMetrics = FoilExposeGridMetrics(width: scroll.contentSize.width, compact: true)
            model.columnCount = metrics.columns
            model.musicColumnCount = musicMetrics.columns
            if let previousQuery, previousQuery != model.searchText {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            if previousSelection != model.selectedIndex || previousRevealRequest != model.selectionRevealRequest {
                if previousSelection != nil, previousCategory == model.historyCategory,
                   let path = indexPath(for: model.selectedIndex),
                   let frame = collection.layoutAttributesForItem(at: path)?.frame,
                   let y = FoilExposeGridScrollTarget.originY(
                       itemFrame: frame,
                       visibleRect: scroll.documentVisibleRect,
                       maximum: max(0, collection.bounds.height - scroll.contentSize.height),
                       revealTop: previousRevealRequest != model.selectionRevealRequest && model.isSelectionInFirstRow) {
                    // 键盘导航到第一行时露出顶部标题；其余位置只确保卡片完整可见。
                    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            for case let item as ExposeCollectionItem in collection.visibleItems() {
                guard let path = collection.indexPath(for: item), sections.indices.contains(path.section),
                      sections[path.section].entries.indices.contains(path.item) else { continue }
                let entry = sections[path.section].entries[path.item]
                item.card.setHighlighted(entry.index == model.selectedIndex)
            }
            previousSelection = model.selectedIndex
            previousRevealRequest = model.selectionRevealRequest
            previousCategory = model.historyCategory
            previousQuery = model.searchText
            if let request = model.pageScrollRequest, request.token != pageToken {
                pageToken = request.token
                let y = scroll.contentView.bounds.minY + (request.direction == .down ? 1 : -1) * max(160, scroll.contentSize.height - 160)
                let maximum = max(0, collection.bounds.height - scroll.contentSize.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, y))))
                scroll.reflectScrolledClipView(scroll.contentView)
                let visibleRect = scroll.documentVisibleRect
                let paths = collection.indexPathsForVisibleItems().sorted {
                    $0.section == $1.section ? $0.item < $1.item : $0.section < $1.section
                }
                var candidates: [(index: Int, frame: NSRect)] = []
                for path in paths {
                    guard let frame = collection.layoutAttributesForItem(at: path)?.frame,
                          frame.intersects(visibleRect),
                          let index = sections[path.section].entries[path.item].index else { continue }
                    candidates.append((index, frame))
                }
                // 整页后高亮优先落在完整可见的第一项，避免选中只露出一角的卡片后又触发修正滚动。
                let first = FoilExposeGridPageSelection.firstIndex(candidates: candidates, visibleRect: visibleRect)
                if let first { DispatchQueue.main.async { [weak model] in model?.selectedIndex = first } }
            }
        }

        private func indexPath(for index: Int) -> IndexPath? {
            for (section, data) in sections.enumerated() {
                if let item = data.entries.firstIndex(where: { $0.index == index }) { return IndexPath(item: item, section: section) }
            }
            return nil
        }
        func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].entries.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let section = sections[indexPath.section]
            if section.isClipboardAuthorization {
                let item = collectionView.makeItem(withIdentifier: .exposeAuthorization, for: indexPath) as! ExposeAuthorizationItem
                item.configure { [weak model] in model?.clipboardSearch.openAuthorizationSettings() }
                return item
            }
            let item = collectionView.makeItem(withIdentifier: .exposeCard, for: indexPath) as! ExposeCollectionItem
            let entry = section.entries[indexPath.item]
            item.card.configure(foil: entry.foil, title: entry.title, subtitle: entry.subtitle, symbol: entry.symbol,
                                compact: section.compact, terminalStyle: section.terminalLayout, shortcut: entry.foil == nil ? nil : entry.index.flatMap { FoilExposeShortcut.key(forIndex: $0) },
                                highlighted: entry.index == model.selectedIndex, action: entry.action, model: model)
            return item
        }
        func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
            let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: .exposeHeader, for: indexPath) as! ExposeSectionHeader
            let section = sections[indexPath.section]
            header.leadingInset = section.terminalLayout ? FoilExposeGridMetrics(terminalWidth: collectionView.bounds.width).inset : nil
            header.configure(title: section.title, count: section.count, symbol: section.symbol,
                             tint: section.tint, filters: section.isHistory ? historyFilters : nil,
                             moreTitle: section.moreTitle, moreAction: section.moreAction)
            header.setAccessibilityIdentifier(section.isHistory ? "expose.section.history" : "expose.section." + section.symbol)
            if section.isHistory { historyHeader = header }
            return header
        }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
            let width = scroll?.contentSize.width ?? collectionView.bounds.width
            if sections[indexPath.section].isClipboardAuthorization {
                let metrics = FoilExposeGridMetrics(width: width, compact: true)
                let itemWidth = max(1, width - 2 * metrics.inset)
                let text = NSLocalizedString("Clipboard History Authorization Instructions", comment: "") as NSString
                let textHeight = text.boundingRect(with: NSSize(width: max(1, itemWidth - 32), height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: [.font: NSFont.systemFont(ofSize: 14)]).height
                return NSSize(width: itemWidth, height: ceil(textHeight) + 62)
            }
            let section = sections[indexPath.section]
            if section.terminalLayout { return FoilExposeGridMetrics(terminalWidth: width).itemSize }
            return FoilExposeGridMetrics(width: width, compact: section.compact).itemSize
        }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, insetForSectionAt section: Int) -> NSEdgeInsets {
            let width = scroll?.contentSize.width ?? collectionView.bounds.width
            let metrics = sections[section].terminalLayout
                ? FoilExposeGridMetrics(terminalWidth: width)
                : FoilExposeGridMetrics(width: width, compact: sections[section].compact)
            return NSEdgeInsets(top: sections[section].isClipboardAuthorization ? 0 : 8,
                                left: metrics.inset, bottom: sections[section].terminalLayout ? 10 : 32, right: metrics.inset)
        }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, minimumInteritemSpacingForSectionAt section: Int) -> CGFloat { sections[section].compact ? 10 : 18 }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat { sections[section].compact ? 10 : 18 }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> NSSize {
            NSSize(width: collectionView.bounds.width, height: sections[section].title.isEmpty ? 0 : 42)
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let exposeCard = Self("ExposeNativeCard")
    static let exposeAuthorization = Self("ExposeAuthorization")
    static let exposeHeader = Self("ExposeNativeHeader")
}

private final class ExposeCollectionView: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }
}

private final class ExposeFlowLayout: NSCollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else { return false }
        return newBounds.width != collectionView.bounds.width
    }
}

private final class ExposeSectionHeader: NSView {
    var leadingInset: CGFloat?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let countBadge = NSView()
    private let moreButton = NSButton()
    private var moreAction: (() -> Void)?
    private weak var filters: NSScrollView?
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white.withAlphaComponent(0.9)
        label.maximumNumberOfLines = 1
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 9
        icon.imageScaling = .scaleNone
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .white.withAlphaComponent(0.65)
        countLabel.alignment = .center
        countBadge.wantsLayer = true
        countBadge.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        countBadge.layer?.cornerRadius = 10
        countBadge.setAccessibilityIdentifier("expose.section.count")
        countBadge.addSubview(countLabel)
        moreButton.isBordered = false
        moreButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        moreButton.contentTintColor = .white.withAlphaComponent(0.65)
        moreButton.target = self
        moreButton.action = #selector(showMore)
        for child in [icon, label, countBadge, moreButton] { addSubview(child) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, count: Int?, symbol: String, tint: NSColor, filters: NSScrollView?,
                   moreTitle: String?, moreAction: (() -> Void)?) {
        isHidden = title.isEmpty
        label.stringValue = title
        countLabel.stringValue = count?.formatted() ?? ""
        countBadge.isHidden = count == nil
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        icon.contentTintColor = tint
        icon.layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
        if self.filters !== filters, self.filters?.superview === self { self.filters?.removeFromSuperview() }
        self.filters = filters
        if let filters, filters.superview !== self { addSubview(filters) }
        self.moreAction = moreAction
        moreButton.isHidden = moreAction == nil
        moreButton.toolTip = moreTitle
        moreButton.setAccessibilityLabel(moreTitle)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = leadingInset ?? FoilExposeGridMetrics(width: bounds.width, compact: false).inset
        let center = bounds.midY
        icon.frame = NSRect(x: inset, y: center - 15, width: 30, height: 30)
        let labelSize = label.cell?.cellSize ?? .zero
        label.frame = NSRect(x: icon.frame.maxX + 10, y: center - labelSize.height / 2,
                             width: labelSize.width + 4, height: labelSize.height)
        let countWidth = max(24, (countLabel.cell?.cellSize.width ?? 0) + 14)
        countBadge.frame = NSRect(x: label.frame.maxX + 10, y: center - 10, width: countWidth, height: 20)
        let countHeight = countLabel.cell?.cellSize.height ?? 14
        countLabel.frame = NSRect(x: 0, y: (20 - countHeight) / 2, width: countWidth, height: countHeight)
        let countEnd = countBadge.isHidden ? label.frame.maxX : countBadge.frame.maxX
        moreButton.frame = NSRect(x: countEnd + 4, y: center - 12, width: 24, height: 24)
        let headingEnd = moreButton.isHidden ? countEnd : moreButton.frame.maxX
        let right = bounds.width - inset
        if let filters {
            // 分类与历史标题同一行；窄窗口只压缩横向滚动区，不压缩标题。
            let naturalWidth = filters.documentView?.frame.width ?? 0
            let width = min(naturalWidth, max(0, right - headingEnd - 16))
            filters.frame = NSRect(x: right - width, y: center - 16, width: width, height: 32)
        }
    }

    @objc private func showMore() { moreAction?() }
}

private final class ExposeAuthorizationItem: NSCollectionViewItem {
    private let note = NSTextField(wrappingLabelWithString: NSLocalizedString("Clipboard History Authorization Instructions", comment: ""))
    private let button = NSButton(title: NSLocalizedString("Clipboard History Authorize", comment: ""), target: nil, action: nil)
    private var perform: (() -> Void)?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        view.layer?.cornerRadius = 10
        note.font = .systemFont(ofSize: 14)
        note.textColor = .white.withAlphaComponent(0.85)
        note.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.appearance = NSAppearance(named: .darkAqua)
        button.target = self
        button.action = #selector(authorize)
        button.setAccessibilityIdentifier("clipboard.authorize")
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(note)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            note.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            button.leadingAnchor.constraint(equalTo: note.leadingAnchor),
            button.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
            button.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -10)
        ])
    }

    func configure(perform: @escaping () -> Void) { self.perform = perform }
    @objc private func authorize() { perform?() }
}

private final class ExposeCollectionItem: NSCollectionViewItem {
    var card: ExposeNativeCard { view as! ExposeNativeCard }
    override func loadView() { view = ExposeNativeCard() }
    override func prepareForReuse() {
        super.prepareForReuse()
        card.reset()
    }
}

/// 原生卡片保持子视图结构不变；复用只换数据，悬停仅改变图层和描边。
private final class ExposeThumbnailView: NSView {
    override var isFlipped: Bool { true }
}

/// 阴影随图像轮廓直接绘制，避免 NSImageView 的内部图层让外层阴影失效。
private final class ExposeShadowedIcon: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let symbol = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            if image.isTemplate, let tint = self.contentTintColor {
                tint.setFill()
                rect.fill(using: .sourceIn)
            }
            return true
        }
        let available = bounds.insetBy(dx: 3, dy: 3)
        let scale = min(available.width / max(1, image.size.width), available.height / max(1, image.size.height))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.95)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        symbol.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// 按键文字按字体行高居中，避免随胶囊高度沿用 NSTextField 的顶部对齐。
private final class ExposeShortcutCell: NSTextFieldCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let height = min(cellFrame.height, cellSize(forBounds: cellFrame).height)
        let centered = NSRect(x: cellFrame.minX, y: cellFrame.midY - height / 2,
                              width: cellFrame.width, height: height)
        super.drawInterior(withFrame: centered, in: controlView)
    }
}

private final class ExposeNativeCard: NSView {
    private let thumbnail = ExposeThumbnailView()
    private let imageLayer = CALayer()
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private let typeIcon = ExposeShadowedIcon()
    private let favicon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let clipboardIcon = NSImageView()
    private let copyButton = NSButton()
    private let clipboardArtwork = ClipboardEntryArtworkView()
    private let dashedBorder = CAShapeLayer()
    private let playback = CALayer()
    private var playbackSubscription: AnyCancellable?
    private let pinned = ExposeShadowedIcon()
    private let incognito = NSImageView()
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var highlighted = false
    private var compact = false
    private var terminalStyle = false
    private var isNotice = false
    private var foil: FoilExposeItem?
    private weak var model: FoilExposeModel?
    private var action: (() -> Void)?
    private var loader: FoilExposeThumbnailLoader?
    private var imageSubscription: AnyCancellable?
    private var loadTask: Task<Void, Never>?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 10
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        thumbnail.layer?.addSublayer(imageLayer)
        thumbnail.layer?.addSublayer(dashedBorder)
        thumbnail.layer?.addSublayer(playback)
        dashedBorder.fillColor = nil
        dashedBorder.lineDashPattern = [6, 4]
        for index in 0..<4 {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = 2
            bar.frame = CGRect(x: index * 9, y: 0, width: 5, height: 24)
            playback.addSublayer(bar)
        }
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = .white.withAlphaComponent(0.85)
        preview.maximumNumberOfLines = 8
        preview.lineBreakMode = .byTruncatingTail
        preview.isSelectable = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .white.withAlphaComponent(0.9)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .white.withAlphaComponent(0.5)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        badge.cell = ExposeShortcutCell(textCell: "")
        badge.isEditable = false
        badge.isSelectable = false
        badge.isBordered = false
        badge.drawsBackground = false
        badge.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        pinned.image = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: nil)
        incognito.image = IncognitoFoilIcon.image
        for image in [icon, typeIcon, pinned, incognito, clipboardIcon] {
            image.contentTintColor = .white
            image.imageScaling = .scaleProportionallyUpOrDown
        }
        pinned.contentTintColor = .systemYellow
        favicon.imageScaling = .scaleProportionallyUpOrDown
        favicon.wantsLayer = true
        favicon.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.9).cgColor
        favicon.layer?.cornerRadius = 5
        addSubview(thumbnail)
        thumbnail.addSubview(favicon)
        for view in [preview, icon, typeIcon, badge, pinned, incognito] { thumbnail.addSubview(view) }
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: NSLocalizedString("Clipboard History Copy", comment: ""))
        copyButton.isBordered = false
        copyButton.contentTintColor = .white.withAlphaComponent(0.8)
        copyButton.toolTip = NSLocalizedString("Clipboard History Copy", comment: "")
        copyButton.setAccessibilityLabel(NSLocalizedString("Clipboard History Copy", comment: ""))
        copyButton.target = self; copyButton.action = #selector(copyClipboardEntry)
        copyButton.isHidden = true
        addSubview(copyButton)
        clipboardArtwork.appearance = NSAppearance(named: .darkAqua)
        clipboardArtwork.isHidden = true
        addSubview(clipboardArtwork)
        addSubview(clipboardIcon)
        addSubview(titleLabel)
        addSubview(subtitleLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityChildren([])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { loadTask?.cancel() }

    func reset() {
        loadTask?.cancel(); loadTask = nil
        imageSubscription = nil; loader = nil
        action = nil; foil = nil; model = nil
        clipboardArtwork.prepareForReuse(); clipboardArtwork.isHidden = true
        playbackSubscription = nil
        updatePlayback(false)
        imageLayer.contents = nil
        hovered = false
    }

    func configure(foil: FoilExposeItem?, title: String, subtitle: String, symbol: String,
                   compact: Bool, terminalStyle: Bool = false, shortcut: String?, highlighted: Bool, action: (() -> Void)?, model: FoilExposeModel) {
        reset()
        self.foil = foil; self.model = model; self.action = action; self.compact = compact; self.terminalStyle = terminalStyle
        self.highlighted = highlighted
        copyButton.isHidden = foil?.clipboardEntry == nil || foil?.clipboardEntry?.isCurrentClipboard == true
        copyButton.isEnabled = foil?.clipboardEntry?.canCopy == true
        copyButton.setAccessibilityIdentifier(foil?.clipboardEntry.map { "clipboard.copy.\($0.id)" })
        setAccessibilityChildren(copyButton.isHidden ? [] : [copyButton])
        isNotice = compact && action == nil && foil == nil
        thumbnail.isHidden = isNotice
        titleLabel.font = .systemFont(ofSize: terminalStyle ? 17 : 12, weight: isNotice ? .regular : .medium)
        titleLabel.textColor = .white.withAlphaComponent(isNotice ? 0.55 : 0.9)
        titleLabel.stringValue = title
        titleLabel.alignment = compact ? .left : .center
        subtitleLabel.font = .systemFont(ofSize: terminalStyle ? 13 : 11)
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = !compact || subtitle.isEmpty
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.lineBreakMode = .byTruncatingTail
        preview.attributedStringValue = NSAttributedString(string: foil?.bodyPreview ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .paragraphStyle: paragraph
        ])
        preview.isHidden = compact || preview.stringValue.isEmpty
        icon.image = NSImage(systemSymbolName: foil?.isNewFoil == true ? "plus" : symbol, accessibilityDescription: nil)
        icon.isHidden = foil?.clipboardEntry != nil || (!compact && !preview.isHidden)
        if let entry = foil?.clipboardEntry {
            clipboardArtwork.isHidden = false; clipboardArtwork.configure(entry)
        }
        favicon.image = foil.flatMap { $0.contentKind == .web && $0.controller?.appState.isIncognito != true ? WebFaviconCache.image(for: $0.id) : nil }
        favicon.isHidden = compact || favicon.image == nil
        typeIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        typeIcon.isHidden = compact || foil?.isNewFoil != false
        if terminalStyle, foil?.terminalConfiguration?.ssh != nil {
            typeIcon.image = NSImage(systemSymbolName: "network", accessibilityDescription: NSLocalizedString("Terminal SSH", comment: ""))
            typeIcon.isHidden = false
        }
        if symbol == AppleMusicReference.symbolName {
            icon.image = Self.musicIcon
            typeIcon.image = Self.musicIcon
        }
        clipboardIcon.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        clipboardIcon.isHidden = compact || foil?.isClipboardContent != true
        dashedBorder.isHidden = foil?.isNewFoil != true
        if let state = foil?.controller?.appState, foil?.contentKind == .audio || foil?.contentKind == .video {
            playbackSubscription = state.$isMediaPlaying.sink { [weak self] playing in self?.updatePlayback(playing) }
        }
        pinned.isHidden = (compact && !terminalStyle) || foil?.historyIsPinned != true
        incognito.isHidden = compact || foil?.controller?.appState.isIncognito != true
        badge.stringValue = shortcut.map { "⌃" + $0 } ?? ""
        badge.isHidden = shortcut == nil
        let annotation = foil?.historyIsPinned == true ? NSLocalizedString("Favorited History", comment: "") + " " : ""
        setAccessibilityLabel([badge.stringValue, annotation + title, foil?.terminalConfiguration?.ssh != nil ? NSLocalizedString("Terminal SSH", comment: "") : "", subtitle].filter { !$0.isEmpty }.joined(separator: " "))
        setAccessibilityRole(action == nil ? .staticText : .button)
        toolTip = subtitle.isEmpty ? title : title + "\n" + subtitle
        if !compact, let path = foil?.thumbnailPath {
            let loader = FoilExposeThumbnailLoader()
            self.loader = loader
            imageSubscription = loader.$image.sink { [weak self] image in
                guard let self else { return }
                self.imageLayer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                if image != nil { self.preview.isHidden = true; self.icon.isHidden = true }
            }
            loadTask = Task { await loader.load(path: path) }
        }
        needsLayout = true
        updateAppearance(animated: false)
    }

    func setHighlighted(_ value: Bool) {
        guard highlighted != value else { return }
        highlighted = value
        updateAppearance()
    }
    private func updateAppearance(animated: Bool = true) {
        thumbnail.layer?.borderColor = NSColor.white.withAlphaComponent(highlighted ? 0.85 : (hovered ? 0.5 : 0.16)).cgColor
        thumbnail.layer?.borderWidth = dashedBorder.isHidden ? (highlighted ? 2 : 1) : 0
        dashedBorder.strokeColor = NSColor.white.withAlphaComponent(highlighted ? 0.85 : (hovered ? 0.5 : 0.24)).cgColor
        dashedBorder.lineWidth = highlighted ? 2 : 1
        setAccessibilitySelected(highlighted)
        updateEmphasisTransform(animated: animated)
    }

    private func updateEmphasisTransform(animated: Bool) {
        guard let layer else { return }
        let scale: CGFloat = action != nil && (hovered || highlighted) ? 1.03 : 1.0
        // AppKit 管理图层锚点；以平移补偿缩放，让卡片中心固定，也避免修改锚点干扰集合布局。
        let offsetX = bounds.width * (0.5 - layer.anchorPoint.x) * (1 - scale)
        let offsetY = bounds.height * (0.5 - layer.anchorPoint.y) * (1 - scale)
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offsetX, ty: offsetY)
        let previous = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(transform)
        CATransaction.commit()
        if animated {
            // 缩放和平移共用弹簧进度，动画途中也始终围绕中心。
            let animation = CASpringAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: previous)
            animation.toValue = NSValue(caTransform3D: layer.transform)
            animation.stiffness = 200
            animation.damping = 25
            animation.duration = 0.35
            layer.add(animation, forKey: "expose-emphasis")
        }
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let side = compact ? bounds.height : bounds.width
        thumbnail.frame = compact ? NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
            : NSRect(x: 0, y: 0, width: side, height: side)
        imageLayer.frame = thumbnail.bounds
        dashedBorder.frame = thumbnail.bounds
        dashedBorder.path = CGPath(roundedRect: thumbnail.bounds.insetBy(dx: 1, dy: 1), cornerWidth: 10, cornerHeight: 10, transform: nil)
        playback.frame = NSRect(x: (thumbnail.bounds.width - 32) / 2, y: (thumbnail.bounds.height - 24) / 2, width: 32, height: 24)
        preview.frame = NSRect(x: 12, y: 12, width: max(0, side - 24), height: max(0, min(side - 24, 152)))
        clipboardArtwork.frame = NSRect(x: 8, y: 7, width: 44, height: 44)
        let artworkInset: CGFloat = clipboardArtwork.isHidden ? 0 : 12
        icon.frame = compact ? NSRect(x: 10, y: 14, width: 30, height: 30)
            : NSRect(x: (side - 44) / 2, y: (side - 44) / 2, width: 44, height: 44)
        if !compact, foil?.contentKind == .camera {
            icon.frame = NSRect(x: (side - 56) / 2, y: (side - 56) / 2, width: 56, height: 56)
        }
        favicon.frame = NSRect(x: side - 29, y: side - 29, width: 23, height: 23)
        typeIcon.frame = NSRect(x: 4, y: max(0, side - 32), width: 28, height: 28)
        pinned.frame = NSRect(x: side - 36, y: 4, width: 28, height: 28)
        incognito.frame = NSRect(x: side - 33, y: side - 33, width: 22, height: 22)
        let badgeWidth = max(28, badge.intrinsicContentSize.width + 12)
        let copyInset: CGFloat = copyButton.isHidden ? 0 : 28
        copyButton.frame = NSRect(x: bounds.width - 34, y: 15, width: 26, height: 26)
        badge.frame = compact ? NSRect(x: bounds.width - badgeWidth - 8 - copyInset, y: 19, width: badgeWidth, height: 20)
            : NSRect(x: 7, y: 7, width: badgeWidth, height: 22)
        titleLabel.frame = compact ? NSRect(x: 50 + artworkInset, y: subtitleLabel.isHidden ? 19 : 10, width: max(0, bounds.width - 100 - copyInset - artworkInset), height: 20)
            : NSRect(x: 0, y: side + 8, width: bounds.width, height: 18)
        if !compact {
            let clipboardWidth: CGFloat = clipboardIcon.isHidden ? 0 : 18
            let measured = (titleLabel.stringValue as NSString).size(withAttributes: [.font: titleLabel.font ?? NSFont.systemFont(ofSize: 12)]).width + 16
            let textWidth = min(measured, max(0, bounds.width - clipboardWidth))
            let start = (bounds.width - textWidth - clipboardWidth) / 2
            clipboardIcon.frame = NSRect(x: start, y: side + 9, width: 13, height: 14)
            // 标题保留整行可用宽度，避免 NSTextField 的内部边距让短标题提前省略。
            titleLabel.frame = NSRect(x: clipboardWidth, y: side + 8,
                                      width: max(0, bounds.width - clipboardWidth), height: 18)
        }
        if isNotice {
            titleLabel.frame = NSRect(x: 10, y: 19, width: max(0, bounds.width - 20), height: 20)
        }
        subtitleLabel.frame = NSRect(x: 50 + artworkInset, y: 31, width: max(0, bounds.width - 65 - copyInset - artworkInset), height: 16)
        if terminalStyle {
            icon.frame = NSRect(x: 18, y: (bounds.height - 30) / 2, width: 30, height: 30)
            let titleX: CGFloat = typeIcon.isHidden ? 64 : 86
            typeIcon.frame = NSRect(x: 64, y: 17, width: 16, height: 16)
            titleLabel.frame = NSRect(x: titleX, y: subtitleLabel.isHidden ? 28 : 12,
                                      width: max(0, bounds.width - titleX - badgeWidth - 24), height: 25)
            let pinnedInset: CGFloat = pinned.isHidden ? 0 : 24
            subtitleLabel.frame = NSRect(x: 64, y: 45, width: max(0, bounds.width - 84 - pinnedInset), height: 19)
            pinned.frame = NSRect(x: bounds.width - 27, y: 46, width: 16, height: 16)
            badge.frame.origin.y = 16
        }
        CATransaction.commit()
        updateEmphasisTransform(animated: false)
    }
    private func updatePlayback(_ playing: Bool) {
        playback.isHidden = !playing
        for (index, bar) in (playback.sublayers ?? []).enumerated() {
            bar.removeAllAnimations()
            if playing {
                let animation = CABasicAnimation(keyPath: "transform.scale.y")
                animation.fromValue = 0.25
                animation.toValue = 1
                animation.duration = 0.3 + Double(index) * 0.11
                animation.autoreverses = true
                animation.repeatCount = .infinity
                bar.add(animation, forKey: "playing")
            }
        }
    }

    private static let musicIcon = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSGradient(starting: NSColor(red: 0.996, green: 0.235, blue: 0.286, alpha: 1),
                   ending: NSColor(red: 0.945, green: 0.059, blue: 0.188, alpha: 1))?.draw(in: path, angle: -90)
        let note = NSAttributedString(string: "♫", attributes: [.font: NSFont.systemFont(ofSize: 25, weight: .bold), .foregroundColor: NSColor.white])
        let size = note.size()
        note.draw(at: NSPoint(x: (40 - size.width) / 2, y: (40 - size.height) / 2))
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        guard action != nil else { return }
        hovered = true; updateAppearance()
    }
    override func mouseExited(with event: NSEvent) { hovered = false; updateAppearance() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let target = super.hitTest(point) else { return nil }
        return target === copyButton ? copyButton : self
    }
    @objc private func copyClipboardEntry() {
        if let entry = foil?.clipboardEntry { model?.clipboardSearch.copy(entry) }
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func accessibilityPerformPress() -> Bool {
        guard let action else { return false }; action(); return true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let foil else { return nil }
        if let index = model?.currentItems.firstIndex(where: { $0.id == foil.id }) {
            model?.selectedIndex = index
        }
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector, symbol: String, key: String = "", modifiers: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: NSLocalizedString(title, comment: ""), action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.withSymbol(symbol)
            item.target = self; menu.addItem(item)
        }
        let favorite = KeyboardShortcutStore.shared.shortcut(forID: "history.toggleFavorite")
        if foil.hasHistoryRecord {
            add(foil.historyIsPinned ? "Unfavorite History" : "Favorite History", #selector(toggleFavorite), symbol: foil.historyIsPinned ? "bookmark.slash" : "bookmark",
                key: foil.isHistoryEntry ? favorite?.keyEquivalent ?? "" : "", modifiers: foil.isHistoryEntry ? favorite?.modifiers ?? [] : [])
        }
        if foil.canRenameTitle { add("Change Title", #selector(rename), symbol: "pencil", key: foil.isHistoryEntry ? "e" : "", modifiers: .command) }
        if foil.canShowInformation { add("Foil Information Menu", #selector(showInformation), symbol: "info.circle", key: foil.isHistoryEntry ? "i" : "", modifiers: .command) }
        if foil.isHistoryEntry { add("Delete History Record", #selector(deleteHistory), symbol: "trash", key: "\u{8}", modifiers: .command) }
        return menu.items.isEmpty ? nil : menu
    }
    @objc private func toggleFavorite() { if let foil { model?.onTogglePinned(foil) } }
    @objc private func showInformation() { if let foil { model?.onShowInformation(foil) } }
    @objc private func rename() { if let foil { model?.onRenameItem(foil) } }
    @objc private func deleteHistory() { if let foil { model?.onClearHistoryItem(foil) } }
}
