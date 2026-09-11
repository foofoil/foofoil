//  AppState+ContentOpen.swift
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
import FoofoilExtensionKit


extension AppState {
        public func openImage(url: URL) {
            applyImage(url: url, originalName: url.lastPathComponent, rotatesIdentity: true, clearsFileList: true)
        }

        func applyImage(
            url: URL,
            originalName: String,
            rotatesIdentity: Bool,
            clearsFileList: Bool,
            cacheToken: String? = nil
        ) {
            isBatchUpdating = true
            defer {
                isBatchUpdating = false
                saveState()
            }
            if rotatesIdentity, hasOpenedContent {
                self.id = UUID()
            }
            if clearsFileList {
                resetFileList()
                clearCustomCover()
            }
            self.originalImageName = originalName
            self.sourceFingerprint = fileList == nil ? Self.localSourceFingerprint(for: url) : nil
            self.imageSource = nil
            // 列表内切项保留边框；新打开图片仍默认无边框。
            if clearsFileList || imageURL == nil {
                self.showBorder = false
            }
            self.createdAt = Date()
            self.webURL = nil
            self.actualWebURL = nil
            if let cachedURL = cacheImage(from: url, itemToken: cacheToken) {
                self.imageURL = cachedURL
            } else {
                self.imageURL = url
            }
        }

        /// 打开本地视频；与图片不同，视频不复制到缓存目录，仅记录原始路径。
        public func openVideo(url: URL) {
            openExternalMedia(url: url, holdsSecurityAccess: false)
        }

        /// 打开本地音频；与视频相同，不复制到缓存目录，仅记录原始路径。
        public func openAudio(url: URL) {
            openExternalMedia(url: url, holdsSecurityAccess: false)
        }

        /// 打开本地音视频：引用原始文件并创建安全范围书签。
        /// - Parameter holdsSecurityAccess: 调用方已对 `url` 调用过 `startAccessingSecurityScopedResource` 且交由本窗口持有。
        func openExternalMedia(url: URL, holdsSecurityAccess: Bool) {
            applyExternalMedia(url: url, holdsSecurityAccess: holdsSecurityAccess, rotatesIdentity: true, clearsFileList: true)
        }

        func applyExternalMedia(
            url: URL,
            holdsSecurityAccess: Bool,
            rotatesIdentity: Bool,
            clearsFileList: Bool,
            originalName: String? = nil
        ) {
            isBatchUpdating = true
            defer {
                isBatchUpdating = false
                saveState()
            }
            if rotatesIdentity, hasOpenedContent {
                self.id = UUID()
            }
            if clearsFileList {
                resetFileList()
                clearCustomCover()
            }
            // 同一 FLAC 上切 CUE 曲目时文件仍在播放；撤掉沙盒访问会让无缝衔接读盘失败。
            let isSameMediaFile = imageURL.map {
                $0.standardizedFileURL.path == url.standardizedFileURL.path
            } ?? false
            if !isSameMediaFile {
                stopVideoAccess()
            }
            if let item = fileList?.currentItem, item.cue != nil {
                beginCueRelatedAccess(for: item)
            }
            self.originalImageName = originalName ?? url.lastPathComponent
            self.sourceFingerprint = fileList == nil ? Self.localSourceFingerprint(for: url) : nil
            self.imageSource = nil
            if clearsFileList || imageURL == nil {
                self.showBorder = false
            }
            // 列表内切曲保留当前缩放，由窗口按新封面比例重算（与图片列表切图一致）；
            // 新打开媒体才恢复默认缩放。
            if clearsFileList {
                self.imageScale = 1.0
            }
            if clearsFileList {
                // 新打开的媒体恢复默认顺序循环；列表内切项保留用户选择
                self.mediaPlaybackMode = .sequentialLoop
            }
            self.createdAt = Date()
            self.webURL = nil
            self.actualWebURL = nil
            // 窗口打开期间保持沙盒访问，同目录封面才能作为关联项读取
            if !isSameMediaFile || accessingVideoURL == nil {
                if holdsSecurityAccess {
                    accessingVideoURL = url
                } else if url.startAccessingSecurityScopedResource() {
                    accessingVideoURL = url
                }
            }
            // 创建安全范围书签，保证 app 重启后仍能访问原始文件
            self.videoBookmarkData = Self.makeSecurityScopedBookmark(for: url)
            if var list = fileList, let index = list.items.firstIndex(where: { $0.id == list.currentID }) {
                list.items[index].path = url.path
                list.items[index].bookmark = videoBookmarkData
                fileList = list
            }
            self.imageURL = url
        }

        /// 停止当前媒体文件的安全范围访问授权。
        func stopVideoAccess() {
            accessingVideoURL?.stopAccessingSecurityScopedResource()
            accessingVideoURL = nil
            accessingCueURL?.stopAccessingSecurityScopedResource()
            accessingCueURL = nil
            if let directoryURL = accessingSidecarDirectoryURL {
                directoryURL.stopAccessingSecurityScopedResource()
                accessingSidecarDirectoryURL = nil
            }
            if let presenter = cueRelatedPresenter {
                NSFileCoordinator.removeFilePresenter(presenter)
                cueRelatedPresenter = nil
            }
        }

