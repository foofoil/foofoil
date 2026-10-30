import AppKit
import Foundation

/// 网页图标是可丢弃的派生数据，按历史记录 ID 保存，避免改变截图和数据库。
enum WebFaviconCache {
    static func path(for id: UUID) -> String {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("foofoil/Favicons", isDirectory: true)
            .appendingPathComponent(id.uuidString + ".png").path
    }

    static func image(for id: UUID) -> NSImage? {
        NSImage(contentsOfFile: path(for: id))
    }

    static func cache(iconURL: URL, historyID: UUID) async {
        guard ["http", "https"].contains(iconURL.scheme?.lowercased() ?? "") else { return }
        do {
            var request = URLRequest(url: iconURL)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  data.count <= 1_048_576, let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return }
            let destination = URL(fileURLWithPath: path(for: historyID))
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: destination, options: .atomic)
        } catch {
            // 图标获取失败时沿用已有缓存和默认图标。
        }
    }
}
