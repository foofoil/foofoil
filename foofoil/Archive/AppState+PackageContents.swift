import AppKit
import FoofoilExtensionKit

extension AppState {
    /// 阅读器可能使用缓存或安全范围资源，菜单必须打开实际源文件而不是预览快照。
    var packageContentsURL: URL? {
        guard archiveSession == nil else { return nil }
        var candidates: [URL] = []
        if let resource = extensionSession?.request.resources.first {
            candidates.append(resource.securityScopedBookmark.flatMap(Self.resolveVideoBookmark) ?? resource.url)
        }
        if let quickLookSourceURL { candidates.append(quickLookSourceURL) }
        if let fingerprint = sourceFingerprint, fingerprint.hasPrefix("file:") {
            candidates.append(URL(fileURLWithPath: String(fingerprint.dropFirst(5))))
        }
        candidates.append(contentsOf: [imageURL, textURL].compactMap { $0 })
        return candidates.first {
            ArchiveReader.supportsPackageContents($0) && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private var packageContentsFingerprint: String? {
        if isArchivePreview, let owner = archiveWindowOwner, let session = owner.archiveSession {
            return "archive-entry:\(owner.sourceFingerprint ?? session.source.primaryURL.path)|\(session.selectedID ?? "")"
        }
        return sourceFingerprint
    }

    /// 原包直接引用；从包内提取的文档另开后共享临时租约，不生成独立可恢复正文。
    func makePackageContentsState() async throws -> AppState? {
        guard let source = packageContentsURL else { return nil }
        let target = AppState(isIncognito: isIncognito)
        let lease = archivePreviewLease
        let displayName = originalImageName ?? source.lastPathComponent
        let fingerprint = packageContentsFingerprint
        target.openArchive(url: source, displayName: displayName, fingerprint: fingerprint,
                           sourceLease: isArchivePreview ? lease : nil)
        return target.archiveSession == nil ? nil : target
    }
}

extension AppDelegate {
    @objc func openPackageContentsAction() {
        guard let reader = activeReadingState, reader.packageContentsURL != nil else { return }
        Task { @MainActor in
            do {
                if let state = try await reader.makePackageContentsState() { showNewWindow(with: state) }
            } catch { showSaveErrorAlert(error) }
        }
    }
}
