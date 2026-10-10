//  SupportedContentOverview.swift
//  foofoil
//
//  Created by tolg on 2026/10/8.
//

import Foundation

@MainActor
enum SupportedContentOverview {
    // 保留已打开文档的历史身份，改名后仍可刷新原有记录。
    static let sourceFingerprint = "foofoil:supported-file-types-overview"

    static func markdown(
        shortcutProvider: (KeyboardShortcutDefinition) -> KeyboardShortcut? = {
            KeyboardShortcutStore.shared.shortcut(for: $0)
        }
    ) -> String {
        guard let url = Bundle.main.url(forResource: "SupportedContent", withExtension: "md"),
              var text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let extensions = AppState.textFilenameExtensions.intersection(["txt", "log", "json", "xml", "yaml", "swift", "py", "js"])
            .sorted().map { "." + $0 }.joined(separator: ", ")
        text = text.replacingOccurrences(of: "{{textExtensions}}", with: extensions)
        // 使用当前生效键位；未设置时省略括号，历史恢复也会重新生成。
        for (placeholder, identifier) in [("openDirectoryShortcut", "file.openDirectory"),
                                          ("openURLShortcut", "file.openURL"),
                                          ("openCameraShortcut", "file.openCamera"),
                                          ("openClipboardShortcut", "file.openClipboardContent")] {
            let shortcut = KeyboardShortcutCatalog.definition(withID: identifier).flatMap(shortcutProvider)
            let suffix = shortcut.map {
                String(format: NSLocalizedString("Supported Content Shortcut Format", comment: ""),
                       $0.displayString.replacingOccurrences(of: "|", with: "\\|"))
            } ?? ""
            text = text.replacingOccurrences(of: "{{\(placeholder)}}", with: suffix)
        }
        return text
    }
}

extension AppState {
    /// 帮助文档沿用文本历史管线，稳定来源标识让恢复时读取最新说明。
    func openSupportedContentOverview() {
        openText(SupportedContentOverview.markdown(), isMarkdown: true)
        sourceFingerprint = SupportedContentOverview.sourceFingerprint
        originalImageName = NSLocalizedString("Supported Content Overview", comment: "") + ".md"
        saveState()
    }
}
