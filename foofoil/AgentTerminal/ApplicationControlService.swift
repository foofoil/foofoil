import AppKit
import PDFKit
import CryptoKit
import FoofoilExtensionKit

/// 通用窗口操作只复用宿主现有集合；授权、暂停、去重和顺序由 AgentTerminal 共用入口处理。
@MainActor
final class ApplicationControlService {
    struct OperationEntry { var value: AgentOperation; var created: Date }
    var operations: [String: OperationEntry] = [:]
    var pendingOpenIDs = Set<String>()
    unowned let delegate: AppDelegate
    init(delegate: AppDelegate) { self.delegate = delegate }

    func supportsTextRead(_ state: AppState) -> Bool {
        state.textURL != nil || state.agentKind == .text || state.agentKind == .markdown ||
            (!state.text.isEmpty && state.extensionSession == nil && state.webURL == nil && state.imageURL == nil)
    }

    func snapshot(_ controller: FloatingWindowController) -> ControlWindow {
        let state = controller.appState
        state.contentSearch.agentBindRoot(controller.window?.contentView)
        var result = ControlWindow(id: controller.controlID, content_id: state.id.uuidString,
                             title: state.toConfig().historyMenuDisplayName,
                             type: String(describing: HistoryContentKind.infer(from: state.toConfig())),
                             visible: controller.window?.isVisible == true, is_loading: state.isLoading,
                             observed_at: ISO8601DateFormatter().string(from: Date()), incognito: state.isIncognito, opacity: state.opacity, pinned: state.isPinned, border: state.showBorder,
                             terminal_state: state.terminalSession?.stateName,
                             terminal_id: state.terminalSession?.id, board_id: state.agentOwnership?.boardID)
        result.content_revision = contentVersion(state)
        result.state_revision = digest("\(result.visible)|\(result.incognito)|\(result.opacity)|\(result.pinned)|\(result.border)|\(result.title)|\(result.is_loading)|\(state.terminalSession?.stateName ?? "")")
        result.read_only = state.agentReadOnly || state.isReadOnlyTextFile
        result.zoom = state.webURL != nil ? state.webZoom : (state.textURL != nil || !state.text.isEmpty || state.isExtensionDocument) ? state.documentZoom : state.imageURL != nil ? state.imageScale : nil
        result.navigator = state.navigatorPanelVisibilityMode == .always ? "visible" : state.navigatorPanelVisibilityMode == .hidden ? "hidden" : "auto"
        result.load_error = state.agentLoadError
        result.location = state.contentSearch.agentLocation
        if let view = state.pdfNavigator?.view, let document = view.document, let page = view.currentPage {
            result.location = AgentLocation(page: document.index(for: page) + 1)
        } else if let progress = state.extensionDocumentScrollFraction { result.location = AgentLocation(progress: progress) }
        if let window = controller.window, let screen = window.screen {
            let frame = window.frame; let area = screen.visibleFrame
            result.frame = AgentFrame(x: frame.minX - area.minX, y: area.maxY - frame.maxY, width: frame.width, height: frame.height)
            result.screen_id = String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]!)
        }
        result.state_revision = digest((result.state_revision ?? "") + "|" + String(state.documentZoom) + "|" + String(state.webZoom) + "|" + String(state.imageScale) + "|" + state.navigatorPanelVisibilityMode.rawValue + "|" + (state.agentMediaController?.isPlaying == true ? "playing" : "paused") + "|" + state.mediaPlaybackMode.rawValue + "|" + String(describing: result.frame))
        return result
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
        guard AgentCommandCatalog.valid(request) else { throw AgentFailure("INVALID_REQUEST") }
        if try executeAdditional(request, response: &response) { return }
        if ["items", "items.select", "media.select"].contains(request.action) {
            try executeItems(request, response: &response); return
        }
        if request.action == "navigate", request.target_id == nil {
            try navigatePosition(request, response: &response); return
        }
        guard request.expected_revision == nil, request.incognito == nil || ["terminal.create", "open", "list"].contains(request.action),
              request.force == nil || request.action == "close",
              request.title == nil || request.action == "terminal.create" || (request.action == "set" && request.property == "title"),
              request.terminal == nil || request.action == "terminal.create",
              request.path == nil || request.action == "open",
              (request.offset == nil && request.limit == nil && request.content_version == nil) || ["read", "outline", "navigate", "list"].contains(request.action),
              request.target_id == nil || request.action == "navigate",
              (request.property == nil && request.value == nil && request.boolean_value == nil) || request.action == "set" else { throw AgentFailure("INVALID_REQUEST") }
        if request.action == "capabilities" {
            if let id = request.board_id {
                guard let target = delegate.windowControllers.first(where: { $0.controlID == id }) else { throw AgentFailure("WINDOW_NOT_FOUND") }
                response.window = snapshot(target)
                response.capabilities = ["window.inspect", "window.reveal", "window.hide", "window.close", "window.opacity", "window.incognito", "window.pinned", "window.border", "window.title"]
                if !target.appState.isLoading && supportsTextRead(target.appState) { response.capabilities?.append("content.read.original") }
                if !target.appState.isLoading && target.appState.navigatorContributions.contains(where: { $0.style == .outline }) { response.capabilities?.append("content.outline"); if target.appState.navigatorContributions.contains(where: { $0.style == .outline && $0.allowedActions.contains(.activate) && $0.items.contains(where: \.isEnabled) }) { response.capabilities?.append("content.navigate") } }
            } else {
                response.capabilities = ["window.list", "window.open", "window.inspect", "window.reveal", "window.hide", "window.close", "window.opacity", "window.incognito", "window.pinned", "window.border", "window.title", "terminal.create", "content.read.original", "content.outline", "content.navigate", "board.show", "board.update", "board.list", "board.close"]
            }
            response.capabilities?.append(contentsOf: ["operation.wait", "content.items", "content.search"])
            if let id = request.board_id {
                let state = try target(id).appState
                response.availability = availability(state)
                response.capabilities = response.availability?.filter(\.available).map(\.name)
            } else {
                response.capabilities?.append(contentsOf: ["config.list", "config.get", "config.set", "permissions.status", "history.search", "history.open", "content.export", "window.frame", "window.focus", "window.screens", "media.status", "media.play", "media.pause", "media.seek"])
            }
            return
        }
        if request.action == "list" {
            guard request.board_id == nil else { throw AgentFailure("INVALID_REQUEST") }
            let targets = delegate.windowControllers.filter { request.incognito != true || $0.appState.isIncognito }
            let version = digest(targets.map(\.controlID).joined(separator: "|"))
            let offset = request.offset ?? 0; let limit = request.limit ?? 20
            guard offset >= 0, offset <= targets.count, (1...20).contains(limit), offset == 0 || request.content_version != nil else { throw AgentFailure("INVALID_REQUEST") }
            if let expected = request.content_version, expected != version { throw AgentFailure("STALE_CONTENT") }
            var page: [ControlWindow] = []
            for target in targets.dropFirst(offset).prefix(limit) {
                let next = page + [snapshot(target)]
                guard try JSONEncoder().encode(next).count <= 24_000 else { if page.isEmpty { throw AgentFailure("ITEM_TOO_LARGE") }; break }
                page = next
            }
            response.windows = page; response.content_version = version
            response.next_offset = offset + page.count < targets.count ? offset + page.count : nil
            return
        }
        if request.action == "terminal.create" {
            guard let configuration = request.terminal, request.board_id == nil else { throw AgentFailure("INVALID_REQUEST") }
            let target = try createTerminal(configuration, title: request.title, incognito: request.incognito == true)
            response.window = snapshot(target)
            return
        }
        let target = try target(request.board_id)
        let wasIncognito = target.appState.isIncognito
        switch request.action {
        case "navigate":
            guard request.offset == nil, request.limit == nil, let expected = request.content_version,
                  let token = request.target_id, token.utf8.count <= 8192, let data = Data(base64Encoded: token),
                  let locator = try? JSONDecoder().decode(AgentNavigationTarget.self, from: data) else { throw AgentFailure("INVALID_REQUEST") }
            let state = target.appState
            guard !state.isLoading else { throw AgentFailure("CONTENT_LOADING") }
            let contributions = state.navigatorContributions.filter { $0.style == .outline }
            let version = try navigationVersion(state, contributions: contributions)
            guard expected == version else { throw AgentFailure("STALE_CONTENT") }
            guard let contribution = contributions.first(where: { $0.id == locator.contribution_id }),
                  contribution.allowedActions.contains(.activate),
                  contribution.items.contains(where: { $0.id == locator.item_id && $0.isEnabled }) else { throw AgentFailure("STALE_TARGET") }
            // 不同后端可能异步处理导航；只报告受理，不声称视口已到达目标。
            state.performNavigatorAction(NavigatorAction(contributionID: contribution.id, kind: .activate, itemIDs: [locator.item_id]))
            response.status = "accepted"
            response.operation = navigationOperation(target, locator: locator)
            response.window = snapshot(target)
            return
        case "outline":
            guard let offset = request.offset, let limit = request.limit, offset >= 0, (1...20).contains(limit), offset == 0 || request.content_version != nil else { throw AgentFailure("INVALID_REQUEST") }
            let state = target.appState
            guard !state.isLoading else { throw AgentFailure("CONTENT_LOADING") }
            let contributions = state.navigatorContributions.filter { $0.style == .outline }
            guard !contributions.isEmpty else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let version = try navigationVersion(state, contributions: contributions)
            if let expected = request.content_version, expected != version { throw AgentFailure("STALE_CONTENT") }
            let items = contributions.flatMap { contribution in
                contribution.items.map { item in
                    AgentOutlineItem(target_id: (try? encoder.encode(AgentNavigationTarget(contribution_id: contribution.id, item_id: item.id)).base64EncodedString()) ?? "", contribution_id: contribution.id, item_id: item.id, parent_id: item.parentID, title: item.title, enabled: item.isEnabled, current: item.isCurrent)
                }
            }
            guard offset <= items.count else { throw AgentFailure("INVALID_REQUEST") }
            var page: [AgentOutlineItem] = []
            for item in items.dropFirst(offset).prefix(limit) {
                // 对实际 JSON 编码计数，给响应信封保留余量；不截断不透明 ID。
                guard try encoder.encode(page + [item]).count <= 20_000 else {
                    if page.isEmpty { throw AgentFailure("ITEM_TOO_LARGE") }
                    break
                }
                page.append(item)
            }
            let next = offset + page.count
            response.outline = AgentOutlinePage(content_id: state.id.uuidString, content_version: version, items: page, next_offset: next < items.count ? next : nil)
            return
        case "read":
            guard let offset = request.offset, let limit = request.limit, offset >= 0, (1...3000).contains(limit) else { throw AgentFailure("INVALID_REQUEST") }
            let state = target.appState
            guard !state.isLoading else { throw AgentFailure("CONTENT_LOADING") }
            guard supportsTextRead(state) else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
            guard offset == 0 || request.content_version != nil else { throw AgentFailure("CONTENT_VERSION_REQUIRED") }
            // 版本同时绑定内容身份和当前内存正文；分页期间发生编辑时拒绝旧游标。
            let source = state.id.uuidString + "\0" + state.text
            let version = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
            if let expected = request.content_version, expected != version { throw AgentFailure("STALE_CONTENT") }
            let scalars = state.text.unicodeScalars
            guard let start = scalars.index(scalars.startIndex, offsetBy: offset, limitedBy: scalars.endIndex) else { throw AgentFailure("INVALID_REQUEST") }
            let end = scalars.index(start, offsetBy: limit, limitedBy: scalars.endIndex) ?? scalars.endIndex
            let next = offset + scalars.distance(from: start, to: end)
            response.text_page = AgentTextPage(content_id: state.id.uuidString, content_version: version, text: String(scalars[start..<end]), offset: offset, next_offset: end == scalars.endIndex ? nil : next, truncated: end != scalars.endIndex)
            return
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
            switch request.property {
            case "opacity":
                guard request.boolean_value == nil, let opacity = request.value, opacity.isFinite, (0.3...1).contains(opacity) else { throw AgentFailure("INVALID_REQUEST") }
                target.appState.opacity = opacity
                target.appState.saveState()
            case "pinned", "border":
                guard request.value == nil, let desired = request.boolean_value else { throw AgentFailure("INVALID_REQUEST") }
                if request.property == "pinned" { target.appState.isPinned = desired }
                else {
                    guard desired || target.appState.readingState.supportsBorderToggle else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
                    target.appState.showBorder = desired
                }
                target.appState.saveState()
            case "title":
                guard request.value == nil, request.boolean_value == nil, let title = request.title, title.utf8.count <= 512 else { throw AgentFailure("INVALID_REQUEST") }
                target.appState.customTitle = FileListState.normalizedTitle(title)
            case "incognito":
                guard request.value == nil, let desired = request.boolean_value else { throw AgentFailure("INVALID_REQUEST") }
                if target.appState.isIncognito != desired, !target.appState.toggleIncognitoMode() {
                    throw AgentFailure("HISTORY_FAVORITED")
                }
            default: throw AgentFailure("INVALID_REQUEST")
            }
        default: throw AgentFailure("INVALID_ACTION")
        }
        response.window = snapshot(target)
        if request.action == "set", request.property == "incognito" {
            let state = target.appState
            response.privacy = AgentPrivacyResult(incognito: state.isIncognito, history_action: state.isIncognito == wasIncognito ? "unchanged" : state.isIncognito ? "removed" : "created", participates_in_restore: !state.isIncognito, terminal_output_persisted: !state.isIncognito && state.terminalConfiguration != nil)
        }
    }
}
