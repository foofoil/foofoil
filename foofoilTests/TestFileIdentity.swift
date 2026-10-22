import Foundation
@testable import foofoil

/// 测试中比较文件路径时统一使用应用的规范路径，避免 `/var` 与 `/private/var` 的表示差异。
enum TestFileIdentity {
    static func path(_ url: URL) -> String {
        FileReference.canonicalPath(url)
    }

    static func path(_ path: String) -> String {
        FileReference.canonicalPath(path)
    }

    static func equals(_ lhs: URL?, _ rhs: URL?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return path(lhs) == path(rhs)
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    static func equals(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return path(lhs) == path(rhs)
        case (nil, nil):
            return true
        default:
            return false
        }
    }
}
