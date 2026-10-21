import AppKit
import SwiftTerm
import Combine
import Darwin

/// 一次运行期会话持有视图和 PTY，SwiftUI 重绘不会创建新 Shell。
@MainActor
final class TerminalSession: NSObject, ObservableObject, @preconcurrency LocalProcessTerminalViewDelegate {
    enum State: Equatable { case waiting, running, closing, exited(Int32?), failed(String) }
    let id = UUID().uuidString
    let configuration: TerminalLaunchConfiguration
    let previousOutput: String?
    var onOutputSnapshotChanged: (() -> Void)?
    private var snapshotSave: Task<Void, Never>?
    private var hasStarted = false
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
        snapshotSave?.cancel(); snapshotSave = nil
        let pid = managedPID ?? 0
        state = .closing
        let task = Task { @MainActor [self] in
            if pid > 1 {
                // 以 pid + 启动时间校验身份；先请求挂断，再 TERM，最后 KILL。
                var members = Self.sessionMembers(pid) ?? []
                Self.signal(members, session: pid, signal: SIGHUP)
                try? await Task.sleep(for: .milliseconds(800))
                members = Self.sessionMembers(pid) ?? members.filter(Self.stillSameProcess)
                Self.signal(members, session: pid, signal: SIGTERM)
                try? await Task.sleep(for: .milliseconds(800))
                members = Self.sessionMembers(pid) ?? members.filter(Self.stillSameProcess)
                Self.signal(members, session: pid, signal: SIGKILL)
                if view.process.running { view.terminate() }
            }
            bootstrap?.cleanup(); bootstrap = nil
            managedPID = nil
            state = .exited(finalExitCode)
            onOutputSnapshotChanged?()
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
        if state != .closing { stop() }
    }
}

final class FoilTerminalView: LocalProcessTerminalView {
    var outputDidChange: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        outputDidChange?()
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
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
