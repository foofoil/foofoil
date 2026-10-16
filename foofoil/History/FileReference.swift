import Foundation

/// 定位与授权分开：只对可访问的本地卷上明确的 ENOENT 作删除判断。
nonisolated enum FileReference {
    enum Status: Equatable { case available, missing, authorizationRequired, offline, temporaryFailure }
    struct Resolution {
        var url: URL
        var bookmark: Data?
        var status: Status
    }

    static func resolve(_ fallback: URL, bookmark: Data?) -> Resolution {
        var url = fallback
        var refreshed = bookmark
        var bookmarkFailed = false
        if let bookmark {
            var stale = false
            do {
                url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if stale { refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
                return Resolution(url: url, bookmark: refreshed ?? bookmark, status: status(of: url))
            } catch {
                let error = error as NSError
                let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
                let noSuchFile = (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) || (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT))
                bookmarkFailed = !noSuchFile
            }
        }
        let status = status(of: url)
        return Resolution(url: url, bookmark: refreshed,
                          status: bookmarkFailed && status == .missing ? .temporaryFailure : status)
    }

    static func status(of url: URL) -> Status {
        guard url.isFileURL else { return .temporaryFailure }
        // 未挂载的外置卷无法与删除区分，始终保留。
        if url.path.hasPrefix("/Volumes/") {
            let parts = url.pathComponents
            if parts.count > 2, !FileManager.default.fileExists(atPath: "/Volumes/" + parts[2]) { return .offline }
        }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return FileManager.default.isReadableFile(atPath: url.path) ? .available : .authorizationRequired
        } catch {
            if AppState.isManagedCacheURL(url), ContentCache.shared.hasLease(for: url.path) { return .temporaryFailure }
            let error = error as NSError
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            let code = underlying?.domain == NSPOSIXErrorDomain ? underlying?.code : (error.domain == NSPOSIXErrorDomain ? error.code : nil)
            if code == Int(EACCES) || code == Int(EPERM) || error.code == NSFileReadNoPermissionError { return .authorizationRequired }
            guard code == Int(ENOENT) || (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError) else { return .temporaryFailure }
            // 目录无法读取时，缺失也可能只是沙盒或离线错误。
            var parent = url.deletingLastPathComponent()
            while parent.path != "/", !FileManager.default.fileExists(atPath: parent.path) { parent.deleteLastPathComponent() }
            guard FileManager.default.isReadableFile(atPath: parent.path),
                  (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) != nil else { return .authorizationRequired }
            if (try? parent.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false { return .temporaryFailure }
            return .missing
        }
    }
}

extension WindowConfig {
    nonisolated var legacyExternalBodyPaths: Set<String> {
        guard sourceFingerprint?.hasPrefix("file:") == true else { return [] }
        let paths = [imagePath, textPath, webURLString.flatMap { URL(string: $0)?.isFileURL == true ? URL(string: $0)?.path : nil }].compactMap { $0 }
        return Set(paths.filter { path in
            let url = URL(fileURLWithPath: path)
            return AppState.isManagedCacheURL(url) && ["cached_image", "cached_text_", "cached_web_"].contains { url.lastPathComponent.hasPrefix($0) }
        })
    }

    nonisolated var isClipboardContent: Bool { imageSource == .clipboard || sourceFingerprint?.hasPrefix("clipboard:") == true }

    /// 只验证正文来源；网页截图等派生文件缺失不能阻止打开其真正内容。
    func historyRestoreFileFailure() -> FileOpenFeedback? {
        guard !isCamera, appleMusicReference == nil,
              sourceFingerprint != KeyboardShortcutsOverview.sourceFingerprint,
              sourceFingerprint != SupportedContentOverview.sourceFingerprint else { return nil }
        if let value = webURLString, let url = URL(string: value), !url.isFileURL { return nil }
        let references: [(URL, Data?)]
        if let item = fileList?.currentItem {
            references = [(item.url, item.bookmark)]
        } else if let archiveSource, !archiveSource.volumes.isEmpty {
            references = archiveSource.volumes.map { (URL(fileURLWithPath: $0.path), $0.bookmark) }
        } else {
            let localWeb = webURLString.flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
            let source = sourceFingerprint.flatMap { $0.hasPrefix("file:") ? URL(fileURLWithPath: String($0.dropFirst(5))) : nil }
                ?? textPath.map(URL.init(fileURLWithPath:)) ?? localWeb ?? imagePath.map(URL.init(fileURLWithPath:))
            references = source.map { [($0, videoBookmark)] } ?? []
        }
        for (url, bookmark) in references {
            let result = FileReference.resolve(url, bookmark: AppState.isManagedCacheURL(url) ? nil : bookmark)
            if result.status != .available {
                return FileOpenFeedback(url: result.url, reason: result.status == .missing ? .missing : .unreadable)
            }
        }
        return nil
    }

