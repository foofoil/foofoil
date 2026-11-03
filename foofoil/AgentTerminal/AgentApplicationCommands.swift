import AppKit
import AVFoundation
import CryptoKit
import FoofoilExtensionKit
import MusicKit
import PDFKit
import WebKit

extension ApplicationControlService {
    func contentVersion(_ state: AppState) -> String {
        digest(state.id.uuidString + "\0" + String(state.agentTextRevision) + "\0" + (state.imageURL?.absoluteString ?? "") + "\0" + (state.extensionSession?.id.uuidString ?? "") + "\0" + String(state.contentReloadRevision) + "\0" + (state.fileList?.currentID ?? state.extensionSession?.playbackQueue?.currentItemID ?? ""))
    }
    func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    func registerOperation(_ target: FloatingWindowController, ready: @escaping @MainActor () -> Bool) -> AgentOperation {
        operations = operations.filter { Date().timeIntervalSince($0.value.created) < 600 }
        if operations.count >= 128, let oldest = operations.min(by: { $0.value.created < $1.value.created })?.key { operations.removeValue(forKey: oldest) }
        let expectedContentID = target.appState.id
        let expectedDrop = target.appState.currentDropGeneration
        let id = delegate.agentTerminal.runID + ":" + UUID().uuidString
        let operation = AgentOperation(id: id, window_id: target.controlID, status: "pending", created_at: ISO8601DateFormatter().string(from: Date()))
        operations[id] = OperationEntry(value: operation, created: Date())
        Task { @MainActor [weak self, weak target, weak delegate = delegate] in
            guard let self else { return }
            defer { self.pendingOpenIDs.remove(operation.window_id) }
            let deadline = Date().addingTimeInterval(300)
            while self.operations[id]?.value.status == "pending" {
                guard let target, delegate?.windowControllers.contains(where: { $0 === target }) == true else {
                    self.operations[id]?.value.status = "failed"; self.operations[id]?.value.error = "WINDOW_CLOSED"; return
                }
                if target.appState.id != expectedContentID || target.appState.currentDropGeneration != expectedDrop {
                    self.operations[id]?.value.status = "failed"; self.operations[id]?.value.error = "CONTENT_REPLACED"; return
                }
                if let error = target.appState.agentLoadError ?? (target.appState.extensionHandoffFailureMessage == nil ? nil : "CONTENT_LOAD_FAILED") {
                    self.operations[id]?.value.status = "failed"; self.operations[id]?.value.error = error; return
                }
                if (try? self.mediaState(target.appState).error) != nil {
                    self.operations[id]?.value.status = "failed"; self.operations[id]?.value.error = "MEDIA_FAILED"; return
                }
                if target.appState.isQuickLookDocument, target.appState.pendingContentOpenCount == 0 {
                    self.operations[id]?.value.status = "unverified"; self.operations[id]?.value.error = "COMPLETION_UNOBSERVABLE"; return
                }
                if ready() { self.operations[id]?.value.status = "ready"; return }
                if Date() >= deadline { self.operations[id]?.value.status = "failed"; self.operations[id]?.value.error = "OPERATION_TIMEOUT"; return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        return operation
    }
    func openOperation(_ target: FloatingWindowController) -> AgentOperation {
        let state = target.appState
        pendingOpenIDs.insert(target.controlID)
        let operation = registerOperation(target) { [weak state] in
            guard let state else { return false }
            guard state.pendingContentOpenCount == 0, !state.isLoading, state.activeDirectoryDropScan == nil else { return false }
            if state.webURL != nil { return state.agentWebLoadFinished }
            if state.isPDFDocument { return state.pdfNavigator?.view?.document != nil }
            // 成功必须有实际加载的内容；空白窗口和 isLoading=false 都不构成完成证据。
            return state.hasOpenedContent && state.extensionHandoffFailureMessage == nil
        }
        return operation
    }

    func cancelPendingOpens(error: String) {
        let pending = Set(operations.values.filter { $0.value.status == "pending" && pendingOpenIDs.contains($0.value.window_id) }.map { $0.value.window_id })
        for controller in delegate.windowControllers where pending.contains(controller.controlID) {
            let state = controller.appState
            state.agentLoadError = error
            state.currentMediaRouteGeneration &+= 1
            state.currentDropGeneration &+= 1
            state.activeDirectoryDropScan?.cancel()
            state.contentSearch.agentStopLoading()
        }
        for id in operations.keys where operations[id]?.value.status == "pending" && pending.contains(operations[id]!.value.window_id) {
            operations[id]?.value.status = "failed"; operations[id]?.value.error = error
        }
        pendingOpenIDs.subtract(pending)
    }

    func target(_ id: String?) throws -> FloatingWindowController {
        guard let id else { throw AgentFailure("INVALID_REQUEST") }
        guard let target = delegate.windowControllers.first(where: { $0.controlID == id }) else {
            if id.contains(":"), !id.hasPrefix(delegate.agentTerminal.runID + ":") { throw AgentFailure("HANDLE_EXPIRED") }
            throw AgentFailure("WINDOW_NOT_FOUND")
        }
        return target
    }
    func mediaState(_ state: AppState) throws -> AgentMediaState {
        guard let controller = state.agentMediaController else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
        var result = AgentMediaState(playing: controller.isPlaying,
                               current_time: controller.currentTime.isFinite ? controller.currentTime : nil,
                               duration: controller.duration.isFinite && controller.duration > 0 ? controller.duration : nil,
                               volume: controller.supportsVolumeControl ? Double(controller.volume) : nil,
                               muted: controller.supportsVolumeControl ? controller.isMuted : nil,
                               mode: state.mediaPlaybackMode.rawValue,
                               pending: !state.extensionPlaybackPendingWrites.isEmpty)
        result.state = state.extensionSession?.mediaPlayback?.state.rawValue ?? (controller.isPlaying ? "playing" : "paused")
        if let music = controller as? AppleMusicPlaybackController {
            if music.isLoading { result.state = "loading" }
            if music.error != nil { result.state = "failed"; result.error = "MEDIA_FAILED" }
        } else if let audio = controller as? AudioPlaybackController, audio.deviceFailureMessage != nil {
            result.state = "failed"; result.error = "MEDIA_FAILED"
        } else if let video = controller as? VideoPlayerController {
            if video.player.status == .failed { result.state = "failed"; result.error = "MEDIA_FAILED" }
            else if video.player.timeControlStatus == .waitingToPlayAtSpecifiedRate { result.state = "loading" }
        }
        if result.state == "failed" { result.error = "MEDIA_FAILED" }
        result.current_item_id = state.fileList?.currentID ?? state.extensionSession?.playbackQueue?.currentItemID
        return result
    }

    func executeAdditional(_ request: AgentRequest, response: inout AgentResponse) throws -> Bool {
        switch request.action {
        case "wait":
            let record: OperationEntry?
            if let id = request.operation_id {
                guard request.board_id == nil else { throw AgentFailure("INVALID_REQUEST") }
                if !id.hasPrefix(delegate.agentTerminal.runID + ":") { throw AgentFailure("HANDLE_EXPIRED") }
                record = operations[id]
            } else {
                let target = try target(request.board_id)
                record = operations.values.filter { $0.value.window_id == target.controlID }.max { $0.created < $1.created }
            }
            guard let record else { throw AgentFailure("OPERATION_NOT_FOUND") }
            response.operation = record.value; response.status = record.value.status
            if let target = delegate.windowControllers.first(where: { $0.controlID == record.value.window_id }) { response.window = snapshot(target) }
            response.error = record.value.error
            return true
        case "screens":
            response.screens = NSScreen.screens.map { screen in
                let frame = screen.visibleFrame
                return AgentScreen(id: String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]!), frame: AgentFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
            }
            return true
        case "config.list", "config.get", "config.set":
            response.configuration = try configuration(request)
            return true
        case "permissions.status":
            response.permissions = [AgentPermission(name: "local-files", status: "not_determined_per_resource", action_required: false),
                                    AgentPermission(name: "apple-music", status: String(describing: MusicAuthorization.currentStatus), action_required: MusicAuthorization.currentStatus != .authorized),
                                    AgentPermission(name: "camera", status: String(describing: AVCaptureDevice.authorizationStatus(for: .video)), action_required: AVCaptureDevice.authorizationStatus(for: .video) != .authorized)]
            return true
        case "settings.open":
            guard ["general", "types", "keyboardShortcuts", "agent"].contains(request.text_value ?? "") else { throw AgentFailure("INVALID_REQUEST") }
            SettingsWindowController.shared.show(section: request.text_value!)
            return true
        case "open":
            guard request.board_id == nil, [request.path != nil, request.url != nil, request.clipboard == true].filter({ $0 }).count == 1 else { throw AgentFailure("INVALID_REQUEST") }
            guard delegate.windowControllers.count < 96 else { throw AgentFailure("WINDOW_LIMIT") }
            let state = AppState(isIncognito: request.incognito == true)
            let controller = FloatingWindowController(appState: state)
            if let path = request.path {
                guard path.hasPrefix("/"), !path.contains("\0"), FileManager.default.isReadableFile(atPath: path) else { throw AgentFailure("CONTENT_UNREADABLE") }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { throw AgentFailure("CONTENT_UNREADABLE") }
                let url = URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)
                if isDirectory.boolValue { _ = state.handleDroppedFileURLs([url]) }
                else { state.openFile(url: url) }
            } else if let raw = request.url {
                guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw AgentFailure("INVALID_REQUEST") }
                state.openWeb(url: url)
            } else {
                // 文件、图片、HTML 与文本沿用宿主解析，全部保留新箔的无痕属性。
                let files = delegate.clipboardFileURLs()
                if !files.isEmpty {
                    guard files.count <= 96 else { throw AgentFailure("RESOURCE_LIMIT") }
                    _ = state.handleDroppedFileURLs(files)
                } else if let image = delegate.clipboardImage() {
                    let representation = AppDelegate.clipboardImageRepresentation(from: .general)
                    guard representation?.data.count ?? 0 <= AgentLimits.fileBytes else { throw AgentFailure("CONTENT_TOO_LARGE") }
                    state.openImage(image: image, imageSource: .clipboard, originalData: representation?.data, filenameExtension: representation?.ext ?? "png")
                } else if let html = NSPasteboard.general.string(forType: .html) {
                    guard html.utf8.count <= AgentLimits.textBytes, state.openHTML(html) else { throw AgentFailure("CONTENT_UNREADABLE") }
                } else {
                    guard let text = NSPasteboard.general.string(forType: .string), text.utf8.count <= AgentLimits.textBytes else { throw AgentFailure("CONTENT_UNREADABLE") }
                    if let url = AppState.websiteURL(fromClipboardText: text) { state.openWeb(url: url) }
                    else { state.openText(text, isMarkdown: true) }
                }
            }
            delegate.prepareNewWindowFrame(for: controller); delegate.addWindowController(controller)
            if !NSApp.isHidden { controller.showWindow(nil) }
            response.window = snapshot(controller); response.status = "accepted"; response.operation = openOperation(controller)
            return true
        case "focus":
            let controller = try target(request.board_id)
            delegate.activateWindow(controller); response.window = snapshot(controller)
            return true
        case "window.frame":
            let controller = try target(request.board_id)
            guard let window = controller.window, let input = request.frame,
                  [input.x, input.y, input.width, input.height].allSatisfy(\.isFinite), input.width > 0, input.height > 0,
                  let screen = NSScreen.screens.first(where: { String(describing: $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]!) == request.screen_id }) else { throw AgentFailure("INVALID_REQUEST") }
            let area = screen.visibleFrame
            let width = min(area.width, max(window.minSize.width, input.width))
            let height = min(area.height, max(window.minSize.height, input.height))
            let x = min(max(area.minX, area.minX + input.x), area.maxX - width)
            let y = min(max(area.minY, area.maxY - input.y - height), area.maxY - height)
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
            controller.appState.saveState(); response.window = snapshot(controller)
            return true
        case "set" where ["zoom", "navigator"].contains(request.property ?? ""):
            let controller = try target(request.board_id); let state = controller.appState
            if request.property == "navigator" {
                switch request.text_value {
                case "visible": state.setNavigatorPanelVisibilityMode(.always)
                case "hidden": state.setNavigatorPanelVisibilityMode(.hidden)
                case "auto": state.setNavigatorPanelVisibilityMode(.onHover)
                default: throw AgentFailure("INVALID_REQUEST")
                }
            } else {
                guard let value = request.value, value.isFinite else { throw AgentFailure("INVALID_REQUEST") }
                if state.webURL != nil { guard (0.25...5).contains(value) else { throw AgentFailure("INVALID_REQUEST") }; state.webZoom = value }
                else if state.isExtensionDocument || state.textURL != nil || !state.text.isEmpty { guard (0.5...3).contains(value) else { throw AgentFailure("INVALID_REQUEST") }; state.documentZoom = value }
                else if state.imageURL != nil { guard (0.05...8).contains(value) else { throw AgentFailure("INVALID_REQUEST") }; state.imageScale = value }
                else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
            }
            state.saveState(); response.window = snapshot(controller)
            return true
        case "media.status", "media.play", "media.pause", "media.seek", "media.next", "media.previous", "media.volume", "media.mute", "media.mode":
            let target = try target(request.board_id); let state = target.appState
            guard let controller = state.agentMediaController else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
            let initial = try mediaState(state)
            var completed: (@MainActor () -> Bool)?
            let actions: [String: MediaPlaybackActionKind] = ["media.play": .play, "media.pause": .pause, "media.seek": .seek, "media.next": .next, "media.previous": .previous]
            if let action = actions[request.action], let session = state.extensionSession,
               session.mediaPlayback?.allows(action, queueItemCount: session.playbackQueue?.items.count ?? 0) != true {
                // 已在目标播放/暂停状态时 setter 保持幂等。
                if !(action == .play && controller.isPlaying) && !(action == .pause && !controller.isPlaying) { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
            }
            switch request.action {
            case "media.play": controller.play(); completed = { controller.isPlaying }
            case "media.pause": controller.pause(); completed = { !controller.isPlaying && state.extensionPlaybackPendingWrites.isEmpty }
            case "media.seek":
                guard let value = request.value, value.isFinite, let duration = initial.duration,
                      ["by", "to"].contains(request.property ?? "") else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
                let time = request.property == "by" ? controller.currentTime + value : value
                guard (0...duration).contains(time) else { throw AgentFailure("INVALID_REQUEST") }
                controller.seek(to: time); completed = { abs(controller.currentTime - time) <= 0.5 && state.extensionPlaybackPendingWrites.isEmpty }
            case "media.next", "media.previous":
                let item = state.fileList?.currentID ?? state.extensionSession?.playbackQueue?.currentItemID
                guard request.action == "media.next" ? controller.playNextItem() : controller.playPreviousItem() else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
                response.status = "accepted"
                completed = { (state.fileList?.currentID ?? state.extensionSession?.playbackQueue?.currentItemID) != item }
            case "media.volume":
                guard controller.supportsVolumeControl else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
                guard let value = Double(request.text_value ?? ""), value.isFinite, (0...1).contains(value) else { throw AgentFailure("INVALID_REQUEST") }
                controller.setVolume(Float(value))
                completed = { abs(Double(controller.volume) - value) < 0.02 }
            case "media.mute":
                guard controller.supportsVolumeControl else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
                guard ["true", "false"].contains(request.text_value ?? "") else { throw AgentFailure("INVALID_REQUEST") }
                let desired = request.text_value == "true"
                if controller.isMuted != desired { controller.toggleMute() }
                completed = { controller.isMuted == desired }
            case "media.mode":
                guard controller.supportsPlaybackModeControl else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
                guard let mode = MediaPlaybackMode(rawValue: request.text_value ?? "") else { throw AgentFailure("INVALID_REQUEST") }
                state.mediaPlaybackMode = mode
            default: break
            }
            response.media = try mediaState(state); response.window = snapshot(target)
            if let completed { response.status = "accepted"; response.operation = registerOperation(target, ready: completed) }
            return true
        default: return false
        }
    }
}

