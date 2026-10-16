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

    /// 包内文档另开后拥有自己的来源生命周期；普通箔持久缓存，无痕箔仅保留临时租约。
    func makePackageContentsState() async throws -> AppState? {
        guard let source = packageContentsURL else { return nil }
        let target = AppState(isIncognito: isIncognito)
        let lease = archivePreviewLease
        let displayName = originalImageName ?? source.lastPathComponent
        let keepsTemporarySource = isArchivePreview && isIncognito
        let fingerprint = packageContentsFingerprint
        var url = source
        if isArchivePreview && !isIncognito {
            guard let destination = target.getCachedContentURL(kind: "package", extension: source.pathExtension) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try await Task.detached(priority: .userInitiated) {
                try ContentCache.shared.copy(from: source, to: destination)
            }.value
            url = destination
        }
        target.openArchive(url: url, displayName: displayName, fingerprint: fingerprint,
                           sourceLease: keepsTemporarySource ? lease : nil)
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
