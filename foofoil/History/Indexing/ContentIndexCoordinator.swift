import Foundation
import AppKit

public final class ContentIndexCoordinator: @unchecked Sendable {
    public static let shared = ContentIndexCoordinator()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.foofoil.history.indexing"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let lock = NSLock()
    private var operations: [UUID: Operation] = [:]
    private var scheduledPaths: [UUID: String] = [:]

    private init() {}

    /// - Parameter force: 为 true 时忽略同路径去重，强制重建缩略图并重跑索引（如同目录封面经授权后才可用）。
    public func schedule(config: WindowConfig, force: Bool = false) {
        let kind = config.contentKind ?? HistoryContentKind.infer(from: config)
        guard kind == .image || kind == .pdf || kind == .video || kind == .audio else { return }
        // 扩展音频列表没有 imagePath，用列表首项文件兜底。
        guard let path = config.imagePath ?? config.fileList?.items.first?.path else { return }
        // 多分区音频的缩略图来自各分区封面，只随分区集合变化重建，切歌不必重拼宫格；
        // 其它内容沿用路径去重（追加目录会改变分区集合）。
        let sectionKey = config.fileList.map { $0.sections.map(\.id).joined(separator: ",") } ?? ""
        let usesSectionThumbnail = kind == .audio && (config.fileList?.sections.count ?? 0) >= 2
        let scheduleKey = usesSectionThumbnail
            ? "sections|\(sectionKey)|\(config.customCoverPath ?? "")"
            : "\(path)|\(config.customCoverPath ?? "")"
        lock.lock()
        if !force, scheduledPaths[config.id] == scheduleKey {
            lock.unlock()
            return
        }
        operations[config.id]?.cancel()
        scheduledPaths[config.id] = scheduleKey
        lock.unlock()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard operation?.isCancelled == false else { return }
            do {
                // 1. 生成正方形 HEIC 缩略图文件并更新数据库
                let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("foofoil", isDirectory: true)
                let thumbnailURL = root.appendingPathComponent("Thumbnails").appendingPathComponent("\(config.id.uuidString).heic")

                // 多分区音频列表用各分区封面拼宫格；封面不足两张时回退单封面。
                var generatedThumbnail = false
                if kind == .audio, let list = config.fileList, list.sections.count >= 2 {
                    let covers = Self.audioSectionCoverImages(for: list)
                    if covers.count >= 2 {
                        generatedThumbnail = HistoryThumbnailGenerator.generateGridThumbnail(
                            images: covers,
                            destinationURL: thumbnailURL
                        )
                    }
                }
                if !generatedThumbnail {
                    generatedThumbnail = HistoryThumbnailGenerator.generateThumbnail(
                        for: URL(fileURLWithPath: path),
                        kind: kind,
                        destinationURL: thumbnailURL,
                        customCoverURL: config.customCoverPath.map { URL(fileURLWithPath: $0) }
                    )
                }
                if generatedThumbnail {
                    HistoryRepository.shared.updateThumbnailPath(id: config.id, path: thumbnailURL.path)
                    HistoryManager.shared.refresh()
                }

                // 2. 提取文本 OCR 并进行索引；音视频没有可 OCR 的画面，音频改为索引曲目元数据
                if kind == .audio {
                    let info = AudioMetadataLoader.loadSynchronously(from: URL(fileURLWithPath: path))
                    let text = [info.title, info.artist, info.album, info.albumArtist, info.composer, info.genre, info.year]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    guard operation?.isCancelled == false,
                          HistoryRepository.shared.config(id: config.id)?.imagePath == path else { return }
                    if !text.isEmpty {
                        HistoryRepository.shared.replaceChunks(historyID: config.id, chunkKind: 2, chunks: [(text, nil)])
                    }
                } else if kind != .video {
                    let chunks: [(String, Int?)]
                    if kind == .pdf {
                        chunks = try PDFTextIndexer.extract(url: URL(fileURLWithPath: path)) { operation?.isCancelled ?? true }
                    } else {
                        chunks = [(try ImageOCRIndexer.recognize(url: URL(fileURLWithPath: path)), nil)]
                    }
                    guard operation?.isCancelled == false,
                          HistoryRepository.shared.config(id: config.id)?.imagePath == path else { return }
                    HistoryRepository.shared.replaceChunks(historyID: config.id, chunkKind: kind == .pdf ? 4 : 2, chunks: chunks.filter { !$0.0.isEmpty })
                }
            } catch {
                NSLog("内容索引失败（%@）：%@", config.id.uuidString, error.localizedDescription)
            }
        }
        lock.lock(); operations[config.id] = operation; lock.unlock()
        queue.addOperation(operation)
    }

    public func indexWebContent(historyID: UUID, text: String) {
        let content = WebContentIndexer.sanitize(text)
        queue.addOperation {
            guard HistoryRepository.shared.config(id: historyID) != nil else { return }
            let chunks = TextContentIndexer.chunk(content).map { ($0, Optional<Int>.none) }
            HistoryRepository.shared.replaceChunks(historyID: historyID, chunkKind: 3, chunks: chunks)
        }
    }

    public func cancel(historyID: UUID) {
        lock.lock(); let operation = operations.removeValue(forKey: historyID); scheduledPaths.removeValue(forKey: historyID); lock.unlock()
        operation?.cancel()
    }

    public func cancelAll(excluding ids: Set<UUID> = []) {
        lock.lock()
        let cancelled = operations.filter { !ids.contains($0.key) }
        cancelled.keys.forEach { operations.removeValue(forKey: $0); scheduledPaths.removeValue(forKey: $0) }
        lock.unlock()
        cancelled.values.forEach { $0.cancel() }
    }

    /// 各分区封面：按分区顺序取每个分区首条目的内嵌/同目录封面，最多四张供宫格使用。
    /// 运行在后台索引队列，通过条目的安全范围书签解析并临时持有访问授权。
    private static func audioSectionCoverImages(for list: FileListState) -> [NSImage] {
        list.sections.prefix(4).compactMap { section in
            guard let item = list.items.first(where: { $0.resolvedSectionID == section.id }) else { return nil }
            return sectionCoverImage(for: item)
        }
    }

    private static func sectionCoverImage(for item: FileListItem) -> NSImage? {
        let resolved: URL?
        if let bookmark = item.bookmark, let bookmarked = AppState.resolveVideoBookmark(bookmark) {
            resolved = bookmarked
        } else {
            resolved = FileManager.default.fileExists(atPath: item.path) ? item.url : nil
        }
        guard let url = resolved else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return AudioMetadataLoader.loadSynchronously(from: url).artwork
    }
}
