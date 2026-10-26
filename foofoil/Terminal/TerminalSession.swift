import AppKit
import CoreText
import SwiftTerm
import Combine
import Darwin

/// 一次运行期会话持有视图和 PTY，SwiftUI 重绘不会创建新 Shell。
@MainActor
final class TerminalSession: NSObject, ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    enum State: Equatable { case waiting, running, closing, exited(Int32?), failed(String) }
    let id = UUID().uuidString
    let configuration: TerminalLaunchConfiguration
    @Published private(set) var previousOutput: String?
    /// 只影响本次会话的展示及搜索范围；隐藏不删除持久化的历史快照。
    @Published var isPreviousOutputHidden = false
    var onOutputSnapshotChanged: (() -> Void)?
    /// Shell 自行结束后通知宿主；宿主据此关闭箔片，不再停留在已结束界面。
    var onSessionEnded: (() -> Void)?
    private var snapshotSave: Task<Void, Never>?
    private var hasStarted = false
    /// 标记本次结束来自 Shell 自身退出，而不是宿主主动停止。
    private var endedByShell = false
    let view = FoilTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
    @Published private(set) var state: State = .waiting
    private var bootstrap: TerminalBootstrap?
    private var closing: Task<Void, Never>?
    private var managedPID: pid_t?
    private var finalExitCode: Int32?
    var stateName: String {
        switch state { case .waiting: return "waiting"; case .running: return "running"; case .closing: return "closing"; case .exited: return "exited"; case .failed: return "failed" }
    }
    var isRunning: Bool { view.process.running && state == .running }

    init(configuration: TerminalLaunchConfiguration, previousOutput: String? = nil) {
        self.configuration = configuration
        self.previousOutput = previousOutput.map(Self.boundedScrollback).flatMap { $0.isEmpty ? nil : $0 }
        super.init()
        view.processDelegate = self
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.applyDocumentStyle(font: view.font, foregroundColor: nil, backgroundColor: nil)
        view.getTerminal().changeHistorySize(1_000)
        view.outputDidChange = { [weak self] in self?.scheduleSnapshotSave() }
    }

    /// 只保存已渲染的普通屏幕文本；不保存转义序列，不重放到 PTY，也不持久化 TUI 备用屏幕。
    var outputSnapshot: String? {
        guard hasStarted else { return previousOutput }
        let current = Self.boundedScrollback(String(decoding: view.getTerminal().getBufferAsData(kind: .normal), as: UTF8.self))
        guard !current.isEmpty else { return previousOutput }
        let combined = previousOutput.map { $0 + "\n\n── " + NSLocalizedString("Terminal Session Record", comment: "") + " ──\n" + current } ?? current
        return Self.boundedScrollback(combined)
    }

    /// 手动导出保留的全部普通屏幕缓冲区，不套用历史持久化的 500 行快照限制。
    var outputTranscript: String? {
        guard hasStarted else { return previousOutput }
        let current = String(decoding: view.getTerminal().getBufferAsData(kind: .normal), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        guard !current.isEmpty else { return previousOutput }
        return previousOutput.map { $0 + "\n\n── " + NSLocalizedString("Terminal Session Record", comment: "") + " ──\n" + current } ?? current
    }

    /// 保留当前提示符、输入和光标列，只清除其他显示及滚动记录；不向 PTY 发送命令。
    func clearContent() {
        let terminal = view.getTerminal()
        let cursor = terminal.getCursorLocation()
        // 直接复制终端单元格，保留提示符颜色、宽字符及光标右侧尚在编辑的内容。
        view.scroll(toPosition: 1)
        let currentLine = terminal.getLine(row: cursor.y).map { BufferLine(from: $0) }
        view.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
        if let currentLine {
            terminal.getLine(row: 0)?.copyFrom(line: currentLine)
            view.feed(text: "\u{1b}[\(min(cursor.x + 1, terminal.cols))G")
            view.needsDisplay = true
        }
        previousOutput = nil
    }

    func clearPreviousOutput() {
        previousOutput = nil
    }

    nonisolated static func boundedScrollback(_ text: String) -> String {
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .newlines)
        let lines = clean.split(separator: "\n", omittingEmptySubsequences: false).suffix(500).joined(separator: "\n")
        var bytes = Array(lines.utf8.suffix(128 * 1_024))
        // 截断点可能落在 UTF-8 多字节字符中，最多跳过三个前导残片。
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeFirst()
        }
        return ""
    }

    private func scheduleSnapshotSave() {
        guard onOutputSnapshotChanged != nil, snapshotSave == nil, state == .running else { return }
        // 持续输出最多每五秒保存一次，避免逐字符或无限推迟的防抖写入。
        snapshotSave = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self else { return }
            self.snapshotSave = nil
            self.onOutputSnapshotChanged?()
        }
    }

    func start() {
        guard state == .waiting else { return }
        do {
            let launch = try TerminalBootstrap(configuration: configuration, terminalID: id)
            bootstrap = launch
            hasStarted = true
            state = .running
            view.startProcess(executable: launch.shell, args: launch.arguments,
                              environment: launch.environment.map { "\($0.key)=\($0.value)" }, currentDirectory: launch.workingDirectory)
            managedPID = view.process.running ? view.process.shellPid : nil
            if !view.process.running { state = .failed("TERMINAL_START_FAILED"); launch.cleanup(); bootstrap = nil }
        } catch { state = .failed((error as? AgentFailure)?.code ?? "TERMINAL_START_FAILED") }
    }

    /// PTY 前台组和同一会话中的后台任务都参与判断；无法读取进程快照时保守确认。
    var needsCloseConfirmation: Bool {
        guard isRunning else { return false }
        let pid = view.process.shellPid
        let foreground = tcgetpgrp(view.process.childfd)
        guard foreground >= 0, let members = Self.sessionMembers(pid) else { return true }
        return foreground != pid || members.contains { $0.pid != pid }
    }

    static func confirmTermination() -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Terminal Close Title", comment: "")
        alert.informativeText = NSLocalizedString("Terminal Close Message", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Terminate", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 不按父子 PID 递归越界追杀：只管理本次 PTY 的 session，脱离 session 的进程不在承诺范围。
    @discardableResult
    func stop() -> Task<Void, Never> {
        if let closing { return closing }
        // 会话已结束：没有残留进程需要清理，不重复走一遍挂断流程。
        if case .exited = state { return Task<Void, Never> {} }
        snapshotSave?.cancel(); snapshotSave = nil
        let pid = managedPID ?? 0
        state = .closing
        let task = Task { @MainActor [self] in
            if pid > 1 {
                // 以 pid + 启动时间校验身份；先请求挂断，再 TERM，最后 KILL。
                var members = Self.sessionMembers(pid) ?? []
                Self.signal(members, session: pid, signal: SIGHUP)
                // Shell 已退出且没有残留任务时立即继续，避免空等清理宽限期。
                if !members.isEmpty { try? await Task.sleep(for: .milliseconds(800)) }
                members = Self.sessionMembers(pid) ?? members.filter(Self.stillSameProcess)
                Self.signal(members, session: pid, signal: SIGTERM)
                // Shell 已退出且没有残留任务时立即继续，避免空等清理宽限期。
                if !members.isEmpty { try? await Task.sleep(for: .milliseconds(800)) }
                members = Self.sessionMembers(pid) ?? members.filter(Self.stillSameProcess)
                Self.signal(members, session: pid, signal: SIGKILL)
                if view.process.running { view.terminate() }
            }
            bootstrap?.cleanup(); bootstrap = nil
            managedPID = nil
            state = .exited(finalExitCode)
            onOutputSnapshotChanged?()
            if endedByShell {
                endedByShell = false
                // Shell 自行结束：通知宿主关闭箔片，不再显示启动新会话的入口。
                onSessionEnded?()
            }
            closing = nil
        }
        closing = task
        return task
    }

    private struct Member { let pid: pid_t; let started: timeval }
    private static func processes() -> [kinfo_proc]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<3 {
            var length = 0
            guard sysctl(&mib, 4, nil, &length, nil, 0) == 0 else { return nil }
            var data = [kinfo_proc](repeating: kinfo_proc(), count: length / MemoryLayout<kinfo_proc>.stride + 32)
            length = data.count * MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, 4, &data, &length, nil, 0) == 0 { return Array(data.prefix(length / MemoryLayout<kinfo_proc>.stride)) }
            if errno != ENOMEM { return nil }
        }
        return nil
    }
    private static func sessionMembers(_ session: pid_t) -> [Member]? {
        processes()?.filter { getsid($0.kp_proc.p_pid) == session }.map { Member(pid: $0.kp_proc.p_pid, started: $0.kp_proc.p_starttime) }
    }
    private static func stillSameProcess(_ member: Member) -> Bool {
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, member.pid]
        return sysctl(&mib, 4, &info, &length, nil, 0) == 0 && length > 0
            && info.kp_proc.p_starttime.tv_sec == member.started.tv_sec
            && info.kp_proc.p_starttime.tv_usec == member.started.tv_usec
    }
    private static func signal(_ members: [Member], session: pid_t, signal: Int32) {
        for member in members where stillSameProcess(member) && getsid(member.pid) == session {
            kill(member.pid, signal)
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        finalExitCode = exitCode.map { status in
            let signal = status & 0x7f
            return signal == 0 ? (status >> 8) & 0xff : 128 + signal
        }
        if state != .closing {
            // PTY 进程自行结束（Ctrl+D 退出最后一层、脚本跑完等）：会话到此为止。
            endedByShell = true
            stop()
        }
    }
}

