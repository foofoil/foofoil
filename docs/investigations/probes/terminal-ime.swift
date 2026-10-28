// 上游缺陷基线：仅检查原始 SwiftTerm，不包含宿主 FoilTerminalView 的修复；不启动 Shell 或创建窗口。
import AppKit
import SwiftTerm

print("probeTarget=upstream SwiftTerm (host overrides excluded)")
let app = NSApplication.shared
let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                   replacementRange: NSRange(location: NSNotFound, length: 0))
print("hasMarkedText=\(view.hasMarkedText())")
print("markedRange=\(view.markedRange())")
print("selectedRange=\(view.selectedRange())")
print("windowsCreated=\(app.windows.count)")
