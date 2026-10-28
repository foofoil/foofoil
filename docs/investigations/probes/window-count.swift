// 只记录相关进程的窗口数量，不输出窗口标题、内容、坐标或其他应用的信息。
import Foundation
import CoreGraphics

let wanted = Set(["foofoil", "CursorUIViewService", "Window Server", "WindowServer", "Squirrel"])
guard let rows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    fputs("CGWindowListCopyWindowInfo unavailable\n", stderr)
    exit(1)
}
var counts: [String: Int] = [:]
var visible: [String: Int] = [:]
for row in rows {
    guard let name = row[kCGWindowOwnerName as String] as? String, wanted.contains(name) else { continue }
    counts[name, default: 0] += 1
    if row[kCGWindowIsOnscreen as String] as? Bool == true { visible[name, default: 0] += 1 }
}
for key in counts.keys.sorted() {
    print("\(key): windows=\(counts[key]!), onscreen=\(visible[key, default: 0])")
}