extension ApplicationControlService {
    func configuration(_ request: AgentRequest) throws -> [AgentConfiguration] {
        let settings = SettingsStore.shared
        func all() -> [AgentConfiguration] {
            [AgentConfiguration(key: "search.local-files.enabled", type: "boolean", value: String(LocalFileSearchSettings.shared.isEnabled), default_value: "true"),
             AgentConfiguration(key: "apple-music.library.enabled", type: "boolean", value: String(settings.appleMusicLibraryEnabled), default_value: "false"),
             AgentConfiguration(key: "search.apple-music.enabled", type: "boolean", value: String(settings.appleMusicSearchEnabled), default_value: "true", dependencies: ["apple-music.library.enabled"]),
             AgentConfiguration(key: "document.default-theme", type: "string", value: settings.defaultDocumentThemeID, default_value: DocumentThemeCatalog.defaultThemeId, choices: DocumentThemeCatalog.shared.presets.map(\.id)),
             AgentConfiguration(key: "document.default-font-size", type: "number", value: String(settings.defaultDocumentFontSize), default_value: "16", minimum: 8, maximum: 48),
             AgentConfiguration(key: "startup.behavior", type: "string", value: settings.startupBehavior.rawValue, default_value: "newWindow", choices: StartupBehavior.allCases.map(\.rawValue)),
             AgentConfiguration(key: "history.remove-missing.enabled", type: "boolean", value: String(settings.automaticallyRemoveMissingHistory), default_value: "true"),
             AgentConfiguration(key: "media.seek-step", type: "number", value: String(settings.mediaSeekStepInterval), default_value: "5", minimum: 1, maximum: 60),
             AgentConfiguration(key: "media.controls-auto-hide", type: "number", value: String(settings.mediaPlaybackControlsAutoHideInterval), default_value: "2", minimum: 1, maximum: 10)]
        }
        if request.action == "config.list" { return all() }
        guard let definition = all().first(where: { $0.key == request.property }) else { throw AgentFailure("UNKNOWN_CONFIGURATION") }
        if request.action == "config.set" {
            guard let value = request.text_value else { throw AgentFailure("INVALID_REQUEST") }
            if definition.type == "boolean", !["true", "false"].contains(value) { throw AgentFailure("INVALID_REQUEST") }
            if value == "true", definition.dependencies.contains("apple-music.library.enabled"), !settings.appleMusicLibraryEnabled { throw AgentFailure("UNMET_PREREQUISITES") }
            switch definition.key {
            case "search.local-files.enabled": LocalFileSearchSettings.shared.isEnabled = value == "true"
            case "apple-music.library.enabled": settings.appleMusicLibraryEnabled = value == "true"
            case "search.apple-music.enabled": settings.appleMusicSearchEnabled = value == "true"
            case "document.default-theme":
                guard DocumentThemeCatalog.shared.presets.contains(where: { $0.id == value }) else { throw AgentFailure("INVALID_REQUEST") }
                settings.defaultDocumentThemeID = value
            case "document.default-font-size":
                guard let number = Double(value), number.isFinite, (8...48).contains(number) else { throw AgentFailure("INVALID_REQUEST") }
                settings.defaultDocumentFontSize = number
            case "startup.behavior":
                guard let behavior = StartupBehavior(rawValue: value) else { throw AgentFailure("INVALID_REQUEST") }
                settings.startupBehavior = behavior
            case "history.remove-missing.enabled": settings.automaticallyRemoveMissingHistory = value == "true"
            case "media.seek-step", "media.controls-auto-hide":
                guard let number = Double(value), number.isFinite, (definition.minimum!...definition.maximum!).contains(number) else { throw AgentFailure("INVALID_REQUEST") }
                if definition.key == "media.seek-step" { settings.mediaSeekStepInterval = number }
                else { settings.mediaPlaybackControlsAutoHideInterval = number }
            default: throw AgentFailure("UNKNOWN_CONFIGURATION")
            }
        }
        if request.action == "config.set" { NotificationCenter.default.post(name: .agentConfigurationDidChange, object: nil) }
        return all().filter { $0.key == definition.key }
    }

