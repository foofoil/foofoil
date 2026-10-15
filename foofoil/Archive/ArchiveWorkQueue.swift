import Foundation

/// 每个压缩包串行执行原生读取；快速切项取消的任务在轮到它时立即退出，不累积并行固实解压。
actor ArchiveWorkQueue {
    func validate(urls: [URL], index: ArchiveIndex) throws {
        try Task.checkCancellation()
        guard (try? ArchiveReader.signatures(urls)) == index.signatures else { throw ArchiveFailure.changed }
    }

    func scan(urls: [URL], password: String?) throws -> ArchiveIndex {
        try Task.checkCancellation()
        return try ArchiveReader.scan(urls: urls, password: password)
    }

    func preview(urls: [URL], index: ArchiveIndex, entry: ArchiveEntry, password: String?, limit: Int64) throws -> ArchivePreviewLease {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("foofoil-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = (entry.path as NSString).deletingLastPathComponent
        do {
            _ = try ArchiveReader.extract(urls: urls, index: index, entries: [entry], root: directory,
                basePath: base == "." ? "" : base, password: password, limit: limit)
            let size = try directory.appendingPathComponent(entry.name).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return ArchivePreviewLease(directory: directory, byteCount: Int64(size))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func export(urls: [URL], index: ArchiveIndex, entries: [ArchiveEntry], selection: ArchiveEntry,
                destination: URL, basePath: String, password: String?, protectedURLs: [URL] = [], progress: @Sendable (Int64) -> Void) throws -> Int {
        try Task.checkCancellation()
        return try ArchiveReader.export(urls: urls, index: index, entries: entries, selection: selection,
            destination: destination, basePath: basePath, password: password, protectedURLs: protectedURLs, progress: progress)
    }
}
