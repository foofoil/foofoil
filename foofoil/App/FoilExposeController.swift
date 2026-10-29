//
//  FoilExposeController.swift
//  foofoil
//
//  Created by tolg on 2026/9/14.
//

import AppKit
import Carbon.HIToolbox
import Combine

/// 索引到数字/字母快捷键的纯函数映射：0-9 → 1-9、0，其后按 A-Z 顺序取字母。
/// 方向导航占用的 Control 键（⌃P/⌃N/⌃F/⌃B）和行首/行尾（⌃A/⌃E）不再分配给编号，
/// 因此共 10 + 20 = 30 项有可用键，31 项起只能点击选择。
enum FoilExposeShortcut {
    /// 已分配给总览导航的 Control 字母，编号跳过它们以免直选抢走导航键。
    static let reservedLetters: Set<String> = ["a", "b", "e", "f", "n", "p"]

    /// 可供编号的字母键：A-Z 中移除导航保留字母，保持原字母顺序。
    static let letters: [String] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        .filter { !reservedLetters.contains(String($0).lowercased()) }
        .map(String.init)

    static func key(forIndex index: Int) -> String? {
        guard index >= 0 else { return nil }
        if index < 10 { return String((index + 1) % 10) }
        let letterIndex = index - 10
        guard letters.indices.contains(letterIndex) else { return nil }
        return letters[letterIndex]
    }
}

/// 键盘高亮移动方向：左右逐项、上下按网格列数跨行；up/down 同时复用为整页滚动方向。
enum FoilExposeMoveDirection: Equatable {
    case up, down, left, right
}

/// 总览历史的内容分类；摄像头和未归类内容只出现在“全部”。
enum FoilExposeHistoryCategory: String, CaseIterable, Identifiable {
    case all, images, media, web, documents, notes, terminal

    var id: Self { self }
    var localizationKey: String { "Expose History Category " + rawValue }
    var symbolName: String {
        switch self {
        case .all: "square.grid.2x2"
        case .images: "photo"
        case .media: "play.rectangle"
        case .web: "globe"
        case .documents: "doc.text"
        case .notes: "note.text"
        case .terminal: "terminal"
        }
    }

    var clearHistoryTitle: String {
        let key = self == .all ? "Expose Clear All History" : "Expose Clear Category History Format"
        return self == .all ? NSLocalizedString(key, comment: "")
            : String(format: NSLocalizedString(key, comment: ""), NSLocalizedString(localizationKey, comment: ""))
    }

    func includes(_ kind: HistoryContentKind) -> Bool {
        switch self {
        case .all: true
        case .images: kind == .image
        case .media: kind == .audio || kind == .video
        case .web: kind == .web
        case .documents: [.text, .markdown, .csv, .pdf, .quickLook, .ebook].contains(kind)
        case .notes: kind == .note
        case .terminal: kind == .terminal
        }
    }
}

/// 覆盖层中一个箔片的快照：打开的箔片收集自 AppDelegate.windowControllers，展示信息取自历史配置。
/// controller 为 nil 表示占位卡（新建空白箔）或历史记录条目（isHistoryEntry）。
struct FoilExposeItem: Identifiable {
    /// 文档型卡片正文的截取上限：只作渲染兜底，实际可见行数由卡片布局决定。
    static let cameraCommandID = UUID(uuidString: "67A8D052-221D-4121-B733-0F66AE5B88DF")!
    static let bodyPreviewCharacterLimit = 600

    let id: UUID
    let controller: FloatingWindowController?
    let isHistoryEntry: Bool
    let title: String
    let symbolName: String
    let contentKind: HistoryContentKind
    let thumbnailPath: String?
    /// 历史配置记录的外部源文件路径；用于让 Spotlight 文件结果避开已展示的同一文件。
    var clipboardEntry: ClipboardSearchEntry? = nil
    var isClipboardContent: Bool = false
    var sourcePath: String? = nil
    /// 文档型箔片（笔记/文本/Markdown/CSV）的截断正文，供缩略图位置直接展示内容；其余类型为 nil。
    var bodyPreview: String? = nil
    var musicItem: AppleMusicLibraryItem? = nil
    var allowsTitleEditing: Bool = true
    var historyIsPinned: Bool = false
    var hasHistoryRecord: Bool = false

    var canRenameTitle: Bool {
        allowsTitleEditing && contentKind != .camera && !isNewFoil && musicItem == nil && clipboardEntry == nil
    }

    var requiresHistoryClearConfirmation: Bool { isHistoryEntry && historyIsPinned }

    var window: NSWindow? { controller?.window }
    var isNewFoil: Bool { controller == nil && !isHistoryEntry && musicItem == nil && clipboardEntry == nil && id != Self.cameraCommandID }

    /// 文档型条目的正文预览：跳过首尾空白后截取开头；空白正文与非文档类型返回 nil，卡片回退到类型图标。
    static func makeBodyPreview(kind: HistoryContentKind, text: String) -> String? {
        guard kind.storesIndexedText else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > bodyPreviewCharacterLimit else { return trimmed }
        return trimmed.prefix(bodyPreviewCharacterLimit) + "…"
    }

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
    let toast = FoilToastCenter()
    let clipboardSearch: ClipboardHistorySearch
    private var clipboardCancellable: AnyCancellable?
    private var clipboardIDs: [String: UUID] = [:]
    private var clipboardItems: [FoilExposeItem] = []
    /// 打开的箔片条目。
    @Published private(set) var items: [FoilExposeItem]
    /// 历史记录条目。
    @Published private(set) var historyItems: [FoilExposeItem]
    @Published var historyCategory: FoilExposeHistoryCategory = .all {
        didSet {
            guard oldValue != historyCategory else { return }
            // 分类切换后将高亮定位到新的历史分区首项。
            selectedIndex = currentItems.firstIndex(where: \.isHistoryEntry) ?? 0
        }
    }

    @Published var pinnedOnly = false {
        didSet {
            selectedIndex = currentItems.firstIndex(where: \.isHistoryEntry) ?? 0
        }
    }

    /// 展示时剪贴板里可打开的内容类型（与实际打开结果一致）；nil 表示没有可打开内容，不显示提示。
    let clipboardContent: ClipboardOpenableContent?
    /// 当前键盘高亮的条目下标（对应 currentItems）；默认高亮第一项。
    @Published var selectedIndex: Int = 0
    @Published var isOptionPressed = false
    /// 键盘移动高亮的请求序号：即使已到边界不移动，视图也据此把选中项完整滚入可见区域。
    @Published private(set) var selectionRevealRequest: UInt64 = 0

    @Published var activeScope: SearchScope? = nil {
        didSet {
            if oldValue != activeScope {
                resultFilter = activeScope?.filter ?? .all
                updateDirectAction()
            }
        }
    }

    /// 输入可直接打开的文件路径或网址；与范围选择共用下拉框，命中时默认高亮。
    @Published private(set) var directAction: DirectSearchAction?

    var isPickingScope: Bool {
        isSearching && activeScope == nil && directAction == nil && searchText.hasPrefix("/")
            && !DirectFilePathResolver.looksLikePath(searchText)
    }

    /// 下拉框可见：正在筛选范围，或已有可直接打开的输入。
    var isChoosingScope: Bool {
        isSearching && activeScope == nil && (isPickingScope || directAction != nil)
    }

    var scopeFilterText: String {
        guard isPickingScope else { return "" }
        return String(searchText.dropFirst())
    }

    var availableScopes: [SearchScope] {
        SearchScope.availableScopes(musicLibraryEnabled: SettingsStore.shared.appleMusicLibraryEnabled, fileSearchEnabled: LocalFileSearchSettings.shared.isEnabled, musicSearchEnabled: SettingsStore.shared.appleMusicSearchEnabled)
    }