    /// 读取异步入口只提取当前已加载内容，不悄悄重开来源文件。
    func executeAsync(_ request: AgentRequest, response: inout AgentResponse) async throws {
        guard AgentCommandCatalog.valid(request) else { throw AgentFailure("INVALID_REQUEST") }
        if request.action == "history.search" {
            guard let query = request.query, query.utf8.count <= 1024, let limit = request.limit, (1...20).contains(limit) else { throw AgentFailure("INVALID_REQUEST") }
            response.history = await HistoryRepository.shared.search(query, limit: limit).map {
                AgentHistoryItem(id: $0.id.uuidString, title: String($0.title.prefix(256)), type: String(describing: $0.contentKind), snippet: $0.matchedSnippet.map { String($0.prefix(256)) })
            }
            return
        }
        if request.action == "history.open" {
            guard let raw = request.target_id, let id = UUID(uuidString: raw), let config = HistoryRepository.shared.config(id: id) else { throw AgentFailure("HISTORY_NOT_FOUND") }
            guard config.appleMusicReference == nil || SettingsStore.shared.appleMusicLibraryEnabled else { throw AgentFailure("UNMET_PREREQUISITES") }
            guard delegate.windowControllers.count < 96 else { throw AgentFailure("WINDOW_LIMIT") }
            let controller: FloatingWindowController
            if request.incognito == true {
                let state = AppState(isIncognito: true)
                guard state.loadConfig(config, preservesIdentity: true) else { throw AgentFailure("CONTENT_LOAD_FAILED") }
                state.startTerminalForExplicitOpen()
                controller = FloatingWindowController(appState: state)
                delegate.prepareNewWindowFrame(for: controller); delegate.addWindowController(controller)
                if !NSApp.isHidden { controller.showWindow(nil) }
            } else {
                guard let loaded = delegate.openHistoryConfig(config: config, id: id, reuseBlankWindow: false) else { throw AgentFailure("CONTENT_LOAD_FAILED") }
                controller = loaded
            }
            response.window = snapshot(controller); response.status = "accepted"; response.operation = openOperation(controller)
            return
        }
        if request.action == "export" {
            try await export(request, response: &response); return
        }
        if request.action == "search" || (request.action == "read" && (request.source != nil && request.source != "original" || request.page != nil)) {
            let controller = try target(request.board_id); let state = controller.appState
            state.contentSearch.agentBindRoot(controller.window?.contentView)
            guard !state.isLoading else { throw AgentFailure("CONTENT_LOADING") }
            let identity = contentVersion(state)
            let text: String
            let source = request.source ?? "original"
            if let page = request.page {
                guard state.isPDFDocument, let view = state.pdfNavigator?.view, let document = view.document,
                      (1...document.pageCount).contains(page), let data = document.dataRepresentation() else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
                guard data.count <= AgentLimits.fileBytes else { throw AgentFailure("CONTENT_TOO_LARGE") }
                text = try await withCheckedThrowingContinuation { continuation in
                    AgentContent.io.async {
                        guard let document = PDFDocument(data: data), let page = document.page(at: page - 1) else { continuation.resume(throwing: AgentFailure("EXTRACTION_FAILED")); return }
                        continuation.resume(returning: page.string ?? "")
                    }
                }
            } else if source == "terminal" {
                guard let terminal = state.terminalSession else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
                let output = terminal.outputTranscript ?? ""
                if let tail = request.tail {
                    guard (1...2000).contains(tail) else { throw AgentFailure("INVALID_REQUEST") }
                    text = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(tail).joined(separator: "\n")
                } else { text = output }
            } else if source == "ocr" {
                guard state.imageURL != nil else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
                guard let ocr = state.imageOCRText else { throw AgentFailure("TEXT_NOT_EXTRACTED") }
                text = ocr
            } else if source == "rendered" {
                text = try await state.contentSearch.agentRenderedText()
            } else {
                guard state.textURL != nil || state.agentKind == .text || state.agentKind == .markdown || !state.text.isEmpty else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
                text = state.text
            }
            guard delegate.windowControllers.contains(where: { $0 === controller }) else { throw AgentFailure("WINDOW_CLOSED") }
            guard contentVersion(state) == identity else { throw AgentFailure("STALE_CONTENT") }
            let version = request.page != nil ? contentVersion(state) : source == "original" ? digest(state.id.uuidString + "\0" + text) : digest(state.id.uuidString + "\0" + source + "\0" + text)
            if let expected = request.content_version, expected != version { throw AgentFailure("STALE_CONTENT") }
            guard let offset = request.offset, offset >= 0, offset == 0 || request.content_version != nil,
                  let limit = request.limit, (1...(request.action == "search" ? 20 : 3000)).contains(limit) else { throw AgentFailure("INVALID_REQUEST") }
            if request.action == "search" {
                guard let query = request.query, !query.isEmpty, query.utf8.count <= 1024 else { throw AgentFailure("INVALID_REQUEST") }
                response.search = try await withCheckedThrowingContinuation { continuation in
                    AgentContent.io.async {
                        let scalars = text.unicodeScalars
                        guard let start = scalars.index(scalars.startIndex, offsetBy: offset, limitedBy: scalars.endIndex) else { continuation.resume(throwing: AgentFailure("INVALID_REQUEST")); return }
                        var range = start..<text.endIndex
                        var matches: [AgentSearchMatch] = []
                        var next: Int?
                        while let match = text.range(of: query, options: [.caseInsensitive], range: range) {
                            if matches.count == limit { next = scalars.distance(from: scalars.startIndex, to: match.lowerBound); break }
                            let position = scalars.distance(from: scalars.startIndex, to: match.lowerBound)
                            let end = scalars.index(match.upperBound, offsetBy: 80, limitedBy: scalars.endIndex) ?? scalars.endIndex
                            matches.append(AgentSearchMatch(offset: position, length: scalars.distance(from: match.lowerBound, to: match.upperBound), snippet: String(text[match.lowerBound..<end]), line: text[..<match.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }))
                            range = match.upperBound..<text.endIndex
                        }
                        continuation.resume(returning: AgentSearchPage(content_version: version, matches: matches, next_offset: next))
                    }
                }
            } else {
                let scalars = text.unicodeScalars
                guard let start = scalars.index(scalars.startIndex, offsetBy: offset, limitedBy: scalars.endIndex) else { throw AgentFailure("INVALID_REQUEST") }
                let end = scalars.index(start, offsetBy: limit, limitedBy: scalars.endIndex) ?? scalars.endIndex
                response.text_page = AgentTextPage(content_id: state.id.uuidString, content_version: version, text: String(scalars[start..<end]), offset: offset, next_offset: end == scalars.endIndex ? nil : offset + scalars.distance(from: start, to: end), truncated: end != scalars.endIndex)
                if text.isEmpty { response.warnings.append("NO_TEXT") }
            }
            guard contentVersion(state) == identity else { throw AgentFailure("STALE_CONTENT") }
            return
        }
        try execute(request, response: &response)
    }

