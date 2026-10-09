import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import foofoil

@MainActor
struct AppleMusicHistoryArtworkTests {
    private func imageData() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func coverIsCachedAsSquareThumbnailAndReusedWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let reference = AppleMusicReference(kind: .album, id: "test-album", title: "Album", subtitle: "Artist")
        let config = WindowConfig(id: UUID(), originalImageName: reference.title, appleMusicReference: reference)
        #expect(repository.upsert(config))
        let destination = directory.appendingPathComponent("Thumbnails/cover.heic")
        let data = try imageData()
        let url = URL(string: "https://example.invalid/artwork")!
        let saved = await AppleMusicHistoryArtwork.cache(url: url, reference: reference, historyID: config.id,
                                                         repository: repository, destinationURL: destination) { _ in data }
        #expect(saved)
        #expect(repository.config(id: config.id)?.thumbnailPath == destination.path)
        #expect(repository.recent(limit: 10).first?.thumbnailPath == destination.path)
        let results = await repository.search("Album")
        #expect(results.first?.thumbnailPath == destination.path)
        #expect(results.first?.symbolName == "music.pages.fill")
        #expect(HistoryContentKind.audio.symbolName == "music.note")
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 128 && image.height == 128)
        let reused = await AppleMusicHistoryArtwork.cache(url: url, reference: reference, historyID: config.id,
                                                          repository: repository, destinationURL: destination) { _ in
            Issue.record("Cached artwork must not download again")
            throw URLError(.notConnectedToInternet)
        }
        #expect(reused)
    }

    @Test func failedArtworkDoesNotRemoveHistoryOrWriteBrokenFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let reference = AppleMusicReference(kind: .song, id: "test-song", title: "Song", subtitle: "Artist")
        let config = WindowConfig(id: UUID(), appleMusicReference: reference)
        #expect(repository.upsert(config))
        let destination = directory.appendingPathComponent("cover.heic")
        let url = URL(string: "https://example.invalid/artwork")!
        let failed = await AppleMusicHistoryArtwork.cache(url: url, reference: reference, historyID: config.id,
                                                          repository: repository, destinationURL: destination) { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(!failed)
        let invalid = await AppleMusicHistoryArtwork.cache(url: url, reference: reference, historyID: config.id,
                                                           repository: repository, destinationURL: destination) { _ in Data("bad image".utf8) }
        #expect(!invalid)
        #expect(repository.config(id: config.id)?.appleMusicReference == reference)
        #expect(repository.config(id: config.id)?.thumbnailPath == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func deletedHistoryRejectsLateArtworkDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite3"))
        let reference = AppleMusicReference(kind: .playlist, id: "test-playlist", title: "Playlist", subtitle: "")
        let config = WindowConfig(id: UUID(), appleMusicReference: reference)
        #expect(repository.upsert(config))
        let destination = directory.appendingPathComponent("cover.heic")
        let data = try imageData()
        let saved = await AppleMusicHistoryArtwork.cache(url: URL(string: "https://example.invalid/artwork")!,
                                                         reference: reference, historyID: config.id,
                                                         repository: repository, destinationURL: destination) { _ in
            repository.remove(id: config.id)
            return data
        }
        #expect(!saved && repository.config(id: config.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