    var filteredScopes: [SearchScope] {
        let filter = scopeFilterText
        return availableScopes.filter { $0.matches(filter: filter) }
    }

    @Published var highlightedScopeIndex: Int = 0

    func moveScopeSelection(by offset: Int) {
        guard directAction == nil, !filteredScopes.isEmpty else { return }
        let count = filteredScopes.count
        highlightedScopeIndex = ((highlightedScopeIndex + offset) % count + count) % count
    }

    func selectHighlightedScope() {
        if directAction != nil {
            openDirectAction()
            return
        }
        guard isPickingScope, !filteredScopes.isEmpty else { return }
        let index = min(max(highlightedScopeIndex, 0), filteredScopes.count - 1)
        selectScope(filteredScopes[index])
    }

    var onOpenCommand: ((SearchScope) -> Void)?
    /// 直接输入的网址：由控制器收起覆盖层并在空白箔中打开。
    var onOpenURL: (URL) -> Void = { _ in }

    func isScopeEnabled(_ scope: SearchScope) -> Bool { true }

    func scopeTitle(_ scope: SearchScope) -> String { scope.displayName }

    func selectScope(_ scope: SearchScope) {
        guard isScopeEnabled(scope) else { return }
        if scope.enableFeatureIfNeeded() {
            highlightedScopeIndex = 0
            objectWillChange.send()
            return
        }
        // 打开命令直接执行，不切换为搜索范围。
        if scope.isOpeningCommand {
            onOpenCommand?(scope)
            return
        }
        if scope == .history { historyCategory = .all; pinnedOnly = false }
        activeScope = scope
        searchText = ""
        highlightedScopeIndex = 0
        selectedIndex = 0
        requestSearchFieldFocus()
    }

    func openDirectAction() {
        guard let directAction else { return }
        switch directAction {
        case .file(let file): onOpenFile(file.url)
        case .url(let url): onOpenURL(url)
        }
    }

    func clearActiveScope() {
        activeScope = nil
        resultFilter = .all
        highlightedScopeIndex = 0
        selectedIndex = 0
        clipboardSearch.search(searchQuery)
        scheduleFileSearch()
        scheduleMusicSearch()
    }

    /// 搜索关键字；输入时即时过滤。
    @Published var searchText: String = "" {
        didSet {
            updateDirectAction()
            if isPickingScope {
                highlightedScopeIndex = 0
                if searchText.contains(" ") {
                    let parts = searchText.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                    let token = String(parts[0])
                    if let matched = availableScopes.first(where: { $0.matches(filter: token) }) {
                        selectScope(matched)
                        searchText = parts.count > 1 ? String(parts[1]) : ""
                        return
                    }
                }
            }
            guard !isPickingScope else { return }
            committedSearchQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if selectedIndex != 0 { selectedIndex = 0 }
            normalizeHistoryCategory()
            scheduleFileSearch()
            scheduleMusicSearch()
            if activeScope == nil || activeScope == .clipboard { clipboardSearch.search(committedSearchQuery) }
            else { clipboardSearch.stop() }
        }
    }
    /// 总览始终接收搜索输入，编号直选统一使用 Control 修饰键。
    let isSearching = true
    /// 搜索输入框聚焦请求序号：面板稍后成为 key window 或 FocusState 落空时，视图据此重新聚焦。
    @Published var searchFieldFocusRequest: UInt64 = 0
    /// 最新的整页滚动请求；面板视图认领执行。
    @Published var pageScrollRequest: FoilExposePageScrollRequest?
    /// Spotlight 文件结果：只在关键字非空时查询与呈现。
    @Published private(set) var files: [SpotlightFileResult] = []
    @Published private(set) var fileDisplayCount = SearchResultLimits.overviewGroupInitial
    @Published private(set) var isFileSearching = false
    @Published private(set) var fileStatus: FileSearchStatus?
    /// 打开文件失败等一次性说明；下一次搜索或重新开启文件搜索时清除。
    @Published var fileSearchNotice: String?
    @Published private(set) var musicItems: [FoilExposeItem] = []
    @Published private(set) var expandedMusicCategories: Set<AppleMusicSearchCategory> = []
    @Published private(set) var musicDisplayCounts: [AppleMusicSearchCategory: Int] = [:]
    @Published var resultFilter: SearchResultFilter = .all {
        didSet {
            if oldValue != resultFilter {
                selectedIndex = 0
                scheduleFileSearch()
                scheduleMusicSearch()
            }
        }
    }
    private var musicHasMoreCategories: Set<AppleMusicSearchCategory> = []
    @Published private(set) var isMusicSearching = false
    @Published private(set) var musicError: String?
    @Published private(set) var isMusicSearchEnabled = false
    @Published private(set) var isMusicAuthorized = false
    /// 网格实际列数，由原生网格按可用宽度计算，供上下移动跨行使用。
    var columnCount: Int = 4
    var musicColumnCount: Int = 3
    var onSelect: (FoilExposeItem) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    var onClearHistory: (FoilExposeHistoryCategory) -> Void = { _ in }
    var onClearHistoryItem: (FoilExposeItem) -> Void = { _ in }
    var onTogglePinned: (FoilExposeItem) -> Void = { _ in }
    var onRenameItem: (FoilExposeItem) -> Void = { _ in }
    var onShowInformation: (FoilExposeItem) -> Void = { _ in }
    /// 打开文件结果：由控制器检查可用性并在浮箔中打开。
    var onOpenFile: (URL) -> Void = { _ in }
    /// 开启文件搜索偏好，不弹出目录授权面板。
    var onEnableFileSearch: () -> Void = {}
    /// 点击剪贴板提示：由控制器关闭覆盖层并打开剪贴板内容（等价于 ⌘⇧V）。
    var onOpenClipboard: () -> Void = {}
    var onNewFoil: () -> Void = {}
    private let fileSearch: (String, SpotlightSearchTarget, @escaping (SpotlightSearchOutcome) -> Void) -> Void
    private let cameraAvailable: () -> Bool
    private let cancelFiles: () -> Void
    private var fileSearchTask: Task<Void, Never>?
    private var fileGeneration = 0
    private var rawFiles: [SpotlightFileResult] = []
    private let musicSearch: @MainActor (String, SearchResultFilter) async throws -> AppleMusicSearchPage
    private let musicAuthorized: @MainActor () -> Bool
    private let musicEnabled: @MainActor () -> Bool
    private var musicTask: Task<Void, Never>?
    private var musicGeneration = 0
    private var musicIDs: [String: UUID] = [:]
    private var musicSettingsCancellable: AnyCancellable?
    private var fileSettingsCancellable: AnyCancellable?
    private var isStopped = false

