import AppKit

/// Spotlight 命中文件的打开支撑：打开前的可读性检查、文件级安全范围转换、目录授权保持。
/// 查询本身不授予文件访问；这里只做打开前检查与授权转换，真正的装载交给 AppDelegate 的分组打开流程。
@MainActor
enum SpotlightFileOpener {
    nonisolated enum FileAccess: Sendable, Equatable { case readable, needsPermission, unavailable, notDownloaded }

    @concurrent
    static func fileAccess(_ url: URL) async -> FileAccess {
        do {
            let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if values.ubiquitousItemDownloadingStatus == .notDownloaded { return .notDownloaded }
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
            return .readable
        } catch {
            let error = error as NSError
            if (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
                || (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code)) {
                return .needsPermission
            }
            return .unavailable
        }
    }

    /// 目录授权只保证持有期间可读；转成文件级安全范围 URL 后，窗口与扩展会话各自持有授权。
    nonisolated static func fileScopedURL(for url: URL) -> URL? {
        guard let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// 释放查询或打开期间持有的目录授权；与 beginAccess 的返回数组配对使用。
    static func releaseAccess(_ scopes: [URL]) {
        scopes.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    /// 打开请求被接受后继续持有目录授权，直到目标箔片装载结束或超时，
    /// 让扩展会话与媒体探测有时间把目录授权替换成自己的文件级安全范围。
    static func holdAccessUntilSettled(_ scopes: [URL], target: AppState?) {
        guard !scopes.isEmpty else { return }
        Task { [scopes] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(target == nil ? 3 : 10))
            while ContinuousClock.now < deadline {
                if let target, !target.isLoading, target.hasOpenedContent { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            scopes.forEach { $0.stopAccessingSecurityScopedResource() }
        }
    }

    /// 复用 AppDelegate 的分组打开流程：优先空白浮箔，否则新建；返回是否已接受打开请求。
    /// 请求被接受后由本方法负责在装载期间保持授权，失败时立即释放。
    @discardableResult
    static func openInFoil(_ url: URL, access: [URL]) -> Bool {
        let scopedURL = fileScopedURL(for: url) ?? url
        guard let delegate = NSApp.delegate as? AppDelegate else {
            releaseAccess(access)
            return false
        }
        let target = delegate.availableBlankWindowController?.appState
        let knownWindows = Set(delegate.windowControllers.map(ObjectIdentifier.init))
        guard delegate.openGroupedFiles([scopedURL], into: target, append: false) else {
            releaseAccess(access)
            return false
        }
        let openedState = target ?? delegate.windowControllers.first { !knownWindows.contains(ObjectIdentifier($0)) }?.appState
        holdAccessUntilSettled(access, target: openedState)
        return true
    }
}
