import Foundation

extension ArchiveReader {
    /// 只在提取全部成功且未取消后替换目标；暂存目录只归本次任务所有。
    nonisolated static func export(urls: [URL], index: ArchiveIndex, entries: [ArchiveEntry],
        selection: ArchiveEntry, destination: URL, basePath: String, password: String?,
        protectedURLs: [URL] = [], limit: Int64 = maximumExportBytes, progress: @Sendable (Int64) -> Void = { _ in }) throws -> Int {
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationAttributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        for source in urls + protectedURLs {
            if source.resolvingSymlinksInPath().standardizedFileURL.path == destinationPath { throw ArchiveFailure.originalDestination }
            if let destinationAttributes, let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: source.path),
               let destinationInode = destinationAttributes[.systemFileNumber] as? NSNumber,
               let sourceInode = sourceAttributes[.systemFileNumber] as? NSNumber,
               destinationInode == sourceInode,
               (destinationAttributes[.systemNumber] as? NSNumber) == (sourceAttributes[.systemNumber] as? NSNumber) { throw ArchiveFailure.originalDestination }
        }
        if selection.isDirectory, FileManager.default.fileExists(atPath: destination.path) { throw ArchiveFailure.conflict }
        let fm = FileManager.default
        // 系统替换目录获得目标同卷暂存区；失败或取消不会留下伪完整输出。
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: staging) }
        let output = staging.appendingPathComponent("result", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let skipped = try extract(urls: urls, index: index, entries: entries, root: output, basePath: basePath, password: password, limit: limit, progress: progress)
        try Task.checkCancellation()
        let result = selection.isDirectory ? output : output.appendingPathComponent(selection.name)
        if fm.fileExists(atPath: destination.path) {
            guard !selection.isDirectory else { throw ArchiveFailure.conflict }
            _ = try fm.replaceItemAt(destination, withItemAt: result)
        } else { try fm.moveItem(at: result, to: destination) }
        return skipped
    }
}