    init(items: [FoilExposeItem],
         historyItems: [FoilExposeItem],
         clipboardContent: ClipboardOpenableContent? = nil,
         fileSearch: ((String, @escaping (SpotlightSearchOutcome) -> Void) -> Void)? = nil,
         targetFileSearch: ((String, SpotlightSearchTarget, @escaping (SpotlightSearchOutcome) -> Void) -> Void)? = nil,
         cancelFiles: (() -> Void)? = nil,
         cameraAvailable: @escaping () -> Bool = { CameraCaptureController.isAvailable },
         musicSearch: (@MainActor (String) async throws -> [AppleMusicLibraryItem])? = nil,
         musicAuthorized: @escaping @MainActor () -> Bool = { AppleMusicLibrary.shared.isAuthorized },
         musicEnabled: @escaping @MainActor () -> Bool = { SettingsStore.shared.appleMusicSearchEnabled },
         clipboardSearch: ClipboardHistorySearch? = nil) {
        self.clipboardSearch = clipboardSearch ?? ClipboardHistorySearch()
        self.cameraAvailable = cameraAvailable
        self.musicSearch = { term, filter in
            if let musicSearch { return .init(items: try await musicSearch(term)) }
            return try await AppleMusicLibrary.shared.searchPage(term, filter: filter)
        }
        self.musicAuthorized = musicAuthorized
        self.musicEnabled = musicEnabled
        self.isMusicSearchEnabled = musicEnabled()
        self.isMusicAuthorized = musicAuthorized()
        self.items = items
        self.historyItems = historyItems
        self.clipboardContent = clipboardContent

        let service = SpotlightFileSearch()
        if let targetFileSearch {
            self.fileSearch = targetFileSearch
        } else if let fileSearch {
            self.fileSearch = { text, _, completion in fileSearch(text, completion) }
        } else {
            self.fileSearch = { text, target, completion in
                service.start(text: text, target: target, completion: completion)
            }
        }
        self.cancelFiles = cancelFiles ?? { service.cancel() }
        clipboardCancellable = self.clipboardSearch.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.clipboardItems = self.clipboardSearch.entries.map { entry in
                let id = self.clipboardIDs[entry.id] ?? UUID()
                self.clipboardIDs[entry.id] = id
                var item = FoilExposeItem(id: id, controller: nil, isHistoryEntry: false, title: entry.title,
                                          symbolName: entry.symbolName, contentKind: .note, thumbnailPath: nil)
                item.clipboardEntry = entry; item.isClipboardContent = true
                if case .text(let text) = entry.content { item.bodyPreview = FoilExposeItem.makeBodyPreview(kind: .note, text: text) }
                return item
            }
            self.selectedIndex = min(self.selectedIndex, max(0, self.displayedResultCount - 1))
            self.objectWillChange.send()
        }
        self.clipboardSearch.search("")
        fileSettingsCancellable = NotificationCenter.default.publisher(for: .localFileSearchDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isStopped else { return }
                self.objectWillChange.send()
                self.restartFileSearch()
            }
        musicSettingsCancellable = NotificationCenter.default.publisher(for: .appleMusicSearchDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isStopped else { return }
                self.objectWillChange.send()
                if !self.musicEnabled() && self.resultFilter.musicCategory != nil {
                    self.activeScope = nil
                    self.resultFilter = .all
                }
                self.scheduleMusicSearch()
            }
    }

    // 分类输入只过滤下拉选项，确认前保留此前的搜索内容和结果。
    private var committedSearchQuery = ""

    /// 有活动范围时下拉框只服务范围选择，不解析直接打开的输入。
    private func updateDirectAction() {
        let action = activeScope == nil ? DirectSearchAction.resolve(searchText) : nil
        guard action != directAction else { return }
        directAction = action
        if action != nil { highlightedScopeIndex = 0 }
    }

    /// 去掉首尾空白后的有效搜索关键字；空字符串表示不过滤。
    var searchQuery: String { committedSearchQuery }

    /// 打开的箔片在前、历史记录在后的完整列表；已在打开的箔片中出现的条目不再重复显示；
    /// 有关键字时只保留标题匹配项。
    private var unfilteredMatchedFoilItems: [FoilExposeItem] {
        let openIDs = Set(items.map(\.id))
        let combined = (items + historyItems.filter { !openIDs.contains($0.id) })
            .filter { SettingsStore.shared.appleMusicLibraryEnabled || $0.symbolName != AppleMusicReference.symbolName }
        if activeScope == .history { return combined.filter { $0.isHistoryEntry && (searchQuery.isEmpty || $0.matches(query: searchQuery)) } }
        guard activeScope == nil else { return [] }
        guard !searchQuery.isEmpty else { return combined }
        guard resultFilter == .all || resultFilter == .history else { return [] }
        let command = (resultFilter == .all && CameraCaptureController.matches(searchQuery, available: cameraAvailable())) ? [FoilExposeItem(id: FoilExposeItem.cameraCommandID, controller: nil, isHistoryEntry: false, title: NSLocalizedString("Open Camera", comment: ""), symbolName: "web.camera.fill", contentKind: .camera, thumbnailPath: nil)] : []
        let query = searchQuery
        return command + combined.filter { $0.matches(query: query) }
    }
    /// 分类数量在展示截断之前统计，并与历史分区的去重、设置和关键词规则保持一致。
    func historyCount(in category: FoilExposeHistoryCategory) -> Int {
        unfilteredMatchedFoilItems.filter { $0.isHistoryEntry && category.includes($0.contentKind) && (!pinnedOnly || $0.historyIsPinned) }.count
    }

    var visibleHistoryCategories: [FoilExposeHistoryCategory] {
        FoilExposeHistoryCategory.allCases.filter { historyCount(in: $0) > 0 }
    }

    private func normalizeHistoryCategory() {
        if historyCount(in: historyCategory) == 0 { historyCategory = .all }
    }

    func replaceHistoryItems(_ items: [FoilExposeItem], deleting deletedID: UUID? = nil) {
        let deletedPosition = deletedID.flatMap { id in currentItems.firstIndex { $0.id == id } }
            .flatMap { index in navigationRows.flatMap { $0 }.firstIndex(of: index) }
        historyItems = items
        normalizeHistoryCategory()
        if let deletedPosition {
            // 删除后沿显示顺序选中后一项；末项回退到前一项，删空时保留安全的空选择。
            let indices = navigationRows.flatMap { $0 }
            selectedIndex = indices.isEmpty ? 0 : indices[min(deletedPosition, indices.count - 1)]
        } else {
            selectedIndex = currentItems.firstIndex(where: \.isHistoryEntry) ?? 0
        }
    }

    /// 改名后重建搜索结果，优先保留当前选择；标题不再匹配搜索时限制到有效下标。
    func refreshItems(open: [FoilExposeItem], history: [FoilExposeItem]) {
        let selectedID = currentItems.indices.contains(selectedIndex) ? currentItems[selectedIndex].id : nil
        items = open
        historyItems = history
        normalizeHistoryCategory()
        selectedIndex = selectedID.flatMap { id in currentItems.firstIndex { $0.id == id } }
            ?? min(selectedIndex, max(0, currentItems.count - 1))
    }

    /// 清除按完整分类处理，不受搜索词、设置隐藏或总览加载上限影响；活跃箔片保留。
    static func historyToClear(_ configs: [WindowConfig], category: FoilExposeHistoryCategory,
                               openIDs: Set<UUID>) -> [WindowConfig] {
        configs.filter { !$0.historyIsPinned && !openIDs.contains($0.id) && category.includes($0.contentKind ?? HistoryContentKind.infer(from: $0)) }
    }

    var showsHistorySection: Bool {
        activeScope == nil || activeScope == .history
    }

    private var matchedFoilItems: [FoilExposeItem] {
        // 历史分类与收藏筛选只作用于历史记录，已打开箔片不受影响。
        unfilteredMatchedFoilItems.filter {
            !$0.isHistoryEntry || (historyCategory.includes($0.contentKind) && (!pinnedOnly || $0.historyIsPinned))
        }
    }

    /// 总览搜索中文件与各音乐分组各自独立展示，没有跨来源的总数上限；只有已打开与历史条目列表封顶 maximum。
    var showsClipboardSection: Bool { activeScope == nil || activeScope == .clipboard }
    var canShowMoreHistory: Bool {
        activeScope == nil && searchQuery.isEmpty && matchedFoilItems.filter(\.isHistoryEntry).count > max(1, columnCount) * 2
    }
    private static let overviewClipboardLimit = 12
    var canShowMoreClipboard: Bool {
        activeScope == nil && clipboardItems.count > Self.overviewClipboardLimit
    }
    var clipboardCount: Int { clipboardItems.count }
    var currentItems: [FoilExposeItem] {
        if activeScope == .clipboard { return clipboardItems }
        var foils = matchedFoilItems
        if activeScope == nil && searchQuery.isEmpty {
            let open = foils.filter { !$0.isHistoryEntry }
            let history = foils.filter(\.isHistoryEntry).prefix(max(1, columnCount) * 2)
            foils = open + history
        } else if activeScope != .history {
            foils = Array(foils.prefix(SearchResultLimits.maximum))
        }
        let clipboard = activeScope == nil ? Array(clipboardItems.prefix(Self.overviewClipboardLimit)) : []
        return foils + clipboard + visibleMusicItems
    }
    private var effectiveFileDisplayCount: Int {
        resultFilter == .files || resultFilter == .folders ? SearchResultLimits.maximum : fileDisplayCount
    }
    var visibleFiles: [SpotlightFileResult] { Array(files.prefix(effectiveFileDisplayCount)) }
    var displayedResultCount: Int { currentItems.count + visibleFiles.count }
    var showsResultLimitNotice: Bool {
        if activeScope == .clipboard || activeScope == .history || searchQuery.isEmpty { return false }
        let foilsTruncated = matchedFoilItems.count > SearchResultLimits.maximum
        let hasExtra = visibleFiles.count < files.count
            || AppleMusicSearchCategory.allCases.contains { resultFilter.includes($0) && (musicDisplayCount(in: $0) < musicItems(in: $0).count || musicHasMoreCategories.contains($0)) }
        let canExpandAny = canExpandFileResults || AppleMusicSearchCategory.allCases.contains { canExpandMusicResults(in: $0) }
        return foilsTruncated || (hasExtra && !canExpandAny)
    }

    /// 高亮条目：越界时回退到第一项。
    var highlightedItem: FoilExposeItem? {
        let items = currentItems
        return items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    /// 文件索引接在箔片后，导航顺序仍按界面的分区排列。
    var fileSelectionIndices: [Int] {
        guard showsFileResults else { return [] }
        return visibleFiles.indices.map { currentItems.count + $0 }
    }

    func openHighlightedResult() {
        let fileIndex = selectedIndex - currentItems.count
        if showsFileResults, visibleFiles.indices.contains(fileIndex) {
            onOpenFile(visibleFiles[fileIndex].url)
        } else if let item = highlightedItem {
            onSelect(item)
        }
    }

    /// 保留关键字并重新聚焦搜索框。
    func beginSearch() {
        requestSearchFieldFocus()
    }

    /// 请求视图把第一响应者交给搜索输入框；面板刚成为 key window 时补一次聚焦。
    func requestSearchFieldFocus() {
        searchFieldFocusRequest &+= 1
    }

    /// 清除关键字并恢复完整列表，继续聚焦搜索框。
    func clearSearch() {
        searchText = ""
        activeScope = nil
        resultFilter = .all
        clipboardSearch.search("")
        requestSearchFieldFocus()
        selectedIndex = 0
    }

    /// 关键字非空时才呈现 Spotlight 文件结果区；空关键字不展示、不查询。
    var showsFileResults: Bool { activeScope != .clipboard && !searchQuery.isEmpty && resultFilter.includesFiles }
    var showsMusicResults: Bool { activeScope != .clipboard && !searchQuery.isEmpty && isMusicSearchEnabled && (resultFilter == .all || resultFilter.musicCategory != nil) }
    func musicItems(in category: AppleMusicSearchCategory) -> [FoilExposeItem] {
        musicItems.filter { $0.musicItem?.searchCategory == category }
    }
    var visibleMusicItems: [FoilExposeItem] {
        AppleMusicSearchCategory.allCases
            .filter { resultFilter.includes($0) }
            .flatMap { category in
                Array(musicItems(in: category).prefix(musicDisplayCount(in: category)))
            }
    }
    func musicDisplayCount(in category: AppleMusicSearchCategory) -> Int {
        resultFilter.musicCategory == category ? SearchResultLimits.maximum
            : musicDisplayCounts[category, default: SearchResultLimits.overviewGroupInitial]
    }
    func canExpandMusicResults(in category: AppleMusicSearchCategory) -> Bool {
        musicDisplayCount(in: category) < SearchResultLimits.maximum && musicDisplayCount(in: category) < musicItems(in: category).count
    }
    func expandMusicResults(in category: AppleMusicSearchCategory) {
        guard canExpandMusicResults(in: category) else { return }
        // 专辑组展开会把后面的歌曲向下推；按身份保留键盘高亮，避免误打开其它曲目。
        let selectedID = highlightedItem?.id
        expandedMusicCategories.insert(category)
        musicDisplayCounts[category] = min(SearchResultLimits.maximum, musicDisplayCount(in: category) + SearchResultLimits.increment)
        if let selectedID, let index = currentItems.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        }
    }

    /// 音乐结果加入同一键盘导航网格；独立取消与代际校验，防止旧查询覆盖新输入。
    private func scheduleMusicSearch() {
        guard !isPickingScope else { return }
        let selectedID = highlightedItem?.id
        musicTask?.cancel()
        musicGeneration += 1
        let generation = musicGeneration
        musicItems = []
        expandedMusicCategories = []; musicDisplayCounts = [:]; musicHasMoreCategories = []
        musicError = nil
        isMusicSearching = false
        isMusicSearchEnabled = musicEnabled()
        isMusicAuthorized = musicAuthorized()
        if let selectedID, let index = currentItems.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        } else {
            selectedIndex = min(selectedIndex, max(0, currentItems.count - 1))
        }
        let query = searchQuery
        guard activeScope != .clipboard, !isStopped, !isPickingScope, (resultFilter == .all || resultFilter.musicCategory != nil), !query.isEmpty, isMusicSearchEnabled, isMusicAuthorized else { return }
        isMusicSearching = true
        musicTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                let page = try await self.musicSearch(query, self.resultFilter)
                guard !Task.isCancelled, generation == self.musicGeneration else { return }
                self.musicHasMoreCategories = page.hasMoreCategories
                let results = AppleMusicSearchCategory.allCases.filter { self.resultFilter.includes($0) }.flatMap { category in
                    page.items.lazy.filter { $0.searchCategory == category }.prefix(SearchResultLimits.probe)
                }
                let incomingIDs = Set(results.map(\.id))
                self.musicIDs = self.musicIDs.filter { incomingIDs.contains($0.key) }
                self.musicItems = results.map { item in
                    let id = self.musicIDs[item.id] ?? UUID()
                    self.musicIDs[item.id] = id
                    return FoilExposeItem(id: id, controller: nil, isHistoryEntry: false,
                                          title: item.title, symbolName: AppleMusicReference.symbolName, contentKind: .audio,
                                          thumbnailPath: nil, musicItem: item)
                }
                self.isMusicSearching = false
            } catch {
                guard let self, !Task.isCancelled, generation == self.musicGeneration else { return }
                self.musicError = error.localizedDescription
                self.isMusicSearching = false
            }
        }
    }

    /// 关键字变化后防抖查询 Spotlight；空关键字立即清空并取消，避免结果与输入不一致。
    private func scheduleFileSearch() {
        guard !isPickingScope else { return }
        fileSearchTask?.cancel()
        fileSearchTask = nil
        fileGeneration += 1
        let generation = fileGeneration
        fileSearchNotice = nil
        fileDisplayCount = SearchResultLimits.overviewGroupInitial
        let query = searchQuery
        guard activeScope != .clipboard, !isPickingScope, !query.isEmpty && resultFilter.includesFiles else {
            cancelFiles()
            rawFiles = []
            files = []
            fileStatus = nil
            isFileSearching = false
            return
        }
        rawFiles = []
        files = []
        fileStatus = nil
        isFileSearching = true
        let target = resultFilter.target
        fileSearchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !Task.isCancelled, generation == self.fileGeneration else { return }
            self.fileSearch(query, target) { [weak self] outcome in
                guard let self, generation == self.fileGeneration else { return }
                switch outcome {
                case .progress(let files):
                    self.rawFiles = Array(files.prefix(SearchResultLimits.probe))
                    self.mergeFiles()
                    return
                case .results(let files): self.rawFiles = Array(files.prefix(SearchResultLimits.probe))
                case .disabled: self.fileStatus = .disabled
                case .unavailable: self.fileStatus = .unavailable
                case .timedOut: self.fileStatus = .timedOut
                }
                self.isFileSearching = false
                self.mergeFiles()
            }
        }
    }

    var canExpandFileResults: Bool { effectiveFileDisplayCount < SearchResultLimits.maximum && effectiveFileDisplayCount < files.count }
    func expandFileResults() {
        guard canExpandFileResults else { return }
        fileDisplayCount = min(SearchResultLimits.maximum, fileDisplayCount + SearchResultLimits.increment)
    }

    /// 重试或重新授权后按当前关键字重新查询。
    func restartFileSearch() {
        scheduleFileSearch()
    }

    /// 覆盖层关闭时停止查询并释放主目录访问。
    func stopFileSearch() {
        clipboardSearch.stop()
        isStopped = true
        musicTask?.cancel()
        musicTask = nil
        musicGeneration += 1
        isMusicSearching = false
        fileSearchTask?.cancel()
        fileSearchTask = nil
        fileGeneration += 1
        cancelFiles()
        isFileSearching = false
    }

    /// 文件结果按相关度排序，并排除已在箔片/历史条目中展示的同一源文件。
    private func mergeFiles() {
        let excluded = Set(unfilteredMatchedFoilItems.compactMap(\.sourcePath).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        files = SpotlightFileResult.ranked(rawFiles, query: searchQuery, excluding: excluded, limit: SearchResultLimits.probe)
    }

    /// 开启文件搜索并重新查询。
    func enableFileSearch() {
        onEnableFileSearch()
    }

    /// 移动键盘高亮，左右逐项、上下跨一行，越界时夹紧。
    /// Tab 在已打开与历史分区间切换；目标分区为空时保留当前高亮。
    func switchFoilSection() {
        let items = currentItems
        let isInHistory = highlightedItem?.isHistoryEntry == true
        if let target = items.firstIndex(where: {
            $0.musicItem == nil && $0.isHistoryEntry != isInHistory
        }) {
            selectedIndex = target
        }
    }

    func moveSelection(_ direction: FoilExposeMoveDirection) {
        // 边界处高亮不移动也要请求一次完整可见，顶部/底部被裁的选中卡片才能滚回视口。
        selectionRevealRequest &+= 1
        guard !navigationRows.isEmpty else { return }
        if direction == .up || direction == .down {
            let rows = navigationRows
            guard let row = rows.firstIndex(where: { $0.contains(selectedIndex) }),
                  let column = rows[row].firstIndex(of: selectedIndex) else { return }
            let targetRow = row + (direction == .up ? -1 : 1)
            guard rows.indices.contains(targetRow) else { return }
            selectedIndex = rows[targetRow][min(column, rows[targetRow].count - 1)]
            return
        }
        let indices = navigationRows.flatMap { $0 }
        guard let position = indices.firstIndex(of: selectedIndex) else {
            selectedIndex = indices[0]
            return
        }
        let delta = direction == .left ? -1 : 1
        selectedIndex = indices[min(max(0, position + delta), indices.count - 1)]
    }

    /// 顶部一行的任意列都应连同最顶端标题一起显示。
    var isSelectionInFirstRow: Bool {
        navigationRows.first?.contains(selectedIndex) == true
    }

    /// 分区各自从左起排满一行；不使用受滚动和高亮动画影响的卡片坐标。
    private var navigationRows: [[Int]] {
        let items = currentItems
        let groups: [([Int], Int)] = [
            (items.indices.filter { !items[$0].isHistoryEntry && items[$0].musicItem == nil }, activeScope == .clipboard ? musicColumnCount : columnCount),
            (items.indices.filter { items[$0].isHistoryEntry }, columnCount)
        ] + [(fileSelectionIndices, musicColumnCount)] + AppleMusicSearchCategory.allCases.map { category in
            (items.indices.filter { items[$0].musicItem?.searchCategory == category }, musicColumnCount)
        }
        return groups.flatMap { indices, columns in
            let width = max(1, columns)
            return stride(from: 0, to: indices.count, by: width).map {
                Array(indices[$0..<min($0 + width, indices.count)])
            }
        }
    }

    /// 行首、行尾沿用分区布局，文件卡片使用紧凑网格的列数。
    func moveSelectionToRowStart() {
        selectionRevealRequest &+= 1
        if let row = navigationRows.first(where: { $0.contains(selectedIndex) }), let first = row.first {
            selectedIndex = first
        }
    }

    func moveSelectionToRowEnd() {
        selectionRevealRequest &+= 1
        if let row = navigationRows.first(where: { $0.contains(selectedIndex) }), let last = row.last {
            selectedIndex = last
        }
    }

    /// 编号按当前列表从头分配，滚动和高亮变化不影响编号；屏外条目也可直选。
    func item(forKey key: String) -> FoilExposeItem? {
        let upper = key.uppercased()
        return currentItems.enumerated().first {
            FoilExposeShortcut.key(forIndex: $0.offset) == upper
        }?.element
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
/// 打开的箔片展示各窗口的历史缩略图，文档型箔片以截断正文当缩略图；历史记录展示全部历史配置，选中即恢复为新箔片。
/// 搜索框始终聚焦，数字/字母直选统一使用 ⌃ 修饰。
/// 只复用历史缩略图，不抓新截图；不使用屏幕录制、辅助功能、输入监控或私有 API。
@MainActor
final class FoilExposeController {
    static let shared = FoilExposeController()

    private var panels: [FoilExposePanel] = []
    var model: FoilExposeModel?
    private var keyMonitor: Any?
    private var showAllHotKeyRef: EventHotKeyRef?
    private var clipboardHotKeyRef: EventHotKeyRef?
    private var incognitoClipboardHotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    /// 系统面板（文件选择、授权）展示期间：覆盖层让出焦点，键盘监听放行，避免误操作覆盖层。
    private var isPresentingSystemUI = false
    private var isOpeningFile = false

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
            selector: #selector(handleWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
    }

    var isShowing: Bool { model != nil }

    /// 启动入口：安装事件处理器并按当前配置注册总览与剪贴板全局热键。
    /// 经 Carbon RegisterEventHotKey，浮箔未激活时也能唤起覆盖层；不需要输入监控或辅助功能权限。
    func installGlobalHotKey() {
        installEventHandlerIfNeeded()
        applyConfiguredGlobalHotKey()
    }

    /// 快捷键配置变更后重新注册全局热键。
    /// 仅注册带修饰键且能映射为 Carbon 键码的组合。
    func applyConfiguredGlobalHotKey() {
        installEventHandlerIfNeeded()
        if let showAllHotKeyRef {
            _ = UnregisterEventHotKey(showAllHotKeyRef)
            self.showAllHotKeyRef = nil
        }
        if let clipboardHotKeyRef {
            _ = UnregisterEventHotKey(clipboardHotKeyRef)
            self.clipboardHotKeyRef = nil
        }
        if let incognitoClipboardHotKeyRef {
            _ = UnregisterEventHotKey(incognitoClipboardHotKeyRef)
            self.incognitoClipboardHotKeyRef = nil
        }
        incognitoClipboardHotKeyRef = registerGlobalHotKey(definitionID: "global.openClipboardIncognito", id: 3)
        clipboardHotKeyRef = registerGlobalHotKey(definitionID: "global.openClipboardContent", id: 2)
        showAllHotKeyRef = registerGlobalHotKey(definitionID: "window.showAllFoils", id: 1)
    }

    private func registerGlobalHotKey(definitionID: String, id: UInt32) -> EventHotKeyRef? {
        guard let definition = KeyboardShortcutCatalog.definition(withID: definitionID),
              let shortcut = KeyboardShortcutStore.shared.shortcut(for: definition) else { return nil }
        guard shortcut.hasRequiredModifiers,
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
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                guard let event,
                      GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID) == noErr,
                      hotKeyID.signature == OSType(0x464F_494C) else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    if hotKeyID.id == 2 {
                        FoilExposeController.shared.openClipboard()
                    } else if hotKeyID.id == 3 {
                        FoilExposeController.shared.openClipboard(isIncognito: true)
                    } else if hotKeyID.id == 1 {
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
            historyItems: Self.collectHistoryItems(),
            clipboardContent: appDelegate.clipboardOpenableContent()
        )
        model.onOpenCommand = { [weak self, weak model] scope in
            if scope == .clipboard {
                self?.openClipboard(isIncognito: model?.isOptionPressed == true)
                return
            }
            self?.dismiss()
            NSApp.activate(ignoringOtherApps: true)
            let delegate = NSApp.delegate as? AppDelegate
            if scope == .url { delegate?.openWebURLAction() }
            else if scope == .terminal { delegate?.openTerminal(isIncognito: false) }
            else if scope == .camera { delegate?.openCameraAction() }
        }
        model.onSelect = { [weak self, weak model] item in
            if let entry = item.clipboardEntry {
                if (NSApp.delegate as? AppDelegate)?.openClipboardSearchEntry(entry, isIncognito: model?.isOptionPressed == true) == true { self?.dismiss() }
                else { model?.fileSearchNotice = NSLocalizedString("Clipboard History Open Failed", comment: "") }
            } else { self?.select(item) }
        }
        model.onDismiss = { [weak self] in self?.dismiss() }
        model.onOpenFile = { [weak self] url in self?.openFile(url) }
        model.onOpenURL = { [weak self] url in self?.openWebURL(url) }
        model.onEnableFileSearch = { [weak self] in self?.enableFileSearch() }
        model.onNewFoil = { [weak self, weak model] in
            let isIncognito = model?.isOptionPressed == true
            self?.dismiss()
            guard let delegate = NSApp.delegate as? AppDelegate else { return }
            if isIncognito { delegate.newIncognitoWindowAction() }
            else { delegate.newWindowAction() }
        }
        model.onOpenClipboard = { [weak self, weak model] in self?.openClipboard(isIncognito: model?.isOptionPressed == true) }
        model.onClearHistory = { [weak self] category in self?.confirmClearHistory(category) }
        model.onClearHistoryItem = { [weak self] item in self?.clearHistoryItem(item) }
        model.onTogglePinned = { [weak self] item in
            guard let self, let model = self.model else { return }
            guard let config = HistoryRepository.shared.config(id: item.id) else {
                model.toast.showFavoriteResult(pinned: true, succeeded: false)
                return
            }
            HistoryManager.shared.setFavorite(id: item.id, pinned: !config.historyIsPinned, toast: model.toast)
            let controllers = (NSApp.delegate as? AppDelegate)?.windowControllers ?? []
            model.refreshItems(open: Self.collectItems(from: controllers), history: Self.collectHistoryItems())
        }
        model.onRenameItem = { [weak self] item in self?.renameItem(item) }
        model.onShowInformation = { [weak self] item in
            guard let self, let panel = self.panels.first,
                  let delegate = NSApp.delegate as? AppDelegate,
                  let config = item.controller?.appState.toConfig() ?? HistoryRepository.shared.config(id: item.id) else { return }
            delegate.showFoilInformation(config: config, state: item.controller?.appState, window: panel, foilWindow: item.controller?.window)
        }
        self.model = model

        // 先准备总览，再激活应用，避免激活期间恢复其他显示器上的箔片焦点。
        if let screen = Self.activeScreen() {
            let panel = Self.makePanel(for: screen, model: model)
            panel.orderFront(nil)
            panels.append(panel)
        }
        NSApp.activate(ignoringOtherApps: true)
        focusPanel()
        schedulePanelFocus()

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
        guard isShowing, !isPresentingSystemUI, !panels.contains(where: { $0.attachedSheet != nil }) else { return }
        focusPanel()
    }

    /// 激活和跨屏窗口排序可能在下一轮主循环恢复箔片焦点；总览仍显示时再交回面板。
    private func schedulePanelFocus() {
        guard let panel = panels.first else { return }
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.panels.first === panel,
                  NSApp.isActive, !self.isPresentingSystemUI,
                  !self.panels.contains(where: { $0.attachedSheet != nil }) else { return }
            self.focusPanel()
        }
    }

    @objc private func handleWindowDidBecomeKey(_ notification: Notification) {
        guard isShowing, notification.object is FloatingWindow else { return }
        schedulePanelFocus()
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
            // 与 HistoryCardView 的缩略图兜底一致：网页整页截图、PDF 与图片原文件都在 imagePath；
            // 音视频原文件不是图片，摄像头箔的 imagePath 只是保存的截图，均不回退。
            var thumbnailPath = contentKind == .archive ? nil : config.thumbnailPath
            if thumbnailPath == nil, contentKind != .audio, contentKind != .video, contentKind != .camera, contentKind != .archive {
                thumbnailPath = config.imagePath
            }
            // 文档型箔片没有缩略图文件，用窗口里的实时正文生成截断预览。
            let bodyPreview = FoilExposeItem.makeBodyPreview(
                kind: contentKind,
                text: controller.appState.text
            )

            let historyConfig = controller.appState.isIncognito ? nil : HistoryRepository.shared.config(id: config.id)
            return FoilExposeItem(
                id: controller.appState.id,
                controller: controller,
                isHistoryEntry: false,
                title: title,
                symbolName: config.historyMenuSymbolName,
                contentKind: contentKind,
                thumbnailPath: thumbnailPath,
                isClipboardContent: config.isClipboardContent,
                sourcePath: Self.sourcePath(from: config),
                bodyPreview: bodyPreview,
                allowsTitleEditing: controller.appState.toConfig().canRenameTitle,
                historyIsPinned: historyConfig?.historyIsPinned ?? false,
                hasHistoryRecord: historyConfig != nil
            )
        }
    }

    /// 历史记录条目：最近的历史配置，附在打开的箔片之后，点击/回车恢复为新箔片窗口。
    private static func collectHistoryItems() -> [FoilExposeItem] {
        HistoryManager.shared.checkFileReferences()
        return HistoryRepository.shared.recent(limit: 500, includingPinned: true).map { config in
            let contentKind = config.contentKind ?? HistoryContentKind.infer(from: config)
            // 与 HistoryCardView 的缩略图兜底一致：网页整页截图、PDF 与图片原文件都在 imagePath；
            // 音视频原文件不是图片，摄像头箔的 imagePath 只是保存的截图，均不回退。
            var thumbnailPath = contentKind == .archive ? nil : config.thumbnailPath
            if thumbnailPath == nil, contentKind != .audio, contentKind != .video, contentKind != .camera, contentKind != .archive {
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
                thumbnailPath: thumbnailPath,
                isClipboardContent: config.isClipboardContent,
                sourcePath: Self.sourcePath(from: config),
                bodyPreview: FoilExposeItem.makeBodyPreview(kind: contentKind, text: config.text),
                allowsTitleEditing: config.canRenameTitle,
                historyIsPinned: config.historyIsPinned,
                hasHistoryRecord: true
            )
        }
    }

    /// 历史配置记录的外部源文件路径（file: 前缀的指纹），用于文件结果的跨来源去重。
    private static func sourcePath(from config: WindowConfig) -> String? {
        guard let fingerprint = config.sourceFingerprint, fingerprint.hasPrefix("file:") else { return nil }
        return String(fingerprint.dropFirst(5))
    }

    static func makePanel(for screen: NSScreen, model: FoilExposeModel) -> FoilExposePanel {
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
        let controller = FoilExposeViewController(model: model)
        // 在交给面板前确定屏幕内容尺寸，避免原生控制器初始为零尺寸。
        controller.view.frame = NSRect(origin: .zero, size: screen.frame.size)
        panel.contentViewController = controller
        return panel
    }

    /// 选择箔片：覆盖层先退场，再把目标窗口调度到最前；占位卡新建空白箔，历史条目恢复历史内容。
    private func select(_ item: FoilExposeItem) {
        if let music = item.musicItem {
            dismiss()
            NSApp.activate(ignoringOtherApps: true)
            (NSApp.delegate as? AppDelegate)?.openAppleMusic(music)
            return
        }
        guard let controller = item.controller, let window = item.window else {
            dismiss()
            NSApp.activate(ignoringOtherApps: true)
            let appDelegate = NSApplication.shared.delegate as? AppDelegate
            if item.id == FoilExposeItem.cameraCommandID {
                appDelegate?.openCameraAction()
            } else if item.isHistoryEntry {
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

    /// 打开 Spotlight 文件结果：先检查可读性；
    /// 文件不可读时留在覆盖层内说明原因，不关闭覆盖层。
    private func openFile(_ url: URL) {
        guard !isOpeningFile, let model else { return }
        isOpeningFile = true
        Task { [weak self] in
            guard let self else { return }
            let result = await SpotlightFileOpener.fileAccess(url)
            guard self.model === model else {
                self.isOpeningFile = false
                return
            }
            switch result {
            case .readable:
                if SpotlightFileOpener.openInFoil(url) {
                    self.dismiss()
                } else {
                    model.fileSearchNotice = NSLocalizedString("Search File Open Failed", comment: "")
                }
            case .notDownloaded:
                model.fileSearchNotice = NSLocalizedString("Search File Not Downloaded", comment: "")
            case .needsPermission, .unavailable:
                model.fileSearchNotice = NSLocalizedString("Search File Open Failed", comment: "")
            }
            self.isOpeningFile = false
        }
    }

    /// 直接输入的网址沿用空白箔打开流程，先收起覆盖层再打开。
    private func openWebURL(_ url: URL) {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        (NSApplication.shared.delegate as? AppDelegate)?.openWebURLInPreferredWindow(url)
    }

    /// 剪贴板提示与快捷键共用入口：先收起覆盖层，再打开剪贴板内容。
    private func openClipboard(isIncognito: Bool = false) {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
        (NSApplication.shared.delegate as? AppDelegate)?.openClipboardContentInNewWindow(isIncognito: isIncognito)
    }

    /// 系统对话框附着在总览上，保持背景可见并让键盘由 sheet 接管。
    static func presentAlert(_ alert: NSAlert, on panel: NSWindow) async -> NSApplication.ModalResponse {
        guard panel.isVisible, panel.attachedSheet == nil else { return .cancel }
        alert.window.level = panel.level
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: panel) { response in
                continuation.resume(returning: response)
            }
        }
    }

    private func renameItem(_ item: FoilExposeItem) {
        guard item.canRenameTitle, !isPresentingSystemUI,
              let model, let panel = panels.first, panel.attachedSheet == nil else { return }
        isPresentingSystemUI = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isPresentingSystemUI = false
                if self.model === model, self.panels.first === panel {
                    panel.makeKeyAndOrderFront(nil)
                    model.requestSearchFieldFocus()
                }
            }
            let config = item.controller?.appState.toConfig() ?? HistoryRepository.shared.config(id: item.id)
            guard let config, config.canRenameTitle else { return }
            let alert = FoilTitleEditing.makeAlert(title: FoilTitleEditing.editableTitle(for: config))
            guard await Self.presentAlert(alert, on: panel) == .alertFirstButtonReturn,
                  self.model === model, let field = alert.accessoryView as? NSTextField else { return }
            HistoryManager.shared.updateHistoryTitle(configId: item.id, newTitle: field.stringValue)
            let controllers = (NSApp.delegate as? AppDelegate)?.windowControllers ?? []
            model.refreshItems(open: Self.collectItems(from: controllers), history: Self.collectHistoryItems())
        }
    }

    /// 已钉住记录的显式删除需确认，普通记录直接清除。
    private func clearHistoryItem(_ item: FoilExposeItem) {
        guard item.isHistoryEntry, !isPresentingSystemUI,
              let model, let panel = panels.first, panel.attachedSheet == nil else { return }
        isPresentingSystemUI = true
        let historyID = item.id
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isPresentingSystemUI = false
                if self.model === model, self.panels.first === panel {
                    panel.makeKeyAndOrderFront(nil)
                    if model.isSearching { model.requestSearchFieldFocus() }
                }
            }
            guard let config = await Task.detached(priority: .userInitiated, operation: {
                HistoryRepository.shared.config(id: historyID)
            }).value, self.model === model else { return }
            // 历史卡片菜单打开期间该条目可能已恢复成活跃箔片，避免清除其恢复数据。
            guard (NSApp.delegate as? AppDelegate)?.windowControllers.contains(where: { $0.appState.id == item.id }) != true else { return }
            if config.historyIsPinned {
                guard await Self.presentAlert(HistoryManager.pinnedDeletionAlert(), on: panel) == .alertSecondButtonReturn,
                      self.model === model else { return }
            }
            if await HistoryManager.shared.removeFromHistory([config]) {
                model.replaceHistoryItems(Self.collectHistoryItems(), deleting: historyID)
            } else {
                let error = NSAlert()
                error.messageText = NSLocalizedString("Expose Clear History Failed", comment: "")
                _ = await Self.presentAlert(error, on: panel)
            }
        }
    }

    /// 批量清除确认与失败提示都附着在总览上，结束后恢复搜索焦点。
    private func confirmClearHistory(_ category: FoilExposeHistoryCategory) {
        guard !isPresentingSystemUI, let model, let panel = panels.first, panel.attachedSheet == nil else { return }
        isPresentingSystemUI = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isPresentingSystemUI = false
                if self.model === model, self.panels.first === panel {
                    NSApp.activate(ignoringOtherApps: true)
                    panel.makeKeyAndOrderFront(nil)
                    if model.isSearching { model.requestSearchFieldFocus() }
                }
            }
            let configs = await Task.detached(priority: .userInitiated) {
                HistoryRepository.shared.recent(limit: Int.max)
            }.value
            let openIDs = Set((NSApp.delegate as? AppDelegate)?.windowControllers.map { $0.appState.id } ?? [])
            let targets = FoilExposeModel.historyToClear(configs, category: category, openIDs: openIDs)
            guard self.model === model else { return }
            let title = category.clearHistoryTitle
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = String(format: NSLocalizedString("Expose Clear History Confirmation Format", comment: ""), targets.count)
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            let clearButton = alert.addButton(withTitle: NSLocalizedString("Clear", comment: ""))
            clearButton.hasDestructiveAction = true
            guard await Self.presentAlert(alert, on: panel) == .alertSecondButtonReturn, self.model === model else { return }
            if await HistoryManager.shared.removeFromHistory(targets) {
                model.replaceHistoryItems(Self.collectHistoryItems())
            } else {
                let error = NSAlert()
                error.messageText = NSLocalizedString("Expose Clear History Failed", comment: "")
                _ = await Self.presentAlert(error, on: panel)
            }
        }
    }

    private func enableFileSearch() {
        LocalFileSearchSettings.shared.isEnabled = true
        model?.restartFileSearch()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
        }
    }

    func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard let model else { return event }
        model.isOptionPressed = event.modifierFlags.contains(.option)
        if event.type == .flagsChanged { return event }
        // 系统面板（文件选择、授权）接管期间把按键交回系统，避免误触覆盖层。
        if isPresentingSystemUI || panels.contains(where: { $0.attachedSheet != nil }) { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if KeyboardShortcutStore.shared.matches(event, identifier: "window.showAllFoils") {
            if !event.isARepeat { toggle() }
            return nil
        }
            let hasCommand = modifiers.contains(.command)
            let hasOption = modifiers.contains(.option)
            let hasControl = modifiers.contains(.control)
            // 输入法正在组合文字时，Esc / 回车 / Tab / ⌫ 留给输入法自己处理（取消候选、上屏、删字）。
            let isComposing = (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
            // 收藏筛选与条目收藏使用独立快捷键。
            if KeyboardShortcutStore.shared.matches(event, identifier: "history.filterFavorites") {
                model.pinnedOnly.toggle()
                model.requestSearchFieldFocus()
                return nil
            }
            // 历史条目快捷键优先于主菜单；组合输入及下拉框选择仍交给输入框。
            if !isComposing, !model.isChoosingScope, let item = model.highlightedItem, item.isHistoryEntry {
                if KeyboardShortcutStore.shared.matches(event, identifier: "history.toggleFavorite") {
                    model.onTogglePinned(item)
                    return nil
                }
                if modifiers.intersection([.command, .shift, .option, .control]) == .command {
                    if key == "e", item.canRenameTitle { model.onRenameItem(item); return nil }
                    if key == "i" { model.onShowInformation(item); return nil }
                }
                if event.keyCode == 51, modifiers.intersection([.command, .shift, .option, .control]) == .command {
                    if !event.isARepeat { model.onClearHistoryItem(item) }
                    return nil
                }
            }
            if let delegate = NSApp.delegate as? AppDelegate,
               delegate.matchesShortcut(event, definition: KeyboardShortcutCatalog.openClipboardContent) {
                self.openClipboard()
                return nil
            }
            // ⌘O/⌘P/⌘L 会打开文件对话框、历史搜索等新视图：先收起覆盖层再放行给菜单，
            // 避免打开的内容被覆盖层挡住。
            let opensAnotherView = (Array(IncognitoOpening.titles.keys) + ["history.search", "file.newIncognito", "file.openClipboardIncognito"]).contains {
                KeyboardShortcutStore.shared.matches(event, identifier: $0)
                    || KeyboardShortcutStore.shared.matchesIncognito(event, identifier: $0)
            }
            let isNewFoil = key == "n" && modifiers.intersection([.command, .shift, .option, .control]) == .command
            if opensAnotherView || isNewFoil {
                self.dismiss()
                return event
            }
            // 其余带命令修饰键的按键放行，让菜单快捷键（含再次触发的 ⌃⇧⎋ / ⌥⎋）继续工作。
            if hasCommand {
                return event
            }
            // 带 ⌥ 的按键放行给菜单快捷键（如再次触发的 ⌥⎋）。
            if hasOption {
                return event
            }
            if event.keyCode == 53 { // Esc：组合输入和下拉框优先处理，否则关闭总览。
                if isComposing { return event }
                if model.isChoosingScope {
                    model.searchText = ""
                    return nil
                }
                self.dismiss()
                return nil
            }
            if event.keyCode == 51 && !isComposing && model.isSearching && model.searchText.isEmpty && model.activeScope != nil {
                model.clearActiveScope()
                return nil
            }
            // ⌃P/N/F/B 优先移动高亮，⌃A/⌃E 跳到行首/行尾，其余 ⌃ + 编号/字母仍可直选。
            if hasControl {
                if model.isChoosingScope {
                    if key == "n" || event.keyCode == 45 {
                        model.moveScopeSelection(by: 1)
                        return nil
                    }
                    if key == "p" || event.keyCode == 35 {
                        model.moveScopeSelection(by: -1)
                        return nil
                    }
                }
                switch key {
                case "a": model.moveSelectionToRowStart(); return nil
                case "e": model.moveSelectionToRowEnd(); return nil
                case "p": model.moveSelection(.up); return nil
                case "n": model.moveSelection(.down); return nil
                case "f": model.moveSelection(.right); return nil
                case "b": model.moveSelection(.left); return nil
                default: break
                }
                if let key = event.charactersIgnoringModifiers,
                   let item = model.item(forKey: key) {
                    self.select(item)
                    return nil
                }
                return event
            }
            // ⇧↑/⇧↓ 与 PageUp/PageDown 等价：整页滚动，完成后高亮重定位到可见第一项。
            if modifiers.contains(.shift), event.keyCode == 125 || event.keyCode == 126 {
                model.requestPageScroll(direction: event.keyCode == 126 ? .up : .down)
                return nil
            }
            switch event.keyCode {
            case 48: // 类别选择时确认高亮项；组合输入仍交给输入法。
                if isComposing { return event }
                if model.isPickingScope {
                    model.selectHighlightedScope()
                    return nil
                }
                model.requestSearchFieldFocus()
                return nil
            case 116, 121: // PageUp / PageDown：整页滚动
                model.requestPageScroll(direction: event.keyCode == 116 ? .up : .down)
            case 36, 76: // 回车打开下拉框项、高亮箔片或选择限定范围
                if model.isSearching, isComposing { return event }
                if model.isChoosingScope {
                    model.selectHighlightedScope()
                    return nil
                }
                model.openHighlightedResult()
            case 123: model.moveSelection(.left)   // ←
            case 124: model.moveSelection(.right)  // →
            case 125:
                if model.isChoosingScope {
                    model.moveScopeSelection(by: 1)
                    return nil
                }
                model.moveSelection(.down)   // ↓
            case 126:
                if model.isChoosingScope {
                    model.moveScopeSelection(by: -1)
                    return nil
                }
                model.moveSelection(.up)     // ↑
            default:
                // 普通字符（包括 /）始终进入搜索框。
                return event
            }
            return nil
        }

    func dismiss() {
        guard model != nil || !panels.isEmpty else { return }
        for panel in panels {
            (panel.contentViewController as? FoilExposeViewController)?.prepareForDismissal()
        }
        model?.stopFileSearch()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        model = nil
        let panels = self.panels
        self.panels = []
        // 总览真正退出时一并取消嵌套 sheet，避免遗留对话框和等待中的确认任务。
        func cancelSheets(on window: NSWindow) {
            guard let sheet = window.attachedSheet else { return }
            cancelSheets(on: sheet)
            window.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
        }
        for panel in panels {
            cancelSheets(on: panel)
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