    private func export(_ request: AgentRequest, response: inout AgentResponse) async throws {
        let controller = try target(request.board_id); let state = controller.appState
        state.contentSearch.agentBindRoot(controller.window?.contentView)
        guard let path = request.output, path.hasPrefix("/"), !path.contains("\0"), ["original", "png"].contains(request.format ?? "") else { throw AgentFailure("INVALID_REQUEST") }
        let output = URL(fileURLWithPath: path).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path) || request.overwrite == true else { throw AgentFailure("OUTPUT_EXISTS") }
        let payload: ContentSavePayload
        if request.format == "original" {
            guard state.canSaveAs, let content = state.contentSavePayload else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
            if case .webArchive = content { payload = .archive(try await state.contentSearch.agentWebArchive()) }
            else { payload = content }
        } else {
            guard state.canSaveContentImage, let root = controller.window?.contentView else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
            let image = try await FoilContentCapture.capture(in: root, state: state)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw AgentFailure("EXPORT_FAILED") }
            payload = .archive(try ContentImageFormat.png.encode(cgImage))
        }
        guard !delegate.agentTerminal.paused else { throw AgentFailure("CONTROL_PAUSED") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            AgentContent.io.async {
                let staged = output.deletingLastPathComponent().appendingPathComponent(".foil-export-\(UUID())")
                defer { try? FileManager.default.removeItem(at: staged) }
                do {
                    try payload.write(to: staged)
                    // 同目录暂存后原子提交；不覆盖模式使用 exclusive hard link 关闭 TOCTOU 竞态。
                    if request.overwrite == true {
                        guard rename(staged.path, output.path) == 0 else { throw AgentFailure("EXPORT_FAILED") }
                    } else {
                        guard link(staged.path, output.path) == 0 else { throw AgentFailure(errno == EEXIST ? "OUTPUT_EXISTS" : "EXPORT_FAILED") }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error as? AgentFailure ?? AgentFailure("EXPORT_FAILED")) }
            }
        }
        response.output = output.path
    }
}

