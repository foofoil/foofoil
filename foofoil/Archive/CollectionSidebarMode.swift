import Foundation
import UniformTypeIdentifiers

nonisolated enum CollectionSidebarMode: String, Codable, CaseIterable, Sendable {
    case folder, image, audio, video

    var kind: FileListKind? {
        switch self {
        case .folder: nil
        case .image: .image
        case .audio: .audio
        case .video: .video
        }
    }
    var symbol: String {
        switch self {
        case .folder: "folder"
        case .image: "photo"
        case .audio: "music.note"
        case .video: "play.rectangle"
        }
    }
    var titleKey: String {
        switch self {
        case .folder: "Directory Contents"
        case .image: "Image List"
        case .audio: "Audio List"
        case .video: "Video List"
        }
    }
}

extension AppState {
    /// 同类型批次沿用已有列表；混合批次在一个箔内保留文件树。
    static func needsCollectionTree(_ urls: [URL]) -> Bool {
        guard let first = urls.first else { return false }
        let firstKind = FileListGrouper.dropKind(url: first)
        return urls.dropFirst().contains { FileListGrouper.dropKind(url: $0) != firstKind }
    }

    func openFileCollection(_ urls: [URL], roots: [URL]? = nil, title: String? = nil) {
        let files = FileListGrouper.uniqued(urls)
        guard !files.isEmpty else { return }
        let volumes = (roots ?? files).map { ArchiveSource.Volume(path: $0.path, bookmark: Self.makeSecurityScopedBookmark(for: $0)) }
        var common = files[0].deletingLastPathComponent().pathComponents
        for file in files.dropFirst() {
            while !file.pathComponents.starts(with: common), !common.isEmpty { common.removeLast() }
        }
        let derivedTitle = roots?.count == 1 ? roots?.first?.lastPathComponent : common.last
        let source = ArchiveSource(volumes: volumes, displayName: title ?? derivedTitle,
            localFiles: files.map { .init(path: $0.path, bookmark: Self.makeSecurityScopedBookmark(for: $0)) })
        resetContent()
        restoreArchive(source)
        saveState()
    }
}

extension ArchiveSource {
    /// 输入文件顺序不变，目录按路径逐级补齐，避免多根目录中同名文件相互覆盖。
    nonisolated func localIndex() -> ArchiveIndex {
        let files = localFiles ?? []
        let paths = files.map { URL(fileURLWithPath: $0.path).standardizedFileURL.pathComponents }
        var common = paths.first.map { Array($0.dropLast()) } ?? []
        for path in paths.dropFirst() {
            while !path.starts(with: common), !common.isEmpty { common.removeLast() }
        }
        if volumes.count == 1, let root = volumes.first,
           files.allSatisfy({ $0.path.hasPrefix(root.path + "/") }) {
            common = URL(fileURLWithPath: root.path).standardizedFileURL.pathComponents
        }
        var entries = [ArchiveEntry(id: "root", ordinal: nil, path: "", parentID: nil, isDirectory: true, size: nil, encrypted: false, isRegular: false)]
        var directories: Set<String> = []
        for (index, components) in paths.enumerated() {
            let relative = Array(components.dropFirst(common.count))
            var parent = "root"
            for depth in 1..<relative.count {
                let path = relative.prefix(depth).joined(separator: "/")
                let id = "directory:" + path
                if directories.insert(id).inserted {
                    entries.append(.init(id: id, ordinal: nil, path: path, parentID: parent, isDirectory: true, size: nil, encrypted: false, isRegular: false))
                }
                parent = id
            }
            entries.append(.init(id: "file:\(index)", ordinal: index, path: relative.joined(separator: "/"), parentID: parent,
                                 isDirectory: false, size: nil, encrypted: false, isRegular: true))
        }
        return .init(entries: entries, format: "", signatures: [])
    }
}