final class FoilTerminalView: LocalProcessTerminalView {
    struct SearchSpan { let row: Int; let columns: Range<Int> }
    struct SearchMatch {
        let spans: [SearchSpan]
        var row: Int { spans.first?.row ?? 0 }
    }
    private var searchOverlay: TerminalSearchOverlay?
    var searchHighlights: [SearchMatch] = [] {
        didSet {
            if searchOverlay == nil, !searchHighlights.isEmpty {
                let overlay = TerminalSearchOverlay(frame: NSRect(origin: .zero, size: bounds.size))
                overlay.terminalView = self
                overlay.autoresizingMask = [.width, .height]
                addSubview(overlay)
                searchOverlay = overlay
            }
            searchOverlay?.needsDisplay = true
        }
    }

    // SwiftTerm 滚动时只重绘终端本身；子视图必须同步失效，不能沿用上一屏的高亮。
    override var needsDisplay: Bool {
        didSet { if needsDisplay { searchOverlay?.needsDisplay = true } }
    }
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        searchOverlay?.needsDisplay = true
    }
    private var searchCurrent = 0
    private var searchColor = NSColor.systemYellow
    private var searchRowCount = 0

    /// 按实际单元格映射 UTF-16 偏移，保留中文宽字符与组合字符的列位置。
    func updateSearch(query: String, color: NSColor) {
        let terminal = getTerminal()
        let rows = String(decoding: terminal.getBufferAsData(), as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        searchRowCount = max(0, rows.count - 1)
        searchColor = color
        var text = ""
        var cells: [(row: Int, start: Int, end: Int)] = []
        for row in 0..<searchRowCount {
            if row > 0 {
                // 复用终端自己的复制语义辨别软换行，长关键字跨屏幕行时仍只算一条。
                let boundary = terminal.getText(start: Position(col: terminal.cols, row: row - 1), end: Position(col: 0, row: row))
                if boundary.contains("\n") || rows[row].isEmpty {
                    text += "\n"; cells.append((row: row, start: 0, end: 0))
                }
            }
            var rowText = ""
            var rowCells: [(row: Int, start: Int, end: Int)] = []
            var meaningfulLength = 0
            for col in 0..<terminal.cols {
                let cell = terminal.buffer.getChar(atBufferRelative: Position(col: col, row: row))
                guard cell.width > 0 else { continue }
                let character = terminal.getCharacter(for: cell)
                let value = character == "\0" ? " " : String(character)
                rowText += value
                rowCells += Array(repeating: (row: row, start: col, end: col + Int(cell.width)), count: value.utf16.count)
                if character != "\0" { meaningfulLength = rowCells.count }
            }
            text += (rowText as NSString).substring(to: meaningfulLength)
            cells += rowCells.prefix(meaningfulLength)
        }
        var matches: [SearchMatch] = []
        for range in FoilContentSearch.ranges(in: text, query: query) where NSMaxRange(range) <= cells.count {
            var spans: [SearchSpan] = []
            for cell in cells[range.location..<NSMaxRange(range)] where cell.end > cell.start {
                if let last = spans.last, last.row == cell.row {
                    spans[spans.count - 1] = SearchSpan(row: cell.row, columns: last.columns.lowerBound..<cell.end)
                } else { spans.append(SearchSpan(row: cell.row, columns: cell.start..<cell.end)) }
            }
            if !spans.isEmpty { matches.append(SearchMatch(spans: spans)) }
        }
        searchHighlights = matches
    }

    func revealSearchMatch(_ index: Int) {
        guard searchHighlights.indices.contains(index) else { return }
        searchCurrent = index
        let terminal = getTerminal()
        let maxScroll = max(0, searchRowCount - terminal.rows)
        if maxScroll > 0 { scroll(toPosition: Double(max(0, searchHighlights[index].row - terminal.rows / 3)) / Double(maxScroll)) }
        if let clip = superview as? NSClipView {
            let rect = searchHighlightRect(for: searchHighlights[index].spans[0])
            let maximum = max(0, bounds.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, rect.midY - clip.bounds.height / 2))))
        }
        needsDisplay = true
    }

    /// 与 SwiftTerm 的绘制使用同一套单元格度量及缓冲区行偏移。
    func searchHighlightRect(for span: SearchSpan) -> NSRect {
        let width = max(1, font.advancement(forGlyph: font.glyph(withName: "W")).width)
        let height = max(1, ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)))
        let row = span.row - getTerminal().getTopVisibleRow()
        return NSRect(x: CGFloat(span.columns.lowerBound) * width,
                      y: frame.height - CGFloat(row + 1) * height,
                      width: CGFloat(span.columns.count) * width, height: height)
    }

    fileprivate func drawSearchHighlights(in overlay: NSView) {
        guard !searchHighlights.isEmpty else { return }
        let terminal = getTerminal()
        for (index, match) in searchHighlights.enumerated() {
            for span in match.spans {
                let row = span.row - terminal.getTopVisibleRow()
                guard row >= 0, row < terminal.rows else { continue }
                let rect = overlay.convert(searchHighlightRect(for: span), from: self)
                searchColor.withAlphaComponent(index == searchCurrent ? 0.55 : 0.12).setFill()
                rect.fill(using: .sourceOver)
                if index == searchCurrent { searchColor.setStroke(); NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke() }
            }
        }
    }

    var outputDidChange: (() -> Void)?
    private var keyboardProtocol = TerminalKeyboardProtocol()

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // 协商序列不能交给 SwiftTerm 当成恢复光标；响应仍经同一 PTY 返回给前台程序。
        for output in keyboardProtocol.receive(slice) {
            switch output {
            case .display(let bytes): super.dataReceived(slice: bytes[...])
            case .reply(let text): send(txt: text)
            }
        }
        outputDidChange?()
    }

    /// SwiftTerm 的 keyDown 不是 open；窗口在终端持有焦点时统一从此入口分发。
    func handleTerminalKeyDown(with event: NSEvent) {
        if let encoded = keyboardProtocol.encoding(for: event, optionAsMetaKey: optionAsMetaKey), !hasMarkedText() {
            selectNone()
            send(txt: encoded)
        } else {
            super.keyDown(with: event)
        }
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        keyboardProtocol = TerminalKeyboardProtocol()
        super.processTerminated(source, exitCode: exitCode)
    }
    private var documentForegroundColor: NSColor?
    private var documentBackgroundColor: NSColor?
    private var installedDarkPalette: Bool?

    func applyDocumentStyle(font: NSFont, foregroundColor: NSColor?, backgroundColor: NSColor?) {
        if self.font != font { self.font = font }
        // 只在样式改变时重设默认色，避免无关重绘覆盖 Shell/TUI 的运行期配色。
        guard installedDarkPalette == nil || documentForegroundColor != foregroundColor || documentBackgroundColor != backgroundColor else { return }
        documentForegroundColor = foregroundColor
        documentBackgroundColor = backgroundColor
        refreshDocumentColors()
    }

    private func refreshDocumentColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeForegroundColor = documentForegroundColor ?? .textColor
            nativeBackgroundColor = documentBackgroundColor ?? .textBackgroundColor
            if let background = nativeBackgroundColor.usingColorSpace(.sRGB) {
                let dark = 0.2126 * background.redComponent + 0.7152 * background.greenComponent + 0.0722 * background.blueComponent < 0.5
                if installedDarkPalette != dark {
                    installColors(Self.ansiPalette(dark: dark))
                    installedDarkPalette = dark
                }
            }
        }
        needsDisplay = true
    }

    /// 保留 ANSI 色位语义；浅底使用较深的低饱和色，深底使用柔和亮色，避免默认荧光绿/青。
    private static func ansiPalette(dark: Bool) -> [SwiftTerm.Color] {
        let values: [UInt32] = dark ? [
            0x252C34, 0xD18A8C, 0x9AC49F, 0xCBB583, 0x97B3D8, 0xB49BC5, 0x8FBFC3, 0xCED6DE,
            0x65717F, 0xDEA0A1, 0xADD0B0, 0xD9C59B, 0xADC3E1, 0xC6AFD4, 0xA4CED0, 0xEDF1F5
        ] : [
            0x29323A, 0xB14F52, 0x3D7254, 0x8D6D30, 0x4E6FA9, 0x8B619A, 0x33777C, 0xD7DCE2,
            0x67727D, 0xBE5A5D, 0x467B5F, 0x97763D, 0x5C7DB3, 0x9770A7, 0x3B7E85, 0xF2F4F6
        ]
        return values.map { value in
            SwiftTerm.Color(red: UInt16((value >> 16) & 0xff) * 257,
                green: UInt16((value >> 8) & 0xff) * 257, blue: UInt16(value & 0xff) * 257)
        }
    }

    /// 终端引擎保存解析后的 RGB 色值，外观变化时需按当前视图重新解析系统语义色。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshDocumentColors()
    }

    /// 控制键及终端编辑快捷键先于应用菜单处理；常规 Command 菜单仍保留。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command) {
            handleTerminalKeyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 搜索覆盖层不接受鼠标事件，也不改变终端的选择、输入或缓冲区属性。
private final class TerminalSearchOverlay: NSView {
    weak var terminalView: FoilTerminalView?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { terminalView?.drawSearchHighlights(in: self) }
}
