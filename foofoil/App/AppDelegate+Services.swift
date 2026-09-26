import AppKit

extension AppDelegate {
    /// 系统传入本次选择专用的粘贴板；保留文件 URL，交由现有流程管理沙盒访问。
    @objc func openInFoofoil(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = clipboardFileURLs(from: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = NSLocalizedString(
                "No files or folders were received from the service.",
                comment: "Open in foofoil service error"
            ) as NSString
            return
        }
        didOpenFiles = true
        openFilesInNewFoil(urls)
    }
}
