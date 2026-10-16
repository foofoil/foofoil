//  AppState+Cache.swift
//  foofoil
//
//  Created by tolg on 2026/7/6.
//


import Foundation
import Combine
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO
import SwiftUI


extension AppState {
        /// 每个窗口只结束自己成功取得的安全范围访问。
        func retainFileAccess(to url: URL) {
            guard !isArchivePreview else { return }
            if accessingVideoURL == url { return }
            stopVideoAccess()
            videoBookmarkData = nil
            mediaSidecarBookmarkData = nil
            guard url.isFileURL, !Self.isManagedCacheURL(url) else { return }
            if url.startAccessingSecurityScopedResource() { accessingVideoURL = url }
            videoBookmarkData = Self.makeSecurityScopedBookmark(for: url)
        }

        func managedBodyURL(extension ext: String) -> URL? {
            guard let root = Self.getFoofoilDirectoryURL() else { return nil }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let prefix = isIncognito ? "session_body_" : "managed_body_"
            let url = root.appendingPathComponent("\(prefix)\(UUID().uuidString).\(ext)")
            ownedBodyPaths.insert(url.path)
            return url
        }

        /// 便笺与剪贴板正文走同一托管路径；编辑防抖后才写入，不回写外部原文件。
        func persistManagedTextIfNeeded(createIfNeeded: Bool = false) {
            guard (!text.isEmpty || textURL != nil), imageURL == nil, webURL == nil, extensionSession == nil,
                  sourceFingerprint != KeyboardShortcutsOverview.sourceFingerprint,
                  sourceFingerprint != SupportedContentOverview.sourceFingerprint else { return }
            if textURL == nil, createIfNeeded {
                textURL = managedBodyURL(extension: isMarkdownPreview && isMarkdownDocument ? "md" : "txt")
            }
            guard let url = textURL, Self.isManagedCacheURL(url) else { return }
            if let previous = lastManagedTextWrite, previous.url == url, previous.text == text { return }
            lastManagedTextWrite = (url, text)
            let content = Data(text.utf8)
            ContentCache.shared.enqueueBodyWrite(content, to: url) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.textURL == url else { return }
                    self.lastManagedTextWrite = nil
                    self.reportFileOpenFeedback([.init(url: url, reason: .failed)])
                }
            }
        }

        // MARK: - Cache Management Helpers

        /// 将旧版本 Flofoil/Flamina 的数据目录迁移到 foofoil，仅在新目录不存在时执行。
        @discardableResult
        nonisolated static func migrateLegacySupportDirectoryIfNeeded() -> Bool {
            guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
            let targetURL = appSupportURL.appendingPathComponent("foofoil", isDirectory: true)
            guard !FileManager.default.fileExists(atPath: targetURL.path) else { return false }
            for legacyName in ["Flofoil", "Flamina"] {
                let legacyURL = appSupportURL.appendingPathComponent(legacyName, isDirectory: true)
                guard FileManager.default.fileExists(atPath: legacyURL.path) else { continue }
                do {
                    try FileManager.default.moveItem(at: legacyURL, to: targetURL)
                    return true
                } catch {
                    NSLog("迁移 %@ 支持目录到 foofoil 失败：%@", legacyName, error.localizedDescription)
                    return false
                }
            }
            return false
        }

        nonisolated static func getFoofoilDirectoryURL() -> URL? {
            guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return nil
            }
            _ = migrateLegacySupportDirectoryIfNeeded()
            return appSupportURL.appendingPathComponent("foofoil", isDirectory: true)
        }

        /// 返回应用自建缓存目录，兼容旧版 Flofoil/Flamina 目录以防迁移失败。
        public nonisolated static func cacheDirectoryURLs() -> [URL] {
            guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return []
            }
            _ = migrateLegacySupportDirectoryIfNeeded()
            let currentURL = appSupportURL.appendingPathComponent("foofoil", isDirectory: true)
            var urls: [URL] = []
            if FileManager.default.fileExists(atPath: currentURL.path) { urls.append(currentURL) }
            for legacyName in ["Flofoil", "Flamina"] {
                let legacyURL = appSupportURL.appendingPathComponent(legacyName, isDirectory: true)
                if FileManager.default.fileExists(atPath: legacyURL.path) { urls.append(legacyURL) }
            }
            // 若两者都不存在，返回目标路径供后续创建使用
            if urls.isEmpty { urls.append(currentURL) }
            return urls
        }

        /// 临时分享导出的一个 UUID 目录是同一所有权单元；子目录条目也不能冒充用户原文件。
        nonisolated static func managedShareRoot(for url: URL) -> URL? {
            guard url.isFileURL, let support = getFoofoilDirectoryURL() else { return nil }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            for name in ["Shared Items", "Session Shared Items"] {
                let root = support.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
                guard resolved.path.hasPrefix(root.path + "/") else { continue }
                let relative = resolved.path.dropFirst(root.path.count + 1).split(separator: "/")
                if let first = relative.first, UUID(uuidString: String(first)) != nil {
                    return root.appendingPathComponent(String(first), isDirectory: true)
                }
            }
            return nil
        }

        /// 仅识别由本应用写入的缓存文件，避免误删 Application Support 中的其他内容。
        public nonisolated static func isManagedCacheURL(_ url: URL) -> Bool {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            if Self.managedShareRoot(for: resolved) != nil { return true }
            guard cacheDirectoryURLs().contains(where: {
                resolved.deletingLastPathComponent().path == $0.resolvingSymlinksInPath().standardizedFileURL.path
            }) else { return false }
            let name = resolved.lastPathComponent
            return name.hasPrefix("managed_body_") || name.hasPrefix("session_body_") || name.hasPrefix("cached_image") ||
                name.hasPrefix("cached_text_") ||
                name.hasPrefix("cached_web_") ||
                name.hasPrefix("cached_cover_") ||
                name.hasPrefix("cached_subject_") ||
                name.hasPrefix("cached_package_") ||
                name.hasPrefix(FragmentedMP4PlaybackCopy.filePrefix)
        }

        /// 当前窗口正在使用的本地缓存路径；分片媒体的播放副本随源文件一并保留。
        public var cachedContentPaths: Set<String> {
            let playbackCopies = [imageURL].compactMap { $0 }.compactMap(FragmentedMP4PlaybackCopy.copyURL(for:))
            return ([imageURL, textURL, webURL, customCoverURL] + playbackCopies + (fileList?.items.map(\.url) ?? []) + (archiveSession?.source.volumes.map { URL(fileURLWithPath: $0.path) } ?? []))
                .compactMap { $0 }
                .filter { $0.isFileURL && Self.isManagedCacheURL($0) }
                .map(\.path)
                .reduce(into: Set<String>()) { $0.insert($1) }
        }

        func getCachedImageURL(for windowId: UUID? = nil, extension ext: String? = nil, itemToken: String? = nil) -> URL? {
            getCachedContentURL(kind: "image", for: windowId, extension: ext, itemToken: itemToken)
        }

        /// 主体抠图的派生缓存路径（`cached_subject_<窗口UUID>.png`）。
        /// 按窗口 UUID 命名，历史删除时随记录一起清理；重开同一历史复用同一路径。
        func imageSubjectCacheURL() -> URL? {
            getCachedContentURL(kind: "subject", for: id, extension: "png")
        }

        func getCachedContentURL(kind: String, for windowId: UUID? = nil, extension ext: String? = nil, itemToken: String? = nil) -> URL? {
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    let controllers = (NSApplication.shared.delegate as? AppDelegate)?.windowControllers ?? []
                    ContentCache.shared.protect(Set(controllers.map { $0.appState.id }).union([windowId ?? id]), paths: Set(controllers.flatMap { $0.appState.cachedContentPaths }))
                }
            }
            guard let foofoilURL = AppState.getFoofoilDirectoryURL() else {
                return nil
            }
            if !FileManager.default.fileExists(atPath: foofoilURL.path) {
                try? FileManager.default.createDirectory(at: foofoilURL, withIntermediateDirectories: true, attributes: nil)
            }
            let targetId = windowId ?? self.id
            var filename = "cached_\(kind)_\(targetId.uuidString)"
            if let itemToken, !itemToken.isEmpty {
                let token = itemToken.replacingOccurrences(of: "/", with: "-")
                filename += "_\(token)"
            }
            if let ext = ext, !ext.isEmpty {
                return foofoilURL.appendingPathComponent("\(filename).\(ext)", isDirectory: false)
            } else {
                return foofoilURL.appendingPathComponent(filename, isDirectory: false)
            }
        }

        /// 缓存文件名包含窗口 UUID，不能用于识别重复来源；这里保留规范化后的原文件路径。
        static func localSourceFingerprint(for url: URL) -> String? {
            guard url.isFileURL, !isManagedCacheURL(url) else { return nil }
            return "file:\(url.resolvingSymlinksInPath().standardizedFileURL.path)"
        }

        func clearCachedImages() {
            guard let root = Self.getFoofoilDirectoryURL(),
                  let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
            ContentCache.shared.retire(Set(files.filter { $0.lastPathComponent.hasPrefix("cached_image_\(id.uuidString)") }.map(\.path)))
        }

        public func createNewFoofoilFromScreenshot(image: NSImage, backingScaleFactor: CGFloat) {
            let webTitle = self.originalImageName ?? NSLocalizedString("Untitled Page", comment: "")
            let formattedTitle = String(format: NSLocalizedString("Web Screenshot: %@", comment: ""), webTitle)

            let newId = UUID()
            guard let destURL = self.managedBodyURL(extension: "png") else { return }
            ownedBodyPaths.remove(destURL.path)
            ContentCache.shared.retain([destURL.path])

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    ContentCache.shared.release([destURL.path]); ContentCache.shared.retire([destURL.path]); return
                }
                if let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]),
                   (try? ContentCache.shared.write(png, to: destURL)) != nil {
                    DispatchQueue.main.async {
                        defer { ContentCache.shared.release([destURL.path]); ContentCache.shared.retire([destURL.path]) }
                        NotificationCenter.default.post(
                            name: .createNewFoofoilFromImage,
                            object: nil,
                            userInfo: [
                                "id": newId,
                                "imageURL": destURL,
                                "originalName": formattedTitle,
                                "isIncognito": self.isIncognito
                            ]
                        )
                    }
                } else {
                    ContentCache.shared.release([destURL.path])
                    ContentCache.shared.retire([destURL.path])
                    print("Failed to save screenshot")
                }
            }
        }

        public func loadImage(from url: URL) -> NSImage? {
            guard !isQuickLookDocument else { return nil }
            if let cached = loadedImageCache, cached.url == url {
                return cached.image
            }

            guard let image = NSImage(contentsOf: url) else { return nil }

            if url.pathExtension.lowercased() == "heic",
               url.lastPathComponent.hasPrefix("cached_image_") {
                if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {

                    var dpi: Double = 72.0
                    if let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
                       let xRes = tiffDict[kCGImagePropertyTIFFXResolution] as? Double {
                        dpi = xRes
                    } else if let dpiWidth = properties[kCGImagePropertyDPIWidth] as? Double {
                        dpi = dpiWidth
                    }

                    let scale = dpi / 72.0
                    if scale > 0 {
                        if let rep = image.representations.first {
                            let pixelWidth = rep.pixelsWide
                            let pixelHeight = rep.pixelsHigh
                            if pixelWidth > 0 && pixelHeight > 0 {
                                image.size = NSSize(
                                    width: CGFloat(pixelWidth) / CGFloat(scale),
                                    height: CGFloat(pixelHeight) / CGFloat(scale)
                                )
                            }
                        }
                    }
                }
            }
            loadedImageCache = (url, image)
            return image
        }

}
