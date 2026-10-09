import Foundation

extension AppState {
    /// 切换资料库来源前先保存旧箔，新内容获得独立的历史身份和音频默认外观。
    func prepareAppleMusic(_ item: AppleMusicLibraryItem) {
        let isNewSource = appleMusicReference?.sourceFingerprint != item.reference.sourceFingerprint
        if isNewSource { saveState() }
        let wasBatchUpdating = isBatchUpdating
        isBatchUpdating = true
        defer { isBatchUpdating = wasBatchUpdating }
        currentMediaRouteGeneration &+= 1
        if isNewSource {
            id = UUID()
            createdAt = Date()
        }
        stopCamera()
        imageURL = nil
        webURL = nil
        actualWebURL = nil
        textURL = nil
        text = ""
        extensionSession = nil
        extensionStateReference = nil
        fileList = nil
        clearAppleMusicNavigator()
        appleMusicItem = item
        originalImageName = item.title
        sourceFingerprint = item.reference.sourceFingerprint
        if isNewSource { showBorder = false }
        isMediaPlaybackControlsVisible = true
    }

    /// 异步恢复不能覆盖用户随后打开的内容；缺失或授权变化保留历史并展示重试入口。
    func restoreAppleMusicItem(
        resolve: @MainActor (AppleMusicReference) async throws -> AppleMusicLibraryItem = { try await AppleMusicLibrary.shared.resolve($0) }
    ) async {
        guard let reference = appleMusicReference, appleMusicItem == nil else { return }
        let generation = currentMediaRouteGeneration
        appleMusicRestoreError = nil
        do {
            let item = try await resolve(reference)
            try Task.checkCancellation()
            guard generation == currentMediaRouteGeneration, appleMusicReference == reference else { return }
            appleMusicItem = item
            originalImageName = item.title
            sourceFingerprint = item.reference.sourceFingerprint
            isMediaPlaybackControlsVisible = true
            saveState()
            AppleMusicHistoryArtwork.schedule(item, historyID: id)
        } catch {
            guard !Task.isCancelled, generation == currentMediaRouteGeneration, appleMusicReference == reference else { return }
            appleMusicRestoreError = error.localizedDescription
        }
    }
}
