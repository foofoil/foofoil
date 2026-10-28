import AppKit

/// 通用窗口操作只复用宿主现有集合；授权、暂停、去重和顺序由 AgentTerminal 共用入口处理。
@MainActor
final class ApplicationControlService {
    unowned let delegate: AppDelegate
    init(delegate: AppDelegate) { self.delegate = delegate }

    func snapshot(_ controller: FloatingWindowController) -> ControlWindow {
        let state = controller.appState
        return ControlWindow(id: controller.controlID, content_id: state.id.uuidString,
                             title: state.toConfig().historyMenuDisplayName,
                             type: String(describing: HistoryContentKind.infer(from: state.toConfig())),
                             visible: controller.window?.isVisible == true, opacity: state.opacity,
                             terminal_state: state.terminalSession?.stateName,
                             terminal_id: state.terminalSession?.id, board_id: state.agentOwnership?.boardID)
    }

    func createTerminal(_ configuration: TerminalLaunchConfiguration, title: String? = nil, incognito: Bool = false, reuseBlankWindow: Bool = false) throws -> FloatingWindowController {
        let normalizedTitle = FileListState.normalizedTitle(title)
        let blank = reuseBlankWindow ? delegate.blankWindowController(isIncognito: incognito) : nil
        guard blank != nil || delegate.windowControllers.count < 96 else { throw AgentFailure("WINDOW_LIMIT") }
        // 在建窗之前验证配置和工作目录；不执行脚本。
        let validation = try TerminalBootstrap(configuration: configuration, terminalID: "validation")
        validation.cleanup()
        // 自动标题的终端按历史身份重开；自定义标题或无痕创建始终保留独立记录。
        if normalizedTitle == nil, !incognito,
           let history = Self.reusableTerminalHistory(in: HistoryRepository.shared.untitledTerminalCandidates(), for: configuration),
           let controller = delegate.openHistoryConfig(config: history, id: history.id, reuseBlankWindow: reuseBlankWindow) {
            return controller
        }
        // 菜单打开沿用普通内容的空箔选择规则；CLI 的 create 仍明确创建新箔。
        let state = blank?.appState ?? AppState(isIncognito: incognito)
        if blank != nil { state.resetContent() }
        state.customTitle = normalizedTitle
        state.prepareTerminal(configuration, start: true)
        if let blank {
            delegate.activateWindow(blank)
            state.saveState()
            return blank
        }
        let controller = FloatingWindowController(appState: state)
        delegate.prepareNewWindowFrame(for: controller)
        delegate.addWindowController(controller)
        if !NSApp.isHidden { controller.showWindow(nil) }
        state.saveState()
        return controller
    }

    static func reusableTerminalHistory(in configs: [WindowConfig], for configuration: TerminalLaunchConfiguration) -> WindowConfig? {
        let directory = configuration.resolvedWorkingDirectory
        return configs.first { config in
            guard FileListState.normalizedTitle(config.customTitle) == nil,
                  let candidate = config.terminalConfiguration else { return false }
            return candidate.ssh == configuration.ssh
                && (configuration.ssh == nil ? candidate.resolvedWorkingDirectory == directory : candidate.workingDirectory == configuration.workingDirectory)
                && candidate.environment == configuration.environment
                && candidate.startupCommands == configuration.startupCommands
        }
    }

    func execute(_ request: AgentRequest, response: inout AgentResponse) throws {
        guard request.expected_revision == nil, request.incognito == nil || request.action == "terminal.create",
              request.force == nil || request.action == "close",
              request.title == nil || request.action == "terminal.create",
              request.terminal == nil || request.action == "terminal.create",
              request.path == nil || request.action == "open",
              (request.property == nil && request.value == nil) || request.action == "set" else { throw AgentFailure("INVALID_REQUEST") }
        if request.action == "list" {
            guard request.board_id == nil else { throw AgentFailure("INVALID_REQUEST") }
            response.windows = delegate.windowControllers.map(snapshot)
            return
        }
        if request.action == "terminal.create" {
            guard let configuration = request.terminal, request.board_id == nil else { throw AgentFailure("INVALID_REQUEST") }
            let target = try createTerminal(configuration, title: request.title, incognito: request.incognito == true)
            response.window = snapshot(target)
            return
        }
        if request.action == "open" {
            guard request.board_id == nil, let path = request.path, path.hasPrefix("/"), !path.contains("\0"),
                  delegate.windowControllers.count < 96 else { throw AgentFailure("INVALID_REQUEST") }
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: path) else { throw AgentFailure("CONTENT_UNREADABLE") }
            let state = AppState()
            let target = FloatingWindowController(appState: state)
            delegate.prepareNewWindowFrame(for: target)
            delegate.addWindowController(target)
            state.openFile(url: url)
            if !NSApp.isHidden { target.showWindow(nil) }
            // 通用内容打开沿用异步加载管线；accepted 不承诺解码或排版完成。
            response.status = "accepted"
            response.window = snapshot(target)
            return
        }
        guard let target = delegate.windowControllers.first(where: { $0.controlID == request.board_id }) else { throw AgentFailure("WINDOW_NOT_FOUND") }
        switch request.action {
        case "reveal":
            if NSApp.isHidden { NSApp.unhide(nil) }
            target.showWindow(nil)
        case "hide": target.hideFoil()
        case "close":
            if target.appState.terminalSession?.needsCloseConfirmation == true, request.force != true { throw AgentFailure("CONFIRMATION_REQUIRED") }
            response.window = snapshot(target)
            target.closeWithoutTerminalPrompt()
            return
        case "inspect": break
        case "set":
            guard request.property == "opacity", let opacity = request.value, opacity.isFinite, (0.3...1).contains(opacity) else { throw AgentFailure("INVALID_REQUEST") }
            target.appState.opacity = opacity
            target.appState.saveState()
        default: throw AgentFailure("INVALID_ACTION")
        }
        response.window = snapshot(target)
    }
}
