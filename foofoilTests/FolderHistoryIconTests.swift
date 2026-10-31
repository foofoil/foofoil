import Foundation
import Testing
@testable import foofoil

struct FolderHistoryIconTests {
    @Test func folderIconsPersistAcrossRecentAndIndexedSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite3"))
        let folder = WindowConfig(id: UUID(), imagePath: root.path, originalImageName: "FolderIconReview",
            contentKind: .archive, archiveSource: .init(volumes: [.init(path: root.path)], displayName: "FolderIconReview",
                localFiles: [.init(path: root.appendingPathComponent("file.txt").path)]))
        let archive = WindowConfig(id: UUID(), imagePath: root.appendingPathComponent("archive.zip").path,
            originalImageName: "ArchiveIconReview.zip", contentKind: .archive,
            archiveSource: .init(volumes: [.init(path: root.appendingPathComponent("archive.zip").path)]))
        #expect(folder.historyMenuSymbolName == "folder")
        #expect(archive.historyMenuSymbolName == "archivebox")
        #expect(repository.upsert(folder))
        #expect(repository.upsert(archive))
        #expect(repository.config(id: folder.id)?.historyMenuSymbolName == "folder")
        let recent = await repository.search("")
        #expect(recent.first { $0.id == folder.id }?.symbolName == "folder")
        #expect(recent.first { $0.id == archive.id }?.symbolName == "archivebox")
        let indexed = await repository.search("FolderIconReview")
        #expect(indexed.first { $0.id == folder.id }?.symbolName == "folder")
        let scoped = await repository.searchOpeningHistory("FolderIconReview", kind: .archive)
        #expect(scoped.first?.symbolName == "folder")
    }
}
