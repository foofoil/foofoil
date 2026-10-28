import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

nonisolated struct ClipboardSearchEntry: Identifiable, Sendable, Equatable {
    enum Content: Sendable, Equatable {
        case text(String), markdown(String), html(String, String?), image(Data), files([URL]), unavailable
    }
    let id: String
    let title: String
    let searchText: String
    let content: Content
    let date: Date
    var sourceBundleIdentifier: String? = nil
    var isCurrentClipboard = false
    var canCopy: Bool { if case .unavailable = content { false } else { true } }
    var imageFilenameExtension: String? {
        guard case .image(let data) = content,
              let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) else { return nil }
        return UTType(type as String)?.preferredFilenameExtension
    }
    var symbolName: String {
        switch content {
        case .text, .markdown: "doc.text"
        case .html: "globe"
        case .image: "photo"
        case .files, .unavailable: "doc"
        }
    }
    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            searchText.range(of: String($0), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
    @MainActor static func current(pasteboard: NSPasteboard = .general) -> Self? {
        let content: Content
        let title: String
        let declaredMarkdown = AppDelegate.markdownPasteboardTypes.compactMap { pasteboard.string(forType: $0) }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let text = declaredMarkdown ?? pasteboard.string(forType: .string) ?? ""
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let imageData = urls.isEmpty ? ([NSPasteboard.PasteboardType.png, .tiff] + (pasteboard.types ?? []).filter { UTType($0.rawValue)?.conforms(to: .image) == true })
            .lazy.compactMap { pasteboard.data(forType: $0) }.first { NSImage(data: $0) != nil } : nil
        if !urls.isEmpty {
            content = .files(urls); title = urls.map(\.lastPathComponent).joined(separator: ", ")
        } else if let data = imageData {
            content = .image(data); title = NSLocalizedString("Clipboard Type Image", comment: "")
        } else if let declaredMarkdown {
            content = .markdown(declaredMarkdown); title = AppState.plainTextHistoryTitle(from: declaredMarkdown) ?? declaredMarkdown
        } else if let html = pasteboard.string(forType: .html), !html.isEmpty {
            content = .html(html, text.isEmpty ? nil : text)
            title = AppState.plainTextHistoryTitle(from: text) ?? NSLocalizedString("Clipboard Web Page", comment: "")
        } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content = .text(text); title = AppState.plainTextHistoryTitle(from: text) ?? text
        } else { return nil }
        return Self(id: "current:\(pasteboard.changeCount)", title: title, searchText: title + "\n" + text, content: content, date: Date())
    }
}

nonisolated enum ClipboardHistoryAccess: Equatable, Sendable { case unknown, available, needsAuthorization, unavailable }
nonisolated struct ClipboardHistorySnapshot: Sendable {
    let access: ClipboardHistoryAccess
    let entries: [ClipboardSearchEntry]
}

/// 系统索引只在后台读取；键入筛选复用快照，不在每个按键上重新解压整个数据库。
actor ClipboardHistoryReader {
    static let shared = ClipboardHistoryReader()
    private var cachedStamp = ""
    private var cached: [ClipboardSearchEntry] = []
    private var store = SpotlightClipboardStore()
    func read() async -> ClipboardHistorySnapshot {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Metadata/CoreSpotlight")
        do { _ = try FileManager.default.contentsOfDirectory(atPath: root.path) }
        catch {
            cached = []; cachedStamp = ""; store = SpotlightClipboardStore()
            let code = (error as NSError).code
            return .init(access: code == NSFileReadNoPermissionError ? .needsAuthorization : .unavailable, entries: [])
        }
        let directory = root.appendingPathComponent("NSFileProtectionCompleteUntilFirstUserAuthentication/index.spotlightV3")
        do {
            let names = [".store.db", "dbStr-1.map.header", "dbStr-2.map.header", "dbStr-4.map.header", "dbStr-5.map.header"]
            let stamp = try names.map { name in
                let values = try directory.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return "\(name):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
            }.joined(separator: "|")
            if stamp != cachedStamp {
                let records = try store.read(directory: directory)
                var unique: [String: ClipboardSearchEntry] = [:]
                for record in records {
                    let urls = record.attachments.compactMap { path -> URL? in
                        let url = path.hasPrefix("file:") ? URL(string: path) : URL(fileURLWithPath: path)
                        guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
                        return url
                    }
                    let content: ClipboardSearchEntry.Content
                    if let text = record.text, !text.isEmpty { content = .text(text) }
                    else if let imageURL = urls.first, UTType(filenameExtension: imageURL.pathExtension)?.conforms(to: .image) == true,
                            let data = try? Data(contentsOf: imageURL) { content = .image(data) }
                    else if !urls.isEmpty { content = .files(urls) }
                    else { content = .unavailable }
                    let entry = ClipboardSearchEntry(id: record.identifier, title: record.title,
                                                     searchText: record.title + "\n" + (record.text ?? "") + "\n" + urls.map(\.lastPathComponent).joined(separator: " "),
                                                     content: content, date: record.date, sourceBundleIdentifier: record.sourceBundleIdentifier)
                    if unique[entry.id].map({ $0.date < entry.date }) ?? true { unique[entry.id] = entry }
                }
                cached = unique.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
                cachedStamp = stamp
            }
            return currentSnapshot()
        } catch {
            return .init(access: (error as NSError).code == NSFileReadNoPermissionError ? .needsAuthorization : .unavailable, entries: [])
        }
    }
    /// 显示旧快照前重新检查权限和保留时长，撤销授权后不会继续展示缓存内容。
    func cachedSnapshot() async -> ClipboardHistorySnapshot? {
        guard !cachedStamp.isEmpty else { return nil }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Metadata/CoreSpotlight")
        do { _ = try FileManager.default.contentsOfDirectory(atPath: root.path) }
        catch {
            cached = []; cachedStamp = ""; store = SpotlightClipboardStore()
            return .init(access: (error as NSError).code == NSFileReadNoPermissionError ? .needsAuthorization : .unavailable, entries: [])
        }
        return currentSnapshot()
    }
    private func currentSnapshot() -> ClipboardHistorySnapshot {
        let preferences = UserDefaults(suiteName: "com.apple.Spotlight")
        if preferences?.object(forKey: "PasteboardHistoryEnabled") != nil, preferences?.bool(forKey: "PasteboardHistoryEnabled") == false {
            return .init(access: .available, entries: [])
        }
        let timeout = preferences?.object(forKey: "PasteboardHistoryTimeout").flatMap { ($0 as? NSNumber)?.doubleValue } ?? 28800
        let threshold = Date().addingTimeInterval(-(timeout > 0 ? timeout : 28800))
        return .init(access: .available, entries: cached.filter { $0.date >= threshold })
    }

}