        /// 从历史配置恢复视频文件的沙盒访问：优先解析安全范围书签重新授权；
        /// 书签缺失或失效时，进程内仍有授权（如拖入后未重启）则直接使用原始路径。
        /// 返回 (播放 URL, 应持久化的书签, 已持有授权的 URL)；无法访问时返回 nil。
        static func restoreVideoAccess(config: WindowConfig, fallbackURL: URL) -> (url: URL, bookmark: Data?, accessedURL: URL?)? {
            if let bookmark = config.videoBookmark {
                var isStale = false
                if let url = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    bookmarkDataIsStale: &isStale
                ) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    if FileManager.default.fileExists(atPath: url.path) {
                        // 书签过期（如文件被移动）时按解析出的新位置重建并持久化
                        let newBookmark = isStale ? Self.makeSecurityScopedBookmark(for: url) : bookmark
                        return (url, newBookmark, accessed ? url : nil)
                    }
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
            }
            guard FileManager.default.fileExists(atPath: fallbackURL.path) else { return nil }
            return (fallbackURL, Self.makeSecurityScopedBookmark(for: fallbackURL), nil)
        }

        /// 解析音频同目录封面文件夹的安全范围书签并校验文件夹仍存在。
        /// 返回 (目录 URL, 书签过期时需持久化的新书签, 是否已持有授权)；无法访问时返回 nil。
        static func restoreSidecarCoverAccess(bookmark: Data) -> (directory: URL, refreshedBookmark: Data?, accessed: Bool)? {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { return nil }
            let accessed = url.startAccessingSecurityScopedResource()
            guard FileManager.default.fileExists(atPath: url.path) else {
                if accessed { url.stopAccessingSecurityScopedResource() }
                return nil
            }
            // 书签过期（如文件夹被移动）时按解析出的新位置重建
            let refreshed = isStale ? Self.makeSecurityScopedBookmark(for: url) : nil
            return (url, refreshed, accessed)
        }

        /// 音频会话内成功读取同目录封面后保存其所在文件夹的书签，重启后无需再次授权即可显示封面。
        func recordSidecarCoverAccess(for audioURL: URL) {
            let directory = audioURL.deletingLastPathComponent()
            let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
            if let existing = accessingSidecarDirectoryURL,
               existing.resolvingSymlinksInPath().standardizedFileURL.path == directoryPath {
                return
            }
            // 只有当前能读取该目录（如拖入整个文件夹的会话）时才可能创建书签
            guard let bookmark = Self.makeSecurityScopedBookmark(for: directory) else { return }
            mediaSidecarBookmarkData = bookmark
            saveState()
        }

        /// 音频无内嵌封面且所在目录未获沙盒授权时，向用户请求文件夹访问权限以载入同目录封面。
        /// 返回调用方是否需要重读元数据：弹面板获授权，或经书签恢复授权后目录已可读，都返回 true；
        /// 目录本来就可读则返回 false（首次读取已带授权，无需重读）。
        /// 取消会记住该目录，避免同一文件夹反复打扰。
        func requestSidecarCoverAccessIfNeeded(for audioURL: URL) async -> Bool {
            let directory = audioURL.deletingLastPathComponent()
            // 目录已可读（已持有授权、无需授权或确实没有封面文件）时不必请求
            guard !AudioMetadataLoader.isCoverDirectoryAccessible(for: audioURL) else { return false }
            // 已保存书签但尚未持有授权（如切换内容后释放）时先重新激活，避免重复打扰；
            // 恢复后目录可读，调用方重读一次即可拿到同目录封面。
            if accessingSidecarDirectoryURL == nil,
               let bookmark = mediaSidecarBookmarkData,
               let sidecar = Self.restoreSidecarCoverAccess(bookmark: bookmark) {
                if sidecar.accessed { accessingSidecarDirectoryURL = sidecar.directory }
                if let refreshed = sidecar.refreshedBookmark { mediaSidecarBookmarkData = refreshed }
                if AudioMetadataLoader.isCoverDirectoryAccessible(for: audioURL) { return true }
            }
            guard !Self.hasDeclinedSidecarCoverAccess(for: directory) else { return false }

            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = directory
            panel.message = String(
                format: NSLocalizedString("Audio Cover Access Message Format", comment: ""),
                directory.lastPathComponent
            )
            panel.prompt = NSLocalizedString("Grant Access", comment: "")

            NSApp.activate(ignoringOtherApps: true)
            let granted: Bool = await withCheckedContinuation { continuation in
                if let window = Self.hostWindow(for: self) {
                    panel.beginSheetModal(for: window) { response in
                        continuation.resume(returning: response == .OK)
                    }
                } else {
                    continuation.resume(returning: panel.runModal() == .OK)
                }
            }
            guard granted, let chosen = panel.urls.first else {
                Self.recordSidecarCoverAccessDecline(for: directory)
                return false
            }
            if chosen.startAccessingSecurityScopedResource() {
                accessingSidecarDirectoryURL = chosen
            }
            mediaSidecarBookmarkData = Self.makeSecurityScopedBookmark(for: chosen)
            saveState()
            return true
        }

        /// 音频封面经用户授权后变为可用：通知窗口按封面重新适配尺寸，并强制重建历史缩略图。
        func sidecarCoverDidBecomeAvailable() {
            refreshAudioCoverPresentation()
        }

        /// 当前箔片是否已有可展示的封面（用户替换的封面或视图已读到的封面）。
        var hasDisplayedAudioCover: Bool {
            customCoverImage != nil || displayedArtwork != nil
        }

        /// 用户拖入替换后缓存的封面图；文件缺失时视为没有自定义封面。
        var customCoverImage: NSImage? {
            guard let url = customCoverURL, FileManager.default.fileExists(atPath: url.path),
                  let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
                return nil
            }
            return image
        }

        func restoreCustomCover(from config: WindowConfig) {
            guard let path = config.customCoverPath, FileManager.default.fileExists(atPath: path) else {
                customCoverURL = nil
                displayedArtwork = nil
                return
            }
            let url = URL(fileURLWithPath: path)
            customCoverURL = url
            displayedArtwork = NSImage(contentsOf: url)
        }

        func clearCustomCover() {
            customCoverURL = nil
            displayedArtwork = nil
        }

        /// 元数据封面之上叠加用户拖入的封面，并记下当前展示图供下次拖入时判断是否询问替换。
        func overlayCustomCover(_ info: AudioTrackInfo) -> AudioTrackInfo {
            var result = info
            if let image = customCoverImage {
                result.artwork = image
                result.sidecarCoverURL = nil
            }
            displayedArtwork = result.artwork
            return result
        }

        /// 将图片文件作为当前音频箔的封面。已有封面时默认询问是否替换；测试可传入 `replacingExisting` 跳过对话框。
        @discardableResult
        func applyAudioCover(from url: URL, replacingExisting: Bool? = nil) -> Bool {
            guard isAudioDocument else { return false }
            guard FileListGrouper.classify(url: url) == .listable(.image) else { return false }
            if hasDisplayedAudioCover {
                let shouldReplace = replacingExisting ?? confirmReplaceAudioCover()
                guard shouldReplace else { return false }
            }
            return installCustomCover(from: url)
        }

        /// 音频箔收到拖入文件时，把其中的图片当作封面并从未处理列表中去掉。
        func consumeDroppedImagesAsAudioCover(from urls: [URL]) -> [URL] {
            guard isAudioDocument else { return urls }
            let images = urls.filter { FileListGrouper.classify(url: $0) == .listable(.image) }
            guard let image = images.first else { return urls }
            _ = applyAudioCover(from: image)
            let imagePaths = Set(images.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
            return urls.filter {
                !imagePaths.contains($0.resolvingSymlinksInPath().standardizedFileURL.path)
            }
        }

        private func installCustomCover(from sourceURL: URL) -> Bool {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
            removeCachedCoverFiles(for: id)
            let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
            guard let destination = getCachedContentURL(kind: "cover", extension: ext) else { return false }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            } catch {
                return false
            }
            guard let image = NSImage(contentsOf: destination),
                  image.size.width > 0, image.size.height > 0 else { return false }
            customCoverURL = destination
            displayedArtwork = image
            persistDisplayedArtworkForHistory(image, force: true)
            saveState()
            let size = AudioMetadataLoader.layoutSize(image) ?? image.size
            refreshAudioCoverPresentation(contentSize: size, preserveDisplayArea: true)
            return true
        }

        private func confirmReplaceAudioCover() -> Bool {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Replace Audio Cover Title", comment: "")
            alert.informativeText = NSLocalizedString("Replace Audio Cover Message", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Replace Cover", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            alert.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertFirstButtonReturn
        }

        private func refreshAudioCoverPresentation(
            contentSize: NSSize? = nil,
            preserveDisplayArea: Bool = false
        ) {
            var userInfo: [AnyHashable: Any] = ["id": id]
            if let contentSize, contentSize.width > 0, contentSize.height > 0 {
                userInfo["size"] = contentSize
            }
            if preserveDisplayArea {
                userInfo["preserveDisplayArea"] = true
            }
            NotificationCenter.default.post(
                name: .mediaPresentationSizeDidChange,
                object: nil,
                userInfo: userInfo
            )
            ContentIndexCoordinator.shared.schedule(config: toConfig(), force: true)
        }

        private func removeCachedCoverFiles(for windowId: UUID) {
            guard let directory = AppState.getFoofoilDirectoryURL() else { return }
            let prefix = "cached_cover_\(windowId.uuidString)"
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { return }
            for file in files where file.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        private static func hostWindow(for state: AppState) -> NSWindow? {
            NSApp.windows.first { ($0.windowController as? FloatingWindowController)?.appState === state }
        }

        private static let sidecarCoverDeclineKeyPrefix = "sidecarCoverAccessDeclined."

        private static func sidecarCoverDeclineKey(for directory: URL) -> String {
            sidecarCoverDeclineKeyPrefix + directory.resolvingSymlinksInPath().standardizedFileURL.path
        }

        static func hasDeclinedSidecarCoverAccess(for directory: URL) -> Bool {
            UserDefaults.standard.object(forKey: sidecarCoverDeclineKey(for: directory)) != nil
        }

        static func recordSidecarCoverAccessDecline(for directory: URL) {
            UserDefaults.standard.set(true, forKey: sidecarCoverDeclineKey(for: directory))
        }

        /// UTType 对音视频的声明较宽（MKV/AVI 等也归为 movie），需再确认 macOS 原生可播放后才打开。
        /// - Parameter holdsSecurityAccess: 已对 `url` 取得安全范围访问；不可播放时由本方法释放，可播放时转交窗口持有。
        func openExternalMediaIfPlayable(url: URL, holdsSecurityAccess: Bool = false) {
            let asset = AVURLAsset(url: url)
            let routeGeneration = currentMediaRouteGeneration
            Task { @MainActor [weak self] in
                let isPlayable = (try? await asset.load(.isPlayable)) ?? false
                guard isPlayable, let self else {
                    if holdsSecurityAccess { url.stopAccessingSecurityScopedResource() }
                    return
                }
                if let closeTask = self.extensionSessionCloseTask {
                    _ = await closeTask.value
                }
                guard self.currentMediaRouteGeneration == routeGeneration else {
                    if holdsSecurityAccess { url.stopAccessingSecurityScopedResource() }
                    return
                }
                self.openExternalMedia(url: url, holdsSecurityAccess: holdsSecurityAccess)
            }
        }

        public func openWeb(url: URL) {
            resetFileList()
            let targetID = (imageURL != nil || webURL != nil || textURL != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ? UUID()
                : id
            let cachedURL: URL
            if url.isFileURL {
                guard let copiedURL = cacheImportedFile(from: url, kind: "web", for: targetID) else { return }
                cachedURL = copiedURL
            } else {
                // 远程网页以 URL 为内容来源，不属于本地文件缓存。
                cachedURL = url
            }

            isBatchUpdating = true
            defer {
                isBatchUpdating = false
                saveState()
            }
            self.id = targetID
            self.sourceFingerprint = Self.localSourceFingerprint(for: url)
            self.originalImageName = url.lastPathComponent
            self.imageSource = nil
            self.showBorder = true
            self.imageScale = 1.0
            self.createdAt = Date()
            self.imageURL = nil
            self.webURL = cachedURL
            self.actualWebURL = nil
        }

        static func readTextContent(from url: URL) throws -> String {
            // 1. 尝试以系统的自动编码探测读取
            var usedEncoding: String.Encoding = .utf8
            if let content = try? String(contentsOf: url, usedEncoding: &usedEncoding) {
                return content
            }

            // 2. 尝试显式以 UTF-8 读取
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }

            // 3. 尝试以 GBK / GB18030 读取
            let gbkEncodingValue = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            let gbkEncoding = String.Encoding(rawValue: gbkEncodingValue)
            if let content = try? String(contentsOf: url, encoding: gbkEncoding) {
                return content
            }

            // 4. 尝试以 UTF-16 读取
            if let content = try? String(contentsOf: url, encoding: .utf16) {
                return content
            }

            // 5. 尝试以 Windows CP1252 / ASCII 读取
            if let content = try? String(contentsOf: url, encoding: .ascii) {
                return content
            }
            if let content = try? String(contentsOf: url, encoding: .windowsCP1252) {
                return content
            }

            // 兜底：如果都失败，抛出最后的异常（用 utf8 读取抛出的错误，这样至少有报错堆栈）
            return try String(contentsOf: url, encoding: .utf8)
        }

        public func openTextFile(url: URL) {
            resetFileList()
            let targetID = (imageURL != nil || webURL != nil || textURL != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ? UUID()
                : id
            guard let cachedURL = cacheImportedFile(from: url, kind: "text", for: targetID) else { return }

            isBatchUpdating = true
            defer {
                isBatchUpdating = false
                saveState()
            }

            do {
                let content = try Self.readTextContent(from: cachedURL)
                self.id = targetID
                self.sourceFingerprint = Self.localSourceFingerprint(for: url)
                self.text = content
                self.textURL = cachedURL
                self.originalImageName = url.lastPathComponent
                self.imageSource = nil
                self.imageURL = nil
                self.webURL = nil
                self.actualWebURL = nil
                self.showBorder = true
                let ext = url.pathExtension.lowercased()
                if ext == "md" || ext == "markdown" {
                    self.isMarkdownPreview = true
                } else {
                    self.isMarkdownPreview = false
                }
                self.createdAt = Date()
            } catch {
                print("Failed to read text file: \(error)")
            }
        }

        func isTextFile(url: URL) -> Bool {
            let ext = url.pathExtension.lowercased()
            if FileListGrouper.isCueFile(url) {
                return false
            }
            let webExtensions = ["html", "htm", "webarchive", "xhtml"]
            if webExtensions.contains(ext) {
                return false
            }

            let textExtensions = ["txt", "md", "markdown", "csv", "json", "xml", "yaml", "yml", "ini", "conf", "plist", "log", "swift", "py", "js", "ts", "sh", "css", "php", "c", "cpp", "h", "java", "go", "rs", "sql", "rb"]
            if textExtensions.contains(ext) {
                return true
            }

            if let type = UTType(filenameExtension: ext) {
                if ext == "svg" || type.conforms(to: .svg) {
                    return false
                }
                return type.conforms(to: .text)
            }
            return false
        }

        /// 判断本应用能否按内容打开本地文件，避免将未知文件的 Finder 图标当成图片。
        public func canOpenFile(url: URL) -> Bool {
            guard url.isFileURL else { return false }

            if ExtensionHost.shared.canOpen(url: url) { return true }

            if FileListGrouper.isCueFile(url) {
                return true
            }

            let ext = url.pathExtension.lowercased()
            if ["html", "htm", "webarchive", "xhtml"].contains(ext) || isTextFile(url: url) {
                return true
            }
            if Self.isExternalMediaFile(url: url) {
                return true
            }
            if NSImage(contentsOf: url) != nil {
                return true
            }
            return ExtensionHost.shared.manager.availableExtension(for: url) != nil
        }

        public func openFile(url: URL) {
            guard canOpenFile(url: url) else { return }
            currentMediaRouteGeneration &+= 1

            if FileListGrouper.isCueFile(url) {
                installCueSheets(urls: [url], preservesIdentity: false)
                return
            }

            resetFileList()

            if ExtensionHost.shared.canOpen(url: url) {
                openUsingExtension(url: url)
                return
            }

            extensionSession = nil
            extensionFallbackProviderID = nil
            extensionStateReference = nil

            let ext = url.pathExtension.lowercased()
            if ["html", "htm", "webarchive", "xhtml"].contains(ext) {
                openWeb(url: url)
            } else if isTextFile(url: url) {
                openTextFile(url: url)
            } else if Self.isExternalMediaFile(url: url) {
                let accessed = url.startAccessingSecurityScopedResource()
                openExternalMediaIfPlayable(url: url, holdsSecurityAccess: accessed)
            } else if NSImage(contentsOf: url) != nil {
                openImage(url: url)
            } else if let available = ExtensionHost.shared.manager.availableExtension(for: url) {
                promptToInstall(available, opening: url)
            }
        }

        func openUsingExtension(url: URL) {
            openUsingExtension(urls: [url])
        }

        /// 两个会话是否竞争同一显式独占设备；系统默认/未选设备不构成冲突。
        nonisolated static func sharesExclusiveDevice(_ lhs: ContentSession, _ rhs: ContentSession) -> Bool {
            guard let deviceID = lhs.audioDeviceSelection?.selectedDeviceID else { return false }
            return deviceID == rhs.audioDeviceSelection?.selectedDeviceID
        }

        func openUsingExtension(urls: [URL]) {
            guard let url = urls.first else { return }
            currentMediaRouteGeneration &+= 1
            let routeGeneration = currentMediaRouteGeneration
            let targetID = (imageURL != nil || webURL != nil || textURL != nil || extensionSession != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ? UUID()
                : id
            isLoading = true
            let previousSession = extensionSession
            extensionSession = nil
            extensionFallbackProviderID = nil
            extensionStateReference = nil
            let closeTask = extensionSessionCloseTask
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.isLoading = false }
                do {
                    let closeResult = await closeTask?.value
                    guard self.currentMediaRouteGeneration == routeGeneration else { return }
                    let outcome = try await (urls.count == 1
                        ? ExtensionHost.shared.open(url: url)
                        : ExtensionHost.shared.open(urls: urls))
                    guard self.currentMediaRouteGeneration == routeGeneration else {
                        ExtensionHost.shared.closeSession(outcome.session)
                        return
                    }
                    if case .failure(let error) = closeResult,
                       let previousSession,
                       Self.sharesExclusiveDevice(previousSession, outcome.session) {
                        // 旧会话释放失败且新会话竞争同一独占设备：不安装新会话，保留待释放记录并提示。
                        ExtensionHost.shared.closeSession(outcome.session)
                        self.extensionHandoffFailureMessage = error.localizedDescription
                        return
                    }
                    if outcome.session.providerID == "builtin.audio" {
                        self.isLoading = false
                        let accessed = url.startAccessingSecurityScopedResource()
                        self.openExternalMediaIfPlayable(url: url, holdsSecurityAccess: accessed)
                        return
                    }
                    self.isBatchUpdating = true
                    self.id = targetID
                    self.stopVideoAccess()
                    self.imageURL = nil
                    self.webURL = nil
                    self.actualWebURL = nil
                    self.textURL = nil
                    self.text = ""
                    self.originalImageName = url.lastPathComponent
                    self.sourceFingerprint = Self.localSourceFingerprint(for: url)
                    self.extensionSession = outcome.session
                    self.extensionFallbackProviderID = outcome.failures.first?.providerID
                    self.stampHostListWithExtensionQueueIDs(outcome.session)
                    self.holdExtensionAudioFileAccess(for: outcome.session)
                    self.extensionStateReference = nil
                    self.installExtensionContainerListIfNeeded(
                        url: url,
                        session: outcome.session,
                        preferredItemID: nil
                    )
                    self.stampHostListWithExtensionQueueIDs(outcome.session)
                    if let extensionID = outcome.session.extensionID {
                        let payload = try JSONEncoder().encode(outcome.session)
                        self.extensionStateReference = try ExtensionHost.shared.stateStore.save(
                            extensionID: extensionID,
                            schemaVersion: 1,
                            payload: payload,
                            reference: outcome.session.id.uuidString.lowercased()
                        )
                    }
                    self.isBatchUpdating = false
                    self.saveState()
                } catch {
                    self.isBatchUpdating = false
                    NSLog("Extension session failed: \(error.localizedDescription)")
                }
            }
        }

        /// 扩展音频不占用 imageURL；为当前曲目持有文件授权，否则视图的元数据/内嵌封面
        /// 读取在重启后因沙盒不可达而失败（播放不受影响，引擎持有已打开的文件句柄）。
        /// 跟随实际播出的队列项切换授权，不碰同目录授权。
        func holdExtensionAudioFileAccess(for session: ContentSession) {
            guard let resource = ExtensionPlaybackSupport.authorizedResource(in: session, fileList: fileList) else { return }
            let url: URL
            if let bookmark = resource.securityScopedBookmark, !bookmark.isEmpty {
                var stale = false
                url = (try? URL(
                    resolvingBookmarkData: bookmark,
                    options: .withSecurityScope,
                    bookmarkDataIsStale: &stale
                )) ?? resource.url
            } else {
                url = resource.url
            }
            accessingVideoURL?.stopAccessingSecurityScopedResource()
            accessingVideoURL = nil
            if url.startAccessingSecurityScopedResource() {
                accessingVideoURL = url
            }
        }

        /// 视图已展示的封面落盘为历史缩略图。无 imagePath 的扩展音频不走后台索引，
        /// 这里是它们唯一的缩略图来源；已有缩略图时不再重复写入，除非强制覆盖。
        func persistDisplayedArtworkForHistory(_ image: NSImage?, force: Bool = false) {
            guard let image else { return }
            let destination = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("foofoil", isDirectory: true)
                .appendingPathComponent("Thumbnails", isDirectory: true)
                .appendingPathComponent("\(id.uuidString).heic")
            if FileManager.default.fileExists(atPath: destination.path) {
                guard force else { return }
                try? FileManager.default.removeItem(at: destination)
            }
            guard HistoryThumbnailGenerator.writeDisplayedArtwork(image, historyID: id) != nil else { return }
            HistoryRepository.shared.updateThumbnailPath(id: id, path: destination.path)
            HistoryManager.shared.refresh()
        }

        /// 历史记录中的值类型快照不代表 Runtime 会话仍存活；使用原始请求（含书签）建立新会话。
        func rebuildExternalExtensionSession(
            from savedSession: ContentSession,
            stateReference: String,
            expectedStateID: UUID
        ) {
            guard let sourceURL = savedSession.request.primaryFileURL else { return }
            currentMediaRouteGeneration &+= 1
            let routeGeneration = currentMediaRouteGeneration
            isLoading = true
            extensionFallbackProviderID = nil
            let closeTask = extensionSessionCloseTask

            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.currentMediaRouteGeneration == routeGeneration {
                        self.isLoading = false
                    }
                }
                do {
                    let closeResult = await closeTask?.value
                    guard self.id == expectedStateID,
                          self.currentMediaRouteGeneration == routeGeneration else { return }
                    let outcome = try await ExtensionHost.shared.open(request: savedSession.request)
                    if case .failure(let error) = closeResult,
                       Self.sharesExclusiveDevice(savedSession, outcome.session) {
                        // 旧会话释放失败且恢复目标竞争同一独占设备：不恢复播放，保留待释放记录并提示。
                        ExtensionHost.shared.closeSession(outcome.session)
                        self.extensionHandoffFailureMessage = error.localizedDescription
                        return
                    }
                    var restoredSession = outcome.session
                    do {
                        restoredSession = try await ExtensionHost.shared.restorePlayback(
                            from: savedSession, in: outcome.session
                        )
                    } catch {
                        try? await ExtensionHost.shared.closeSessionAndWait(outcome.session)
                        throw error
                    }
                    guard self.id == expectedStateID,
                          self.currentMediaRouteGeneration == routeGeneration else {
                        ExtensionHost.shared.closeSession(outcome.session)
                        return
                    }

                    self.isBatchUpdating = true
                    self.stopVideoAccess()
                    self.imageURL = nil
                    self.webURL = nil
                    self.actualWebURL = nil
                    self.textURL = nil
                    self.text = ""
                    self.originalImageName = sourceURL.lastPathComponent
                    self.sourceFingerprint = self.fileList == nil
                        ? Self.localSourceFingerprint(for: sourceURL)
                        : nil
                    self.noteUserPausedMediaPlayback()
                    self.extensionSession = restoredSession
                    self.extensionFallbackProviderID = outcome.failures.first?.providerID
                    self.stampHostListWithExtensionQueueIDs(restoredSession)
                    self.holdExtensionAudioFileAccess(for: restoredSession)
                    self.installExtensionContainerListIfNeeded(
                        url: sourceURL,
                        session: restoredSession,
                        preferredItemID: self.fileList?.currentID
                    )
                    self.stampHostListWithExtensionQueueIDs(restoredSession)
                    if let extensionID = restoredSession.extensionID {
                        let payload = try JSONEncoder().encode(restoredSession)
                        self.extensionStateReference = try ExtensionHost.shared.stateStore.save(
                            extensionID: extensionID,
                            schemaVersion: 1,
                            payload: payload,
                            reference: stateReference
                        )
                    }
                    self.isBatchUpdating = false
                    self.saveState()
                } catch {
                    guard self.id == expectedStateID,
                          self.currentMediaRouteGeneration == routeGeneration else { return }
                    self.isBatchUpdating = false
                    self.extensionSession = self.unavailableExtensionSession(
                        extensionID: savedSession.extensionID ?? "unavailable",
                        reference: stateReference
                    )
                    NSLog("Extension session restore failed: \(error.localizedDescription)")
                }
            }
        }

        /// 宿主持有列表与播放模式；连续 DSD 文件共享扩展会话以提前填充 DoP。
        func openFileListAudioUsingExtension(url: URL, itemID: String) {
            currentMediaRouteGeneration &+= 1
            let routeGeneration = currentMediaRouteGeneration
            let previousSession = extensionSession
            extensionSession = nil
            extensionFallbackProviderID = nil
            extensionStateReference = nil
            stopVideoAccess()
            imageURL = nil
            originalImageName = url.lastPathComponent
            sourceFingerprint = nil
            isLoading = true
            let closeTask = extensionSessionCloseTask

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let closeResult = await closeTask?.value
                    guard self.currentMediaRouteGeneration == routeGeneration,
                          self.fileList?.currentID == itemID else { return }
                    let urls = self.contiguousExtensionAudioURLs(startingAt: itemID)
                    let outcome: SessionResolutionOutcome
                    if urls.count > 1, let sequence = try? await ExtensionHost.shared.open(urls: urls) {
                        if ExtensionPlaybackSupport.acceptsGaplessCollection(sequence.session) {
                            outcome = sequence
                        } else {
                            try? await ExtensionHost.shared.closeSessionAndWait(sequence.session)
                            outcome = try await ExtensionHost.shared.open(url: url)
                        }
                    } else {
                        outcome = try await ExtensionHost.shared.open(url: url)
                    }
                    guard self.currentMediaRouteGeneration == routeGeneration,
                          self.fileList?.currentID == itemID else {
                        ExtensionHost.shared.closeSession(outcome.session)
                        return
                    }
                    if case .failure(let error) = closeResult,
                       let previousSession,
                       Self.sharesExclusiveDevice(previousSession, outcome.session) {
                        // 旧会话释放失败且新会话竞争同一独占设备：不安装新会话，保留待释放记录并提示。
                        ExtensionHost.shared.closeSession(outcome.session)
                        self.extensionHandoffFailureMessage = error.localizedDescription
                        self.isLoading = false
                        return
                    }
                    if outcome.session.providerID == "builtin.audio" {
                        let asset = AVURLAsset(url: url)
                        let isPlayable = (try? await asset.load(.isPlayable)) ?? false
                        guard self.currentMediaRouteGeneration == routeGeneration,
                              self.fileList?.currentID == itemID else { return }
                        self.isLoading = false
                        if isPlayable {
                            self.applyExternalMedia(
                                url: url,
                                holdsSecurityAccess: false,
                                rotatesIdentity: false,
                                clearsFileList: false
                            )
                        }
                        return
                    }
                    self.isBatchUpdating = true
                    self.originalImageName = url.lastPathComponent
                    self.sourceFingerprint = nil
                    self.extensionSession = outcome.session
                    self.extensionFallbackProviderID = outcome.failures.first?.providerID
                    self.stampHostListWithExtensionQueueIDs(outcome.session)
                    self.holdExtensionAudioFileAccess(for: outcome.session)
                    self.installExtensionContainerListIfNeeded(
                        url: url,
                        session: outcome.session,
                        preferredItemID: itemID
                    )
                    self.stampHostListWithExtensionQueueIDs(outcome.session)
                    if let extensionID = outcome.session.extensionID {
                        let payload = try JSONEncoder().encode(outcome.session)
                        self.extensionStateReference = try ExtensionHost.shared.stateStore.save(
                            extensionID: extensionID,
                            schemaVersion: 1,
                            payload: payload,
                            reference: outcome.session.id.uuidString.lowercased()
                        )
                    }
                    self.isBatchUpdating = false
                    self.isLoading = false
                    self.saveState()
                } catch {
                    guard self.currentMediaRouteGeneration == routeGeneration else { return }
                    self.isBatchUpdating = false
                    self.isLoading = false
                    NSLog("Audio provider session failed: \(error.localizedDescription)")
                }
            }
        }

        func promptToInstall(_ entry: ExtensionRegistryEntry, opening url: URL) {
            let alert = NSAlert()
            alert.messageText = String(format: NSLocalizedString("Install Extension Title Format", comment: ""), entry.name)
            alert.informativeText = String(
                format: NSLocalizedString("Install Extension Message Format", comment: ""),
                entry.name
            )
            alert.addButton(withTitle: NSLocalizedString("Install and Open", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            isLoading = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await ExtensionHost.shared.manager.install(entry.id)
                    self.openUsingExtension(url: url)
                } catch {
                    self.isLoading = false
                    let failed = NSAlert()
                    failed.messageText = NSLocalizedString("Extension Install Failed Title", comment: "")
                    failed.informativeText = error.localizedDescription
                    failed.runModal()
                }
            }
        }

        /// 作为协调器的释放回调；失败时保留会话供重试，不静默清空。
        private func pauseExtensionForExclusiveHandoff(sessionID: UUID) async throws {
            guard let session = extensionSession, session.id == sessionID else { return }
            exclusivePlaybackGeneration &+= 1
            noteUserPausedMediaPlayback()
            let updated = try await ExtensionHost.shared.perform(mediaAction: .pause, in: session)
            guard extensionSession?.id == sessionID else { return }
            extensionSession = updated
            isMediaPlaying = false
            if let extensionID = updated.extensionID, let reference = extensionStateReference {
                _ = try? ExtensionHost.shared.stateStore.save(
                    extensionID: extensionID, schemaVersion: 1,
                    payload: JSONEncoder().encode(updated), reference: reference
                )
            }
        }

        func performExtensionCommand(_ commandID: String) {
            if let session = extensionSession,
               let action = ExtensionPlaybackSupport.legacyMediaAction(for: commandID, in: session) {
                performExtensionMediaAction(action)
            } else {
                performExtensionOperation(.command(commandID))
            }
        }

        func performExtensionMediaAction(_ action: ExtensionMediaAction) {
            performExtensionOperation(.media(action))
        }

        private func performExtensionOperation(_ operation: ExtensionSessionOperation) {
            do { try operation.mediaAction?.validate() } catch {
                NSLog("Extension media action rejected: \(error.localizedDescription)")
                return
            }
            if operation.mediaAction == .pause { exclusivePlaybackGeneration &+= 1 }
            // refresh 是只读同步，不推进序号；其它动作递增序号，使过期回包在完成时被丢弃。
            if operation.mediaAction != .refresh { extensionPlaybackOperationVersion &+= 1 }
            let operationVersion = extensionPlaybackOperationVersion
            guard let currentSession = extensionSession else { return }
            let session = sessionByApplyingHostPlaybackSequence(currentSession)
            let commandGeneration = exclusivePlaybackGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let updated: ContentSession
                    let isStart = operation.mediaAction == .play
                    let isDeviceChange = operation.selectedDeviceID != nil && session.mediaPlayback?.state == .playing
                    let deviceID = isDeviceChange
                        ? operation.selectedDeviceID
                        : session.audioDeviceSelection?.selectedDeviceID
                    if ExtensionPlaybackSupport.requiresExclusiveHandoff(session), (isStart || isDeviceChange), let deviceID {
                        var result = session
                        let generation = commandGeneration
                        try await ExclusivePlaybackCoordinator.shared.perform(
                            deviceID: deviceID, ownerID: session.id,
                            pause: { [weak self] in try await self?.pauseExtensionForExclusiveHandoff(sessionID: session.id) },
                            isCurrent: { [weak self] in
                                self?.extensionSession?.id == session.id && self?.exclusivePlaybackGeneration == generation
                            },
                            start: { [weak self] in
                                guard let self, self.extensionSession?.id == session.id,
                                      self.exclusivePlaybackGeneration == generation else { throw CancellationError() }
                                if isDeviceChange {
                                    let paused = try await ExtensionHost.shared.perform(mediaAction: .pause, in: session)
                                    ExclusivePlaybackCoordinator.shared.release(ownerID: session.id)
                                    let selected = try await operation.perform(in: paused)
                                    guard self.exclusivePlaybackGeneration == generation else { throw CancellationError() }
                                    result = try await ExtensionHost.shared.perform(mediaAction: .play, in: self.sessionByApplyingHostPlaybackSequence(selected))
                                } else {
                                    result = try await operation.perform(in: session)
                                }
                            }
                        )
                        updated = result
                    } else {
                        updated = try await operation.perform(in: session)
                    }
                    guard self.extensionSession?.id == session.id,
                          self.exclusivePlaybackGeneration == commandGeneration,
                          self.extensionPlaybackOperationVersion == operationVersion else { return }
                    self.extensionSession = updated
                    self.extensionHandoffFailureMessage = nil
                    self.synchronizeFileListWithExtensionQueue(updated)
                    // 进度最多每五秒保存一次扩展快照，避免每秒写盘或刷新历史排序。
                    let persistsState = operation.mediaAction != .refresh
                    let checkpointsPlayback = Date().timeIntervalSince(self.lastExtensionPlaybackCheckpoint) >= 5
                    if persistsState || checkpointsPlayback,
                       let extensionID = updated.extensionID,
                       let reference = self.extensionStateReference {
                        let payload = try JSONEncoder().encode(updated)
                        try ExtensionHost.shared.stateStore.save(
                            extensionID: extensionID,
                            schemaVersion: 1,
                            payload: payload,
                            reference: reference
                        )
                    }
                    if persistsState || checkpointsPlayback {
                        self.lastExtensionPlaybackCheckpoint = Date()
                    }
                    if persistsState { self.saveState() }
                } catch is CancellationError {
                    // 过期/取消不是释放失败，不提示。
                } catch {
                    if case ExclusivePlaybackCoordinator.HandoffError.releaseFailed = error {
                        // 释放失败：保留旧会话/待释放记录，阻止同设备新获取并提示。
                        self.extensionHandoffFailureMessage = error.localizedDescription
                    }
                    NSLog("Extension command failed: \(error.localizedDescription)")
                    // 失败后只刷新一次扩展快照；refresh 不再触发二次刷新，结果仍受会话/序号校验。
                    if let mediaAction = operation.mediaAction, mediaAction != .refresh,
                       self.extensionSession?.id == session.id {
                        self.performExtensionMediaAction(.refresh)
                    }
                }
            }
        }

        func seekExtensionPlayback(to position: TimeInterval) {
            // 只在能力与动作都可用时发送；拖动值由 Slider 交互状态承载，成功回包后再更新会话快照。
            guard position.isFinite, position >= 0,
                  let session = extensionSession,
                  MediaPlaybackRequest.isSupported(by: session),
                  session.mediaPlayback?.isSeekable == true,
                  ExtensionPlaybackSupport.isActionAvailable(.seek, in: session) else { return }
            performExtensionMediaAction(.seek(position))
        }

        func performNavigatorAction(_ action: NavigatorAction) {
            if let contribution = builtInNavigatorContributions.first(where: {
                $0.id == action.contributionID
            }) {
                do {
                    try NavigatorContributionValidator.validate(action, in: contribution)
                    builtInNavigatorActionHandler?(action)
                } catch {
                    NSLog("Built-in navigator action failed validation: \(error.localizedDescription)")
                }
                return
            }
            if let session = extensionSession {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let updated = try await ExtensionHost.shared.perform(
                            navigatorAction: action,
                            in: self.sessionByApplyingHostPlaybackSequence(session)
                        )
                        guard self.extensionSession?.id == session.id else { return }
                        self.extensionSession = updated
                        if let extensionID = updated.extensionID,
                           let reference = self.extensionStateReference {
                            let payload = try JSONEncoder().encode(updated)
                            try ExtensionHost.shared.stateStore.save(
                                extensionID: extensionID,
                                schemaVersion: 1,
                                payload: payload,
                                reference: reference
                            )
                        }
                        self.saveState()
                    } catch {
                        NSLog("Navigator action failed: \(error.localizedDescription)")
                    }
                }
                return
            }
        }

        @discardableResult
        public func copyCurrentImageToPasteboard() -> Bool {
            guard webURL == nil,
                  let imageURL,
                  let image = NSImage(contentsOf: imageURL) else {
                return false
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.writeObjects([image])
        }

        public func saveWebScreenshot(_ image: NSImage, triggerSavePanel: Bool = false) {
            guard webURL != nil else { return }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                guard let tiffData = image.tiffRepresentation,
                      let bitmapImage = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
                    return
                }

                guard let destURL = self.getCachedImageURL(extension: "png") else { return }

                do {
                    try pngData.write(to: destURL)
                    DispatchQueue.main.async {
                        guard self.webURL != nil else { return }
                        self.imageURL = destURL

                        if triggerSavePanel {
                            NotificationCenter.default.post(
                                name: .webSnapshotReadyForSave,
                                object: nil,
                                userInfo: ["id": self.id]
                            )
                        }
                    }
                } catch {
                    print("Failed to save web screenshot: \(error)")
                }
            }
        }

        public func openImage(image: NSImage, originalName: String? = nil, imageSource: ImageSource? = nil) {
            if hasOpenedContent {
                self.id = UUID()
            }
            resetFileList()
            self.isLoading = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                guard let tiffData = image.tiffRepresentation,
                      let bitmapImage = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                    return
                }

                self.clearCachedImages()
                guard let destURL = self.getCachedImageURL(extension: "png") else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                    return
                }

                do {
                    try pngData.write(to: destURL)
                    DispatchQueue.main.async {
                        self.isBatchUpdating = true
                        self.sourceFingerprint = nil
                        self.originalImageName = originalName ?? "dropped_image.png"
                        self.imageSource = imageSource
                        self.showBorder = false
                        self.createdAt = Date()
                        self.webURL = nil
                        self.actualWebURL = nil
                        self.imageURL = destURL
                        self.isBatchUpdating = false
                        self.isLoading = false
                        self.saveState()
                    }
                } catch {
                    print("Failed to save dropped image to cache: \(error)")
                    DispatchQueue.main.async {
                        self.isLoading = false
                    }
                }
            }
        }
}