extension ApplicationControlService {
    func navigationVersion(_ state: AppState, contributions: [NavigatorContribution]) throws -> String {
        // 当前位置与播放指示不属于目录结构版本；翻页或播放不会使目录游标失效。
        let stable = contributions.map { contribution in
            var copy = contribution
            copy.selectedItemIDs = []
            copy.items = copy.items.map { item in var copy = item; copy.isCurrent = false; return copy }
            return copy
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(state.id.uuidString + "\0" + String(decoding: try encoder.encode(stable), as: UTF8.self))
    }
    func navigationOperation(_ target: FloatingWindowController, locator: AgentNavigationTarget) -> AgentOperation {
        registerOperation(target) { [weak state = target.appState] in
            guard let contribution = state?.navigatorContributions.first(where: { $0.id == locator.contribution_id }) else { return false }
            return contribution.selectedItemIDs.contains(locator.item_id) || contribution.items.contains { $0.id == locator.item_id && $0.isCurrent }
        }
    }
    func executeItems(_ request: AgentRequest, response: inout AgentResponse) throws {
        let target = try target(request.board_id); let state = target.appState
        guard !state.isLoading else { throw AgentFailure("CONTENT_LOADING") }
        let contributions = state.navigatorContributions
        guard !contributions.isEmpty else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
        let version = try navigationVersion(state, contributions: contributions)
        if let expected = request.content_version, expected != version { throw AgentFailure("STALE_CONTENT") }
        if request.action != "items" {
            guard request.content_version != nil, let raw = request.target_id, raw.utf8.count <= 8192,
                  let data = Data(base64Encoded: raw), let locator = try? JSONDecoder().decode(AgentNavigationTarget.self, from: data),
                  let contribution = contributions.first(where: { $0.id == locator.contribution_id }), contribution.allowedActions.contains(.activate),
                  contribution.items.contains(where: { $0.id == locator.item_id && $0.isEnabled }) else { throw AgentFailure("STALE_TARGET") }
            state.performNavigatorAction(.init(contributionID: locator.contribution_id, kind: .activate, itemIDs: [locator.item_id]))
            response.status = "accepted"; response.operation = navigationOperation(target, locator: locator); response.window = snapshot(target)
            return
        }
        guard let offset = request.offset, offset >= 0, offset == 0 || request.content_version != nil,
              let limit = request.limit, (1...20).contains(limit) else { throw AgentFailure("INVALID_REQUEST") }
        let encoder = JSONEncoder()
        let items = try contributions.flatMap { contribution in
            try contribution.items.map { item in
                AgentOutlineItem(target_id: try encoder.encode(AgentNavigationTarget(contribution_id: contribution.id, item_id: item.id)).base64EncodedString(), contribution_id: contribution.id, item_id: item.id, parent_id: item.parentID, title: item.title, enabled: item.isEnabled, current: item.isCurrent)
            }
        }
        guard offset <= items.count else { throw AgentFailure("INVALID_REQUEST") }
        var page: [AgentOutlineItem] = []
        for item in items.dropFirst(offset).prefix(limit) {
            guard try encoder.encode(page + [item]).count <= 20_000 else { if page.isEmpty { throw AgentFailure("ITEM_TOO_LARGE") }; break }
            page.append(item)
        }
        response.outline = AgentOutlinePage(content_id: state.id.uuidString, content_version: version, items: page, next_offset: offset + page.count < items.count ? offset + page.count : nil)
    }
    func navigatePosition(_ request: AgentRequest, response: inout AgentResponse) throws {
        let controller = try target(request.board_id); let state = controller.appState
        state.contentSearch.agentBindRoot(controller.window?.contentView)
        guard !state.isLoading else { throw AgentFailure("CONTENT_LOADING") }
        guard let version = request.content_version, [request.page != nil, request.line != nil, request.progress != nil].filter({ $0 }).count == 1 else { throw AgentFailure("INVALID_REQUEST") }
        if let page = request.page {
            guard version == contentVersion(state) else { throw AgentFailure("STALE_CONTENT") }
            guard let view = state.pdfNavigator?.view, let document = view.document, (1...document.pageCount).contains(page), let target = document.page(at: page - 1) else { throw AgentFailure("CAPABILITY_UNAVAILABLE") }
            view.go(to: target)
            response.operation = registerOperation(controller) { view.currentPage === target }
        } else {
            guard version == digest(state.id.uuidString + "\0" + state.text) else { throw AgentFailure("STALE_CONTENT") }
            if let line = request.line, line < 1 { throw AgentFailure("INVALID_REQUEST") }
            try state.contentSearch.agentNavigate(line: request.line, progress: request.progress)
        }
        response.status = response.operation == nil ? "ready" : "accepted"
        response.window = snapshot(controller)
    }
    func availability(_ state: AppState) -> [AgentCapability] {
        let loading = state.isLoading
        let controller = state.agentMediaController
        let base = ["window.inspect", "window.reveal", "window.hide", "window.close", "window.opacity", "window.incognito", "window.pinned", "window.border", "window.title", "window.focus", "window.frame"]
        var result = base.map { AgentCapability(name: $0, available: true) }
        func add(_ name: String, _ supported: Bool, _ reason: String = "unsupported_content") {
            result.append(AgentCapability(name: name, available: supported && !loading, reason: loading ? "content_loading" : supported ? nil : reason))
        }
        add("content.read.original", supportsTextRead(state))
        add("content.read.pdf", state.isPDFDocument && state.pdfNavigator?.view?.document != nil, "requires_page")
        add("content.read.rendered", state.contentSearch.agentCanReadRendered)
        add("content.read.terminal", state.terminalSession != nil)
        add("content.read.ocr", state.imageOCRText != nil, "text_not_extracted")
        add("content.outline", state.navigatorContributions.contains { $0.style == .outline })
        add("content.items", !state.navigatorContributions.isEmpty)
        add("content.navigate", !state.navigatorContributions.isEmpty || supportsTextRead(state))
        add("content.search", supportsTextRead(state) || state.contentSearch.agentCanReadRendered || state.terminalSession != nil || state.imageOCRText != nil || state.isPDFDocument)
        add("media.status", controller != nil)
        for (name, action) in [("media.play", MediaPlaybackActionKind.play), ("media.pause", .pause), ("media.seek", .seek), ("media.next", .next), ("media.previous", .previous)] {
            let supported = controller != nil && (state.extensionSession?.mediaPlayback.map { $0.allows(action, queueItemCount: state.extensionSession?.playbackQueue?.items.count ?? 0) } ?? (action != .seek || (controller?.duration ?? 0) > 0))
            add(name, supported, "backend_or_state_unavailable")
        }
        add("media.volume", controller?.supportsVolumeControl == true)
        add("media.mute", controller?.supportsVolumeControl == true)
        add("media.mode", controller?.supportsPlaybackModeControl == true)
        return result
    }
}

extension Notification.Name {
    static let agentConfigurationDidChange = Notification.Name("AgentConfigurationDidChange")
}
