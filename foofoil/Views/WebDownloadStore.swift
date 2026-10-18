import AppKit
import WebKit

/// 下载由应用持有，关闭来源箔片后仍可完成；目标统一使用系统 Downloads 目录。
@MainActor
final class WebDownloadStore: NSObject, WKDownloadDelegate {
    static let shared = WebDownloadStore()
    private var downloads: [ObjectIdentifier: WKDownload] = [:]
    private var destinations: [ObjectIdentifier: URL] = [:]

    func start(_ download: WKDownload) {
        downloads[ObjectIdentifier(download)] = download
        download.delegate = self
    }

    static func destination(for suggestedFilename: String, in directory: URL, reserved: Set<URL>) -> URL {
        // 网页提供的名称只能是单个文件名，不能跳出下载目录。
        let component = (suggestedFilename as NSString).lastPathComponent
        let name = component.isEmpty || component == "." || component == ".." ? "download" : component
        let original = directory.appendingPathComponent(name)
        let ext = original.pathExtension
        let stem = ext.isEmpty ? name : original.deletingPathExtension().lastPathComponent
        var candidate = original
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate) {
            let numbered = "\(stem) (\(suffix))"
            candidate = directory.appendingPathComponent(ext.isEmpty ? numbered : "\(numbered).\(ext)")
            suffix += 1
        }
        return candidate
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        do {
            let directory = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            let destination = Self.destination(for: suggestedFilename, in: directory,
                                               reserved: Set(destinations.values))
            destinations[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        } catch {
            completionHandler(nil)
            finish(download)
            (NSApp.delegate as? AppDelegate)?.showSaveErrorAlert(error)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download)
        (NSApp.delegate as? AppDelegate)?.showSaveErrorAlert(error)
    }

    private func finish(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        destinations.removeValue(forKey: id)
        downloads.removeValue(forKey: id)
    }
}
