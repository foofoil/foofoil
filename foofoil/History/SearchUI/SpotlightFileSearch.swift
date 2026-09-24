import Foundation
import UniformTypeIdentifiers

nonisolated struct SpotlightFileResult: Identifiable, Sendable, Equatable {
    let url: URL
    let modifiedAt: Date
    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }
    var symbolName: String {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .movie) { return "play.rectangle" }
        if type.conforms(to: .pdf) { return "text.document" }
        return "doc"
    }

    static func ranked(_ files: [Self], query: String, excluding paths: Set<String> = []) -> [Self] {
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        func rank(_ file: Self) -> Int {
            let name = file.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            if name == needle { return 0 }
            if (name as NSString).deletingPathExtension == needle { return 1 }
            return name.hasPrefix(needle) ? 2 : 3
        }
        var seen = paths
        return files.filter { seen.insert($0.id).inserted }.sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.id < $1.id
        }.prefix(20).map { $0 }
    }
}

nonisolated enum SpotlightSearchOutcome: Sendable {
    case results([SpotlightFileResult])
    /// 初次收集尚未结束，先展示当前可用的候选。
    case progress([SpotlightFileResult])
    /// 尚未授权搜索用户主目录。
    case needsAuthorization
    /// 已保存的主目录书签无法恢复，需要用户重新开启。
    case authorizationUnavailable
    case unavailable
    case timedOut
}

/// 查询对象和观察者始终留在主运行循环，只提取有限数量的元数据，不读取文件正文。
@MainActor
final class SpotlightFileSearch {
    private var accessedScopes: [URL] = []
    private var generation = 0
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private let makeQuery: () -> NSMetadataQuery
    private let deadline: Duration
    private var timeout: Task<Void, Never>?
    private var completion: ((SpotlightSearchOutcome) -> Void)?

    init(makeQuery: @escaping () -> NSMetadataQuery = { NSMetadataQuery() }, deadline: Duration = .seconds(3)) {
        self.makeQuery = makeQuery
        self.deadline = deadline
    }

    nonisolated static func predicate(for text: String) -> NSPredicate {
        NSPredicate(format: "%K CONTAINS[cd] %@ AND NOT (%K == %@)",
                    "kMDItemFSName", text, "kMDItemContentType", "public.folder")
    }

