import AppKit

/// Spotlight 命中文件先检查可读性，再交给 AppDelegate 的分组打开流程。
/// 系统隐私权限与索引结果独立，不额外创建主目录授权。
@MainActor
enum SpotlightFileOpener {
    nonisolated enum FileAccess: Sendable, Equatable { case readable, needsPermission, unavailable, notDownloaded }

    @concurrent
    static func fileAccess(_ url: URL) async -> FileAccess {
        do {
            let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .isDirectoryKey])
            if values.ubiquitousItemDownloadingStatus == .notDownloaded { return .notDownloaded }
            if values.isDirectory == true {
                return FileManager.default.isReadableFile(atPath: url.path) ? .readable : .needsPermission
            }
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

    /// 复用 AppDelegate 的分组打开流程：优先空白浮箔，否则新建；返回是否已接受打开请求。
    @discardableResult
    static func openInFoil(_ url: URL, isIncognito: Bool = false, target: AppState? = nil) -> Bool {
        guard let delegate = NSApp.delegate as? AppDelegate else { return false }
        let source = target.flatMap { $0.isIncognito == isIncognito && delegate.isBlank($0) ? $0 : nil }
        let state = source ?? delegate.blankWindowController(isIncognito: isIncognito)?.appState ?? AppState(isIncognito: isIncognito)
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if isDir {
            guard state.handleDroppedFileURLs([url]) else { return false }
        } else {
            guard delegate.openGroupedFiles([url], into: state, append: false) else { return false }
        }
        if let controller = delegate.windowControllers.first(where: { $0.appState === state }) {
            delegate.activateWindow(controller)
        } else { delegate.showNewWindow(with: state) }
        return true
    }
}
