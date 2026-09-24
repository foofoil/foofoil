import AppKit
import Foundation

/// 文件搜索范围固定为用户主目录：系统只把访问权限授予用户明确选择的路径，
/// 因此“开启文件搜索”时由系统文件面板确认一次主目录，保存只读安全范围书签；
/// 每次查询和打开分别持有并释放访问，未授权时不启动 Spotlight 查询。
@MainActor
final class SpotlightSearchAccess {
    static let shared = SpotlightSearchAccess()
    private let defaults: UserDefaults
    private let key = "spotlightSearchHomeBookmark"
    /// 授权与校验使用的用户主目录；测试可注入临时目录。
    let homeDirectory: URL

    init(defaults: UserDefaults = .standard, homeDirectory: URL = SpotlightSearchAccess.userHome) {
        self.defaults = defaults
        self.homeDirectory = homeDirectory
    }

    /// 账户主目录。沙盒进程的 NSHomeDirectory / homeDirectoryForCurrentUser 指向应用容器，不能作为搜索范围。
    nonisolated static let userHome: URL = {
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    var isAuthorized: Bool { defaults.data(forKey: key) != nil }

    /// 只接受用户主目录：选择其他目录时拒绝保存，避免搜索范围偏离固定范围。
    func authorizeHome(_ url: URL) throws {
        guard isUserHome(url) else { throw SpotlightSearchAccessError.notUserHome }
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }

    func isUserHome(_ url: URL) -> Bool {
        Self.canonicalPath(url) == Self.canonicalPath(homeDirectory)
    }

    /// 解析书签并持有访问；调用方负责用 stopAccessingSecurityScopedResource 配对释放。
    /// 未授权时返回空数组，由查询服务报告需要授权；书签无法恢复时清除失效授权并抛错。
    func beginAccess() throws -> [URL] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else {
                throw CocoaError(.fileReadNoPermission)
            }
            if stale, let refreshed = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(refreshed, forKey: key)
            }
            return [url]
        } catch {
            clear()
            throw error
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

enum SpotlightSearchAccessError: Error {
    case notUserHome
}

/// 开启文件搜索的系统确认流程：固定选择用户主目录，成功后保存只读安全范围书签。
@MainActor
enum SpotlightSearchAuthorization {
    enum Outcome: Equatable {
        case authorized
        case cancelled
        /// 选择的不是用户主目录，授权未保存。
        case needsHomeFolder
        case failed
    }

    static func request(completion: @escaping (Outcome) -> Void) {
        let access = SpotlightSearchAccess.shared
        let panel = makePanel()
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                completion(.cancelled)
                return
            }
            do {
                try access.authorizeHome(url)
                completion(.authorized)
            } catch SpotlightSearchAccessError.notUserHome {
                completion(.needsHomeFolder)
            } catch {
                completion(.failed)
            }
        }
    }

    /// 直接打开用户主目录：目录模式下确认按钮返回当前文件夹，一次点击即可授权，
    /// 不必在上一级列表里挑选，也不会误选同级目录或子目录。
    static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SpotlightSearchAccess.shared.homeDirectory
        panel.message = NSLocalizedString("File Search Authorization Message", comment: "")
        panel.prompt = NSLocalizedString("File Search Authorization Confirm", comment: "")
        return panel
    }
}