    func start(text: String, scopes: [URL], extensions: Set<String>, completion: @escaping (SpotlightSearchOutcome) -> Void) {
        cancel()
        guard !scopes.isEmpty else { completion(.needsAuthorization); return }
        // 调用方已启动安全范围访问，服务接管到查询完成或取消。
        accessedScopes = scopes
        let requestGeneration = generation
        let query = makeQuery()
        query.searchScopes = scopes.map(\.path)
        query.predicate = Self.predicate(for: text)
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemFSContentChangeDate", ascending: false),
                                 NSSortDescriptor(key: "kMDItemPath", ascending: true)]
        query.notificationBatchingInterval = 0.1
        self.query = query
        self.completion = completion
        for name in [Notification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == requestGeneration else { return }
                    self.receiveResults(text: text, extensions: extensions, isFinished: name == .NSMetadataQueryDidFinishGathering)
                }
            })
        }
        guard query.start() else { finish(.unavailable); return }
        timeout = Task { [weak self, deadline] in
            do { try await Task.sleep(for: deadline) } catch { return }
            guard let self, self.generation == requestGeneration else { return }
            // 截止只限制等待时间，不能把系统已经收集到的可用文件丢弃。
            let files = self.collectResults(text: text, extensions: extensions)
            self.finish(files.isEmpty ? .timedOut : .results(files))
        }
    }

    private func receiveResults(text: String, extensions: Set<String>, isFinished: Bool) {
        let files = collectResults(text: text, extensions: extensions)
        // 系统查询可能命中数万项；候选已足够时停止，不等待全量排序和收集完成。
        if isFinished || ((query?.resultCount ?? 0) >= 200 && !files.isEmpty) {
            finish(.results(files))
        } else if !files.isEmpty {
            completion?(.progress(files))
        }
    }

    private func collectResults(text: String, extensions: Set<String>) -> [SpotlightFileResult] {
        guard let query else { return [] }
        query.disableUpdates()
        defer { query.enableUpdates() }
        var files: [SpotlightFileResult] = []
        for index in 0..<min(query.resultCount, 200) {
            // gathering 期间批量属性接口可能尚未填充，直接从元数据项读取。
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: "kMDItemPath") as? String else { continue }
            let url = URL(fileURLWithPath: path)
            guard url.isFileURL,
                  Self.isWithinScopes(url, scopes: accessedScopes),
                  // 再做字面匹配，避免 Spotlight 的查询语法把输入中的通配符扩展为结果。
                  url.lastPathComponent.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                  (item.value(forAttribute: "kMDItemFSInvisible") as? NSNumber)?.boolValue != true,
                  !url.pathComponents.contains(where: { $0.hasPrefix(".") }),
                  !Self.isHomeLibrary(url),
                  !AppState.isManagedCacheURL(url),
                  let identifier = item.value(forAttribute: "kMDItemContentType") as? String,
                  Self.supports(url: url, typeIdentifier: identifier, extensions: extensions) else { continue }
            files.append(.init(url: url, modifiedAt: item.value(forAttribute: "kMDItemFSContentChangeDate") as? Date ?? .distantPast))
        }
        return files
    }

    nonisolated static func isWithinScopes(_ url: URL, scopes: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return scopes.contains {
            let root = $0.standardizedFileURL.path
            return path.hasPrefix(root == "/" ? "/" : root + "/")
        }
    }

    /// 主目录范围下排除 ~/Library：应用数据与缓存数量庞大，不属于用户要找的文件。
    nonisolated static func isHomeLibrary(_ url: URL) -> Bool {
        let library = SpotlightSearchAccess.userHome.appendingPathComponent("Library", isDirectory: true).standardizedFileURL.path
        return url.standardizedFileURL.path.hasPrefix(library + "/")
    }

    nonisolated static func supports(url: URL, typeIdentifier: String, extensions: Set<String>) -> Bool {
        guard let type = UTType(typeIdentifier), !type.conforms(to: .folder), !type.conforms(to: .application) else { return false }
        if extensions.contains(url.pathExtension.lowercased()) || AppState.textFilenameExtensions.contains(url.pathExtension.lowercased()) { return true }
        return [.image, .pdf, .html, .text, .movie, .audio].contains { type.conforms(to: $0) }
            || typeIdentifier == "com.apple.webarchive"
            || url.pathExtension.lowercased() == "cue"
    }

    private func finish(_ outcome: SpotlightSearchOutcome) {
        let callback = completion
        cancel()
        callback?(outcome)
    }

    func cancel() {
        generation += 1
        query?.stop()
        query = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        timeout?.cancel()
        timeout = nil
        completion = nil
        accessedScopes.forEach { $0.stopAccessingSecurityScopedResource() }
        accessedScopes = []
    }
}

extension SpotlightFileSearch {
    /// 用宿主与可用扩展声明的候选类型，在已授权的主目录范围内查询；未授权时直接报告状态。
    func start(text: String, completion: @escaping (SpotlightSearchOutcome) -> Void) {
        let extensions = Set(ExtensionHost.shared.resolver.allDescriptors()
            .filter { $0.isEnabled && $0.isRuntimeAvailable }
            .flatMap(\.filenameExtensions).map { $0.lowercased() })
        do {
            let scopes = try SpotlightSearchAccess.shared.beginAccess()
            start(text: text, scopes: scopes, extensions: extensions, completion: completion)
        } catch {
            completion(.authorizationUnavailable)
        }
    }
}
