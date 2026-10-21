import Foundation

/// 搜索是用户偏好；文件隐私权限由 macOS 在实际访问时处理，不再请求主目录书签。
@MainActor
final class LocalFileSearchSettings {
    static let shared = LocalFileSearchSettings()
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var isEnabled: Bool {
        get { defaults.bool(forKey: "localFileSearchEnabled") }
        set {
            defaults.set(newValue, forKey: "localFileSearchEnabled")
            NotificationCenter.default.post(name: .localFileSearchDidChange, object: nil)
        }
    }
    nonisolated static var userHome: URL { FileManager.default.homeDirectoryForCurrentUser }
}
