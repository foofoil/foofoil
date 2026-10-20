import AppKit
import UniformTypeIdentifiers

struct FileOpenFeedback: Identifiable, Equatable {
    enum Reason: String {
        case unsupported = "File Feedback Unsupported"
        case missing = "File Feedback Missing"
        case unreadable = "File Feedback Unreadable"
        case emptyDirectory = "File Feedback Empty Directory"
        case failed = "File Feedback Failed"
        case differentType = "File Feedback Different Type"
    }
    let url: URL
    let reason: Reason
    /// 历史恢复失败时携带原记录 ID，反馈箔自身拥有独立身份。
    var historyID: UUID? = nil
    var id: String { url.path + reason.rawValue + (historyID?.uuidString ?? "") }

    @MainActor
    var canRemoveFromHistory: Bool {
        historyID.flatMap { HistoryRepository.shared.config(id: $0) } != nil
    }

    /// 用户在失效文件反馈中显式移出历史，无论是否收藏都不再确认。
    @MainActor
    func removeFromHistory() async -> Bool {
        guard let historyID else { return false }
        guard let config = HistoryRepository.shared.config(id: historyID) else { return true }
        return await HistoryManager.shared.removeFromHistory([config])
    }
}

extension AppState {
    /// 明确的失败先分流，避免污染目标箔片及其历史；未知文档仍交给系统预览判断。
    func initialFileOpenFailure(_ url: URL) -> FileOpenFeedback? {
        guard url.isFileURL else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isReadableKey])
            if values.isReadable == false { return .init(url: url, reason: .unreadable) }
            if values.isDirectory == true && values.isPackage != true { return nil }
            // 源码/脚本可能同时符合 executable；文本入口优先，不能被二进制文件过滤误拒绝。
            if isTextFile(url: url) || canUseKnownQuickLookPreview(url) || ArchiveReader.recognizes(url) { return nil }
            if let type = UTType(filenameExtension: url.pathExtension),
               ["public.archive", "public.executable", "com.apple.application-bundle", "com.apple.disk-image", "com.apple.installer-package"].contains(where: {
                   UTType($0).map { type.conforms(to: $0) } ?? false
               }) {
                if ExtensionHost.shared.canOpen(url: url) { return nil }
                return .init(url: url, reason: .unsupported)
            }
            return nil
        } catch {
            let cocoa = error as NSError
            return .init(url: url, reason: cocoa.code == NSFileReadNoSuchFileError ? .missing : .unreadable)
        }
    }

    func filterFileOpenFailures(_ urls: [URL]) -> [URL] {
        var failures: [FileOpenFeedback] = []
        let remaining = urls.filter {
            if let failure = initialFileOpenFailure($0) { failures.append(failure); return false }
            return true
        }
        reportFileOpenFeedback(failures)
        return remaining
    }

    func reportFileOpenFeedback(_ failures: [FileOpenFeedback]) {
        guard !failures.isEmpty else { return }
        if isArchivePreview { fileOpenFeedback = failures; return }
        NotificationCenter.default.post(name: .fileOpenFeedback, object: self,
            userInfo: ["failures": failures, "batchID": fileOpenFeedbackBatchID])
    }

    var isFileOpenFeedback: Bool { !fileOpenFeedback.isEmpty && !hasOpenedContent && appleMusicReference == nil }

    /// 预览能力与缩略图能力并不完全等价：已知文档直接保留预览，未知类型只在系统能生成内容缩略图时打开。
    func canUseKnownQuickLookPreview(_ url: URL) -> Bool {
        let extensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "rtfd", "odt", "ods", "odp", "epub"]
        return extensions.contains(url.pathExtension.lowercased()) || ArchiveReader.supportsPackageContents(url)
    }
}