@MainActor
final class ClipboardHistorySearch: ObservableObject {
    @Published private(set) var access: ClipboardHistoryAccess = .unknown
    @Published private(set) var entries: [ClipboardSearchEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var copyError: String?
    private var snapshot: [ClipboardSearchEntry] = []
    private var current: ClipboardSearchEntry?
    private var query = ""
    private var task: Task<Void, Never>?
    private var active = false
    private var activation: AnyCancellable?
    private let load: @Sendable () async -> ClipboardHistorySnapshot
    private let currentContent: @MainActor () -> ClipboardSearchEntry?
    private let cachedLoad: @Sendable () async -> ClipboardHistorySnapshot?
    init(load: (@Sendable () async -> ClipboardHistorySnapshot)? = nil,
         currentContent: @escaping @MainActor () -> ClipboardSearchEntry? = { .current() },
         cachedLoad: (@Sendable () async -> ClipboardHistorySnapshot?)? = nil) {
        self.load = load ?? { await ClipboardHistoryReader.shared.read() }
        if let cachedLoad { self.cachedLoad = cachedLoad }
        else if load == nil { self.cachedLoad = { await ClipboardHistoryReader.shared.cachedSnapshot() } }
        else { self.cachedLoad = { nil } }
        self.currentContent = currentContent
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { if self?.active == true { self?.refresh() } }
            }
    }
    func search(_ query: String) {
        self.query = query
        if !active { active = true; refresh() } else { filter() }
    }
    func refresh() {
        task?.cancel()
        access = .unknown
        current = currentContent()
        filter()
        isLoading = true
        task = Task { [weak self, load, cachedLoad] in
            if let cached = await cachedLoad() {
                guard let self, !Task.isCancelled, self.active else { return }
                self.access = cached.access; self.snapshot = cached.entries; self.filter()
            }
            let result = await load()
            guard let self, !Task.isCancelled, self.active else { return }
            self.access = result.access
            self.snapshot = result.entries
            self.isLoading = false
            self.filter()
        }
    }
    func stop() {
        active = false; task?.cancel(); task = nil
        access = .unknown; snapshot = []; current = nil; entries = []; isLoading = false; copyError = nil
    }
    private func filter() {
        // 未授权时最多一项；不把系统历史导入浮箔自己的历史数据库。
        let values = access == .available ? snapshot : []
        var all = values
        if let current, !all.contains(where: { $0.content == current.content }) { all.insert(current, at: 0) }
        entries = all.filter { $0.matches(query) }.map { entry in
            var result = entry
            result.isCurrentClipboard = entry.content == current?.content
            return result
        }
    }
    /// 只有用户点击复制才改写默认剪贴板；打开搜索结果始终使用自己的内容快照。
    @discardableResult
    func copy(_ entry: ClipboardSearchEntry, to pasteboard: NSPasteboard = .general) -> Bool {
        guard entry.canCopy else { return false }
        let success: Bool
        switch entry.content {
        case .unavailable: return false
        case .files(let urls):
            pasteboard.clearContents()
            success = pasteboard.writeObjects(urls as [NSURL])
        case .text(let text):
            pasteboard.clearContents()
            success = pasteboard.setString(text, forType: .string)
        case .markdown(let text):
            pasteboard.clearContents()
            success = pasteboard.setString(text, forType: .string)
                && pasteboard.setString(text, forType: AppDelegate.markdownPasteboardTypes[0])
        case .html(let html, let text):
            pasteboard.clearContents()
            success = pasteboard.setString(html, forType: .html)
                && (text.map { pasteboard.setString($0, forType: .string) } ?? true)
        case .image(let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) else {
                copyError = NSLocalizedString("Clipboard History Copy Failed", comment: ""); return false
            }
            pasteboard.clearContents()
            success = pasteboard.setData(data, forType: NSPasteboard.PasteboardType(type as String))
        }
        copyError = success ? nil : NSLocalizedString("Clipboard History Copy Failed", comment: "")
        if success { current = currentContent(); filter() }
        return success
    }

    func openAuthorizationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}