    /// 外部旧快照有可靠原路径时只使用原文件，绝不回退到缓存正文。
    nonisolated func resolvingFileReferences(removeMissingItems: Bool = true) -> (config: WindowConfig, missing: Bool) {
        var config = self
        guard !isCamera, appleMusicReference == nil,
              sourceFingerprint != KeyboardShortcutsOverview.sourceFingerprint,
              sourceFingerprint != SupportedContentOverview.sourceFingerprint else { return (config, false) }
        if let value = config.webURLString, let url = URL(string: value), !url.isFileURL { return (config, false) }
        if var list = config.fileList, !list.items.isEmpty {
            let oldItems = list.items
            var missingSections: Set<String> = []
            list.sections = list.sections.map { section in
                guard !section.isFolder, let path = section.cueSheetPath else { return section }
                let resolved = FileReference.resolve(URL(fileURLWithPath: path), bookmark: section.cueSheetBookmark)
                if resolved.status == .missing { missingSections.insert(section.id) }
                var section = section
                section.cueSheetPath = resolved.url.path
                section.cueSheetBookmark = resolved.bookmark
                return section
            }
            list.items = list.items.compactMap { item in
                if let sectionID = item.resolvedSectionID, missingSections.contains(sectionID) { return nil }
                let resolved = FileReference.resolve(item.url, bookmark: item.bookmark)
                guard resolved.status != .missing else { return nil }
                var item = item
                item.path = resolved.url.path
                item.bookmark = resolved.bookmark
                return item
            }
            guard !list.items.isEmpty else { return (config, true) }
            if !list.items.contains(where: { $0.id == list.currentID }) { list.currentID = list.items[0].id }
            if !removeMissingItems, list.items.count != oldItems.count { return (config, false) }
            config.fileList = list
            if let item = list.currentItem, config.imagePath != nil { config.imagePath = item.path; config.videoBookmark = item.bookmark }
            return (config, false)
        }
        if var archive = config.archiveSource {
            var missing = false
            for index in archive.volumes.indices {
                let result = FileReference.resolve(URL(fileURLWithPath: archive.volumes[index].path), bookmark: archive.volumes[index].bookmark)
                missing = missing || result.status == .missing
                archive.volumes[index].path = result.url.path
                archive.volumes[index].bookmark = result.bookmark
            }
            config.archiveSource = archive
            config.imagePath = archive.primaryURL.path
            return (config, missing)
        }
        let webFile = config.webURLString.flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
        var source = config.textPath.map(URL.init(fileURLWithPath:)) ?? webFile ?? config.imagePath.map(URL.init(fileURLWithPath:))
        if let fingerprint = sourceFingerprint, fingerprint.hasPrefix("file:") { source = URL(fileURLWithPath: String(fingerprint.dropFirst(5))) }
        guard let source else { return (config, false) }
        let resolved = FileReference.resolve(source, bookmark: AppState.isManagedCacheURL(source) ? nil : config.videoBookmark)
        if config.textPath != nil { config.textPath = resolved.url.path }
        else if webFile != nil { config.webURLString = resolved.url.absoluteString }
        else if config.imagePath != nil { config.imagePath = resolved.url.path }
        config.videoBookmark = resolved.bookmark
        if sourceFingerprint?.hasPrefix("file:") == true { config.sourceFingerprint = "file:" + resolved.url.path }
        return (config, resolved.status == .missing)
    }
}
