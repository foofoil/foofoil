import Foundation

nonisolated enum SharedFileImport {
    /// 仅导入分享扩展标记的临时文件；Finder 分享的原文件和目录继续使用原路径。
    static func persist(_ urls: [URL], root: URL? = nil) throws -> [URL] {
        let root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("foofoil/Shared Items", isDirectory: true)
        var created: [URL] = []
        do {
            return try urls.map { source in
                guard ShareStaging.isStaged(source) else { return source }
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                created.append(directory)
                let destination = directory.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: destination)
                return destination
            }
        } catch {
            for directory in created { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }
}
