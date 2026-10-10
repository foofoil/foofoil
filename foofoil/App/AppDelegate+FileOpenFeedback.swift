import AppKit

extension AppDelegate {
    @objc func handleFileOpenFeedback(_ notification: Notification) {
        guard let failures = notification.userInfo?["failures"] as? [FileOpenFeedback], !failures.isEmpty else { return }
        let batchID = notification.userInfo?["batchID"] as? UUID ?? UUID()
        // 同一批次异步判定出的失败合并到独立反馈箔；绝不占用现有空箔或覆盖原内容。
        if let existing = windowControllers.first(where: {
            $0.appState.isFileOpenFeedback && $0.appState.fileOpenFeedbackBatchID == batchID
        }) {
            let known = Set(existing.appState.fileOpenFeedback.map(\.id))
            existing.appState.fileOpenFeedback.append(contentsOf: failures.filter { !known.contains($0.id) })
            activateWindow(existing)
        } else {
            let state = AppState()
            state.fileOpenFeedbackBatchID = batchID
            state.fileOpenFeedback = failures
            state.originalImageName = failures.count == 1 ? failures[0].url.lastPathComponent : NSLocalizedString("File Feedback Title", comment: "")
            state.showBorder = true
            let controller = showNewWindow(with: state)
            controller.window?.title = failures.count == 1 ? failures[0].url.lastPathComponent : NSLocalizedString("File Feedback Title", comment: "")
        }
        if let source = notification.object as? AppState, source.closesEmptyWindowAfterFileOpenFailure,
           let controller = windowControllers.first(where: { $0.appState === source }) {
            closeFoilIfStillBlank(controller, for: source)
        }
    }
}
