import Foundation
import MusicKit

/// 封面缓存属于历史条目，不随播放器切歌改变，也不依赖音乐箔继续打开。
@MainActor
enum AppleMusicHistoryArtwork {
    private static var tasks: [UUID: Task<Void, Never>] = [:]

    static func schedule(_ item: AppleMusicLibraryItem, historyID: UUID) {
        guard tasks[historyID] == nil, let url = item.artwork?.url(width: 256, height: 256) else { return }
        let reference = item.reference
        tasks[historyID] = Task {
            defer { tasks[historyID] = nil }
            await cache(url: url, reference: reference, historyID: historyID)
        }
    }

    @discardableResult
    static func cache(
        url: URL, reference: AppleMusicReference, historyID: UUID,
        repository: HistoryRepository = .shared,
        destinationURL: URL? = nil,
        fetch: @Sendable (URL) async throws -> Data = { url in
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    ) async -> Bool {
        guard let config = repository.config(id: historyID), config.appleMusicReference == reference else { return false }
        let destination = destinationURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("foofoil/Thumbnails", isDirectory: true)
            .appendingPathComponent("\(historyID.uuidString).heic")
        if FileManager.default.fileExists(atPath: destination.path) {
            repository.updateThumbnailPath(id: historyID, path: destination.path)
            if repository === HistoryRepository.shared { HistoryManager.shared.refresh() }
            return true
        }
        do {
            let data = try await fetch(url)
            // 下载期间可以关闭箔；历史被删除或来源被替换时则不再写入。
            guard !Task.isCancelled, repository.config(id: historyID)?.appleMusicReference == reference else { return false }
            let written = await Task.detached(priority: .utility) {
                HistoryThumbnailGenerator.generateArtworkThumbnail(data: data, destinationURL: destination)
            }.value
            guard written else { return false }
            guard repository.config(id: historyID)?.appleMusicReference == reference else {
                try? FileManager.default.removeItem(at: destination)
                return false
            }
            repository.updateThumbnailPath(id: historyID, path: destination.path)
            if repository === HistoryRepository.shared { HistoryManager.shared.refresh() }
            return true
        } catch { return false }
    }
}
