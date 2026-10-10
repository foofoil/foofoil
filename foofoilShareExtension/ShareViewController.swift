import AppKit
import UniformTypeIdentifiers

/// macOS 分享入口使用公开 NSWorkspace API 向主应用交付内容，并由系统转交文件访问权。
@MainActor
final class ShareViewController: NSViewController {
    private var openingTask: Task<Void, Never>?
    private let message = NSTextField(labelWithString: "")
    private let retryButton = NSButton()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
        message.stringValue = NSLocalizedString("Share Opening", comment: "")
        message.maximumNumberOfLines = 3
        let cancel = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: self, action: #selector(cancelSharing))
        retryButton.title = NSLocalizedString("Retry", comment: "")
        retryButton.target = self
        retryButton.action = #selector(beginSharing)
        retryButton.isHidden = true
        let buttons = NSStackView(views: [retryButton, cancel])
        let stack = NSStackView(views: [message, buttons])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if openingTask == nil { beginSharing() }
    }

    @objc private func cancelSharing() {
        openingTask?.cancel()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    @objc private func beginSharing() {
        openingTask?.cancel()
        retryButton.isHidden = true
        message.stringValue = NSLocalizedString("Share Opening", comment: "")
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        openingTask = Task { [weak self] in
            do {
                guard !providers.isEmpty, providers.count <= 100 else { throw CocoaError(.fileReadUnsupportedScheme) }
                var urls: [URL] = []
                // 保留来源顺序；任一附件失败时保留分享面板，不悄悄漏掉内容。
                for provider in providers {
                    try Task.checkCancellation()
                    urls.append(try await SharedItemLoader.load(provider))
                }
                try Task.checkCancellation()
                guard let self else { return }
                let containingApp = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                guard containingApp.pathExtension == "app" else { throw CocoaError(.fileNoSuchFile) }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.open(urls, withApplicationAt: containingApp, configuration: configuration) { _, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } catch {
                guard !Task.isCancelled, let self else { return }
                let failure = error as NSError
                NSLog("Share handoff failed: %@ (%ld)", failure.domain, failure.code)
                self.message.stringValue = NSLocalizedString("Share Failed", comment: "") + "\n" + error.localizedDescription
                self.retryButton.isHidden = false
            }
        }
    }

}
