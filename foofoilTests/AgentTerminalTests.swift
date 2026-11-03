import AppKit
import Testing
import FoofoilExtensionKit
@testable import foofoil

@MainActor
@Suite(.sharedApplicationState, .serialized)
struct AgentTerminalTests {
    @MainActor private final class Fixture {
        let delegate = AppDelegate()
        let previous = NSApp.delegate
        let root: URL
        let url: URL
        let terminal: AgentTerminal
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            url = root.appendingPathComponent("reference.txt")
            try Data("first".utf8).write(to: url)
            terminal = delegate.agentTerminal
            NSApp.delegate = delegate
        }
        func cleanup() {
            for controller in delegate.windowControllers { controller.close() }
            NSApp.delegate = previous
            try? FileManager.default.removeItem(at: root)
        }
        func request(_ action: String, token: String = String(repeating: "a", count: 64), board: String? = nil) -> AgentRequest {
            var request = AgentRequest(action: action, run_id: terminal.runID, credential: token, board_id: board)
            if action == "show" || action == "update" { request.path = url.path }
            if action == "show" { request.incognito = true }
            return request
        }
        func call(_ request: AgentRequest, delivered: [URL]? = nil) async -> AgentResponse {
            await withCheckedContinuation { continuation in
                terminal.receive(request, delivered: delivered ?? [url]) { continuation.resume(returning: $0) }
            }
        }
        func authorize(_ token: String = String(repeating: "a", count: 64)) async {
            _ = await call(request("authorize", token: token))
        }
    }

    @Test func ordinaryOpenReportsIncognitoAndPreservesPrivacy() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var request = AgentRequest(action: "open")
        request.path = f.url.path
        request.incognito = true
        var response = AgentResponse(request_id: request.request_id, run_id: f.terminal.runID, status: "ready")
        try f.delegate.applicationControl.execute(request, response: &response)
        #expect(response.status == "accepted")
        #expect(response.window?.incognito == true)
        #expect(response.window?.observed_at.isEmpty == false)
        let state = try #require(f.delegate.windowControllers.first?.appState)
        #expect(state.isIncognito)
        #expect(HistoryRepository.shared.config(id: state.id) == nil)
    }

    @Test func incognitoSetterIsIdempotentAndCapabilitiesAreScoped() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let state = AppState(isIncognito: true)
        let window = FloatingWindowController(appState: state)
        f.delegate.addWindowController(window)
        var request = AgentRequest(action: "set", board_id: window.controlID)
        request.property = "incognito"
        request.boolean_value = true
        var response = AgentResponse(request_id: request.request_id, run_id: f.terminal.runID)
        try f.delegate.applicationControl.execute(request, response: &response)
        try f.delegate.applicationControl.execute(request, response: &response)
        #expect(state.isIncognito)
        request.boolean_value = false
        try f.delegate.applicationControl.execute(request, response: &response)
        #expect(!state.isIncognito)
        request.property = "pinned"
        request.boolean_value = false
        try f.delegate.applicationControl.execute(request, response: &response)
        #expect(response.window?.pinned == false)
        request.property = "title"
        request.boolean_value = nil
        request.title = "参考资料"
        try f.delegate.applicationControl.execute(request, response: &response)
        #expect(response.window?.title == "参考资料")
        request.title = nil
        request.property = "border"
        request.boolean_value = true
        try f.delegate.applicationControl.execute(request, response: &response)
        #expect(response.window?.border == true)
        var query = AgentRequest(action: "capabilities", board_id: window.controlID)
        response = AgentResponse(request_id: query.request_id, run_id: f.terminal.runID)
        try f.delegate.applicationControl.execute(query, response: &response)
        #expect(response.capabilities?.contains("window.incognito") == true)
        var list = AgentRequest(action: "list")
        list.incognito = true
        try f.delegate.applicationControl.execute(list, response: &response)
        #expect(response.windows?.isEmpty == true)
        query.board_id = "missing"
        #expect(throws: AgentFailure.self) { try f.delegate.applicationControl.execute(query, response: &response) }
    }

    @Test func readPagesUnicodeAndRejectsStaleContent() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let state = AppState(isIncognito: true)
        state.text = "甲😀乙"
        let window = FloatingWindowController(appState: state)
        f.delegate.addWindowController(window)
        var capabilities = AgentRequest(action: "capabilities", board_id: window.controlID)
        var discovered = AgentResponse(request_id: capabilities.request_id, run_id: f.terminal.runID)
        try f.delegate.applicationControl.execute(capabilities, response: &discovered)
        #expect(discovered.capabilities?.contains("content.read.original") == true)
        capabilities.board_id = nil
        var request = AgentRequest(action: "read", board_id: window.controlID)
        request.offset = 1; request.limit = 2
        var response = AgentResponse(request_id: request.request_id, run_id: f.terminal.runID)
        #expect(throws: AgentFailure.self) { try f.delegate.applicationControl.execute(request, response: &response) }
        request.offset = 0
        try f.delegate.applicationControl.execute(request, response: &response)
        #expect(response.text_page?.text == "甲😀")
        #expect(response.text_page?.next_offset == 2)
        request.offset = 2; request.content_version = response.text_page?.content_version
        try f.delegate.applicationControl.execute(request, response: &response)
        #expect(response.text_page?.text == "乙")
        state.text = "changed"
        #expect(throws: AgentFailure.self) { try f.delegate.applicationControl.execute(request, response: &response) }
    }

    @Test func outlinePagesAndRejectsChangedNavigation() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let state = AppState(isIncognito: true)
        state.builtInNavigatorContributions = [NavigatorContribution(id: "contents", titleLocalizationKey: "Contents", style: .outline, items: [NavigatorItem(id: "a", title: "甲"), NavigatorItem(id: "b", parentID: "a", title: "乙")])]
        let window = FloatingWindowController(appState: state)
        f.delegate.addWindowController(window)
        var request = AgentRequest(action: "outline", board_id: window.controlID)
        request.offset = 0; request.limit = 1
        var response = AgentResponse(request_id: request.request_id, run_id: f.terminal.runID)
        try f.delegate.applicationControl.execute(request, response: &response)
        #expect(response.outline?.items.first?.item_id == "a")
        #expect(response.outline?.next_offset == 1)
        var activated: String?
        state.builtInNavigatorActionHandler = { activated = $0.itemIDs.first }
        var navigation = AgentRequest(action: "navigate", board_id: window.controlID)
        navigation.content_version = response.outline?.content_version
        navigation.target_id = response.outline?.items.first?.target_id
        var navigationResponse = AgentResponse(request_id: navigation.request_id, run_id: f.terminal.runID)
        try f.delegate.applicationControl.execute(navigation, response: &navigationResponse)
        #expect(navigationResponse.status == "accepted")
        #expect(activated == "a")
        request.offset = 1; request.content_version = response.outline?.content_version
        try f.delegate.applicationControl.execute(request, response: &response)
        #expect(response.outline?.items.first?.parent_id == "a")
        state.builtInNavigatorContributions[0].items.removeLast()
        #expect(throws: AgentFailure.self) { try f.delegate.applicationControl.execute(request, response: &response) }
        #expect(throws: AgentFailure.self) { try f.delegate.applicationControl.execute(navigation, response: &navigationResponse) }
    }

    @Test func stableIdentityDedupAndRevisionPreserveActualWindow() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        await f.authorize()
        let show = f.request("show")
        let first = await f.call(show)
        let board = try #require(first.board_id)
        let window = try #require(f.delegate.windowControllers.first)
        let contentID = window.appState.id
        window.window?.setFrame(NSRect(x: 120, y: 180, width: 530, height: 360), display: false)
        window.appState.opacity = 0.72
        window.appState.isPinned = false
        window.appState.showBorder = false
        window.window?.orderOut(nil)
        let frame = window.window?.frame
        let opacity = window.appState.opacity
        let border = window.appState.showBorder
        let duplicate = await f.call(show)
        #expect(duplicate.board_id == board)
        #expect(f.delegate.windowControllers.count == 1)
        try Data("second".utf8).write(to: f.url)
        var update = f.request("update", board: board)
        update.expected_revision = 1
        let second = await f.call(update)
        #expect(second.revision == 2)
        #expect(window.appState.id == contentID)
        #expect(window.appState.text == "second")
        #expect(window.window?.frame == frame)
        #expect(window.window?.isVisible == false)
        #expect(window.appState.opacity == opacity)
        #expect(!window.appState.isPinned && window.appState.showBorder == border)
        update.request_id = UUID().uuidString
        #expect(await f.call(update).error == "REVISION_CONFLICT")
        #expect(window.appState.agentOwnership?.revision == 2)
        #expect(HistoryRepository.shared.config(id: contentID) == nil)
        window.appState.id = UUID()
        #expect(await f.call(f.request("list")).boards?.first?.board_id == board)
        _ = await f.call(f.request("close", board: board))
        #expect(f.delegate.windowControllers.isEmpty)
        #expect(await f.call(show).board_id == board)
        #expect(f.delegate.windowControllers.isEmpty)
    }

    @Test func authorizationAndManualTakeoverDoNotLeakBoards() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        await f.authorize()
        let first = await f.call(f.request("show"))
        let board = try #require(first.board_id)
        let other = String(repeating: "b", count: 64)
        await f.authorize(other)
        #expect(await f.call(f.request("list", token: other)).boards?.isEmpty == true)
        #expect(await f.call(f.request("update", token: other, board: board)).error == "BOARD_NOT_FOUND")
        #expect(await f.call(f.request("update", token: other, board: "does-not-exist")).error == "BOARD_NOT_FOUND")
        let state = try #require(f.delegate.windowControllers.first?.appState)
        state.resetContent()
        #expect(state.agentOwnership == nil)
        #expect(await f.call(f.request("update", board: board)).error == "BOARD_NOT_FOUND")
    }

    @Test func failedPreparationDoesNotClearOldContentOrIncrementRevision() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        await f.authorize()
        let show = await f.call(f.request("show"))
        let state = try #require(f.delegate.windowControllers.first?.appState)
        try FileManager.default.removeItem(at: f.url)
        #expect(await f.call(f.request("update", board: show.board_id)).error == "CONTENT_UNREADABLE")
        #expect(state.text == "first")
        #expect(state.agentOwnership?.revision == 1)
    }

    @Test func requestIDConflictAndRestartRejectOldCredentials() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        await f.authorize()
        let request = f.request("show")
        _ = await f.call(request)
        var conflict = request
        conflict.title = "different"
        #expect(await f.call(conflict).error == "REQUEST_ID_CONFLICT")
        var stale = f.request("list")
        stale.run_id = UUID().uuidString
        #expect(await f.call(stale).error == "PERMISSION_DENIED")
    }

    @Test func pauseAndRevocationBlockInFlightCommitsAndNeverReplay() async throws {
        for revoke in [false, true] {
            let f = try Fixture(); defer { f.cleanup() }
            await f.authorize()
            let shown = await f.call(f.request("show"))
            var resume: CheckedContinuation<Void, Never>?
            var started = false
            f.terminal.prepare = { url in
                started = true
                await withCheckedContinuation { resume = $0 }
                return try AgentContent.prepare(url)
            }
            let pending = Task { await f.call(f.request("update", board: shown.board_id)) }
            while !started { await Task.yield() }
            if revoke { f.terminal.revokeAll() }
            else { f.terminal.paused = true; f.terminal.paused = false }
            resume?.resume()
            #expect(await pending.value.error == (revoke ? "PERMISSION_DENIED" : "CONTROL_PAUSED"))
            #expect(f.delegate.windowControllers.first?.appState.text == "first")
            if revoke { #expect(await f.call(f.request("authorize")).error == "PERMISSION_DENIED") }
        }
    }

    @Test func userCloseDuringPreparationCannotRecreateWindow() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        await f.authorize()
        let shown = await f.call(f.request("show"))
        var resume: CheckedContinuation<Void, Never>?
        var started = false
        f.terminal.prepare = { url in
            started = true
            await withCheckedContinuation { resume = $0 }
            return try AgentContent.prepare(url)
        }
        let pending = Task { await f.call(f.request("update", board: shown.board_id)) }
        while !started { await Task.yield() }
        f.delegate.windowControllers.first?.close()
        resume?.resume()
        #expect(await pending.value.error == "BOARD_NOT_FOUND")
        #expect(f.delegate.windowControllers.isEmpty)
    }

    @Test func boundedFIFOAndDuplicatePendingRequestOnlyPrepareOnce() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        await f.authorize()
        let shown = await f.call(f.request("show"))
        var resume: CheckedContinuation<Void, Never>?
        var prepared = 0
        f.terminal.prepare = { url in
            prepared += 1
            if prepared == 1 { await withCheckedContinuation { resume = $0 } }
            return try AgentContent.prepare(url)
        }
        let request = f.request("update", board: shown.board_id)
        let first = Task { await f.call(request) }
        while prepared == 0 { await Task.yield() }
        let duplicate = Task { await f.call(request) }
        var queued = f.request("update", board: shown.board_id)
        queued.expected_revision = 2
        let second = Task { await f.call(queued) }
        await Task.yield()
        resume?.resume()
        #expect(await first.value.revision == 2)
        #expect(await duplicate.value.revision == 2)
        #expect(await second.value.revision == 3)
        #expect(prepared == 2)
    }

    @Test func markdownRemovesEveryImageBeforeHTMLImporter() {
        let markdown = "![local](file:///private/secret.png) ![remote](https://example.com/a.png)\n\n<img src='https://example.com/b'>\n\n```\n![literal](file:///x)\n```"
        let html = AppState.agentMarkdownHTML(AppState.cmarkToHTML(markdown), placeholder: "[unavailable]")
        #expect(!html.lowercased().contains("<img"))
        #expect(html.contains("[unavailable]"))
        #expect(html.contains("![literal]"))
    }

    @Test func fileValidationRejectsUnsupportedCorruptAndOversizedContent() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let unsupported = f.root.appendingPathComponent("script.html")
        try Data("<html>".utf8).write(to: unsupported)
        #expect(throws: AgentFailure.self) { try AgentContent.prepare(unsupported) }
        let image = f.root.appendingPathComponent("bad.png")
        try Data([1, 2, 3]).write(to: image)
        #expect(throws: AgentFailure.self) { try AgentContent.prepare(image) }
        try Data(repeating: 65, count: AgentLimits.textBytes + 1).write(to: f.url)
        #expect(throws: AgentFailure.self) { try AgentContent.prepare(f.url) }
    }

    @Test func ordinaryUpdatesUseOneReferenceOnlyHistoryAndRestoreAsHuman() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        await f.authorize()
        var request = f.request("show")
        request.incognito = false
        let shown = await f.call(request)
        let state = try #require(f.delegate.windowControllers.first?.appState)
        let id = state.id
        defer { if let config = HistoryRepository.shared.config(id: id) { HistoryManager.shared.removeFromHistory(config) } }
        try Data("updated".utf8).write(to: f.url)
        _ = await f.call(f.request("update", board: shown.board_id))
        #expect(state.id == id)
        let config = try #require(HistoryRepository.shared.config(id: id))
        let savedURL = URL(fileURLWithPath: try #require(config.textPath)).resolvingSymlinksInPath()
        #expect(savedURL == f.url.resolvingSymlinksInPath())
        #expect(config.text.isEmpty)
        let restored = AppState()
        #expect(restored.loadConfig(config))
        #expect(restored.text == "updated")
        #expect(restored.agentOwnership == nil)
        #expect(restored.agentReadOnly)
        #expect(restored.agentOwnership == nil)
        restored.openTextFile(url: f.url)
        #expect(!restored.agentReadOnly)
    }

    @Test func queueAndSessionLimitsRemainBoundedDuringPreparation() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        await f.authorize()
        var resume: CheckedContinuation<Void, Never>?
        var started = false
        f.terminal.prepare = { url in
            started = true
            await withCheckedContinuation { resume = $0 }
            return try AgentContent.prepare(url)
        }
        let pending = Task { await f.call(f.request("show")) }
        while !started { await Task.yield() }
        var replies: [AgentResponse] = []
        for _ in 0..<(AgentLimits.queue + 2) {
            f.terminal.receive(f.request("list"), delivered: []) { replies.append($0) }
        }
        #expect(replies.filter { $0.error == "QUEUE_FULL" }.count == 3)
        resume?.resume()
        #expect(await pending.value.error == nil)
        while replies.count < AgentLimits.queue + 2 { await Task.yield() }
        for index in 1..<AgentLimits.sessions {
            let token = String(format: "%064x", index)
            #expect(await f.call(f.request("authorize", token: token)).error == nil)
        }
        #expect(await f.call(f.request("authorize", token: String(repeating: "c", count: 64))).error == "PERMISSION_DENIED")
    }

    @Test func timeoutRespondsBeforeBlockedPreparationAndRetryCannotCommitLater() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let terminal = AgentTerminal(delegate: f.delegate, requestTimeout: 0.05)
        var request = AgentRequest(action: "authorize", run_id: terminal.runID, credential: String(repeating: "a", count: 64))
        terminal.receive(request, delivered: []) { _ in }
        var resume: CheckedContinuation<Void, Never>?
        terminal.prepare = { url in
            await withCheckedContinuation { resume = $0 }
            return try AgentContent.prepare(url)
        }
        request.action = "show"; request.path = f.url.path; request.incognito = true
        var results: [AgentResponse] = []
        terminal.receive(request, delivered: [f.url]) { results.append($0) }
        try await Task.sleep(for: .milliseconds(120))
        #expect(results.first?.error == "TIMEOUT")
        terminal.receive(request, delivered: [f.url]) { results.append($0) }
        #expect(results.count == 2 && results.last?.error == "TIMEOUT")
        resume?.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(f.delegate.windowControllers.isEmpty)
    }

    @Test func svgPreparationAndTypeChangeKeepSmallActualWindowFrame() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        await f.authorize()
        let svg = f.root.appendingPathComponent("diagram.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 200 100\"><rect width=\"200\" height=\"100\" fill=\"red\"/></svg>".utf8).write(to: svg)
        var request = f.request("show"); request.path = svg.path
        let shown = await f.call(request, delivered: [svg])
        #expect(shown.error == nil)
        let controller = try #require(f.delegate.windowControllers.first)
        #expect(controller.appState.agentSVGData != nil)
        #expect(controller.appState.loadImage(from: svg)?.size == NSSize(width: 200, height: 100))
        controller.window?.setFrame(NSRect(x: 200, y: 200, width: 80, height: 80), display: false)
        let frame = controller.window?.frame
        controller.appState.textFontSize = 25
        controller.appState.imageScale = 2
        #expect(await f.call(f.request("update", board: shown.board_id)).revision == 2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.window?.frame == frame)
        #expect(controller.appState.imageScale == 1)
        #expect(controller.appState.textFontSize == AppState.defaultTextFontSize)
        #expect(controller.appState.agentSVGData == nil)
        #expect(!controller.appState.showBorder)
        #expect(controller.window?.hasShadow == false)
        #expect(controller.appState.supportsBorderToggle)
    }

    @Test func sourceIOCannotBlockTimeoutResponseTransport() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let terminal = AgentTerminal(delegate: f.delegate, requestTimeout: 0.05)
        let token = String(repeating: "a", count: 64)
        terminal.receive(AgentRequest(action: "authorize", run_id: terminal.runID, credential: token), delivered: []) { _ in }
        let fence = DispatchSemaphore(value: 0)
        AgentContent.io.async { fence.wait() }
        defer { fence.signal() }
        var request = AgentRequest(action: "show", run_id: terminal.runID, credential: token)
        request.path = f.url.path; request.incognito = true
        let result = MainActorTestValue<AgentResponse?>(nil)
        terminal.receive(request, delivered: [f.url]) { response in
            AgentContent.transport.async { Task { @MainActor in result.value = response } }
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(result.value?.error == "TIMEOUT")
        #expect(f.delegate.windowControllers.isEmpty)
    }
    @Test func operationsObserveOpenFailureAndClosedWindows() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        await f.authorize()
        var open = f.request("open")
        open.path = f.url.path; open.incognito = true
        let accepted = await f.call(open)
        let operation = try #require(accepted.operation)
        #expect(accepted.status == "accepted")
        try await Task.sleep(for: .milliseconds(150))
        var wait = f.request("wait"); wait.operation_id = operation.id
        let ready = await f.call(wait)
        #expect(ready.operation?.status == "ready")
        let window = try #require(f.delegate.windowControllers.first)
        window.appState.agentLoadError = "CONTENT_LOAD_FAILED"
        let failed = f.delegate.applicationControl.registerOperation(window) { false }
        try await Task.sleep(for: .milliseconds(150))
        wait.request_id = UUID().uuidString; wait.operation_id = failed.id
        #expect(await f.call(wait).operation?.error == "CONTENT_LOAD_FAILED")
        window.appState.agentLoadError = nil
        let closed = f.delegate.applicationControl.registerOperation(window) { false }
        window.close()
        try await Task.sleep(for: .milliseconds(150))
        wait.request_id = UUID().uuidString; wait.operation_id = closed.id
        #expect(await f.call(wait).operation?.error == "WINDOW_CLOSED")
        wait.request_id = UUID().uuidString; wait.operation_id = "previous-run:operation"
        #expect(await f.call(wait).error == "HANDLE_EXPIRED")
    }

    @Test func itemsVersionIgnoresSelectionButRejectsReplacement() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let state = AppState(isIncognito: true)
        state.builtInNavigatorContributions = [NavigatorContribution(id: "list", titleLocalizationKey: "Contents", style: .flat, items: [NavigatorItem(id: "a", title: "甲"), NavigatorItem(id: "b", title: "乙")], allowedActions: [.activate])]
        let window = FloatingWindowController(appState: state); f.delegate.addWindowController(window)
        var request = AgentRequest(action: "items", board_id: window.controlID)
        request.offset = 0; request.limit = 1
        var response = AgentResponse(request_id: request.request_id, run_id: f.terminal.runID)
        try f.delegate.applicationControl.execute(request, response: &response)
        request.content_version = response.outline?.content_version
        state.builtInNavigatorContributions[0].items[0].isCurrent = true
        state.builtInNavigatorContributions[0].selectedItemIDs = ["a"]
        request.offset = 1
        try f.delegate.applicationControl.execute(request, response: &response)
        #expect(response.outline?.items.first?.item_id == "b")
        state.id = UUID()
        #expect(throws: AgentFailure.self) { try f.delegate.applicationControl.execute(request, response: &response) }
    }

    @Test func searchDoesNotNavigateAndExportRefusesOverwrite() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let state = AppState(isIncognito: true); state.text = "甲😀乙\n甲😀丙"; state.agentKind = .text
        let window = FloatingWindowController(appState: state); f.delegate.addWindowController(window)
        var search = AgentRequest(action: "search", board_id: window.controlID)
        search.query = "😀"; search.offset = 0; search.limit = 1
        var response = AgentResponse(request_id: search.request_id, run_id: f.terminal.runID)
        try await f.delegate.applicationControl.executeAsync(search, response: &response)
        #expect(response.search?.matches.first?.offset == 1)
        #expect(response.search?.next_offset == 5)
        search.offset = response.search?.next_offset; search.content_version = response.search?.content_version
        try await f.delegate.applicationControl.executeAsync(search, response: &response)
        #expect(response.search?.matches.first?.line == 2)
        var export = AgentRequest(action: "export", board_id: window.controlID)
        export.format = "original"; export.output = f.root.appendingPathComponent("export.txt").path
        try await f.delegate.applicationControl.executeAsync(export, response: &response)
        #expect(try String(contentsOfFile: export.output!, encoding: .utf8) == state.text)
        await #expect(throws: AgentFailure.self) { try await f.delegate.applicationControl.executeAsync(export, response: &response) }
    }

    @Test func configurationRejectsDependenciesAndPublishesUpdates() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let settings = SettingsStore.shared
        let library = settings.appleMusicLibraryEnabled
        let step = settings.mediaSeekStepInterval
        defer { settings.appleMusicLibraryEnabled = library; settings.mediaSeekStepInterval = step }
        settings.appleMusicLibraryEnabled = false
        var request = AgentRequest(action: "config.set")
        request.property = "search.apple-music.enabled"; request.text_value = "true"
        var response = AgentResponse(request_id: request.request_id, run_id: f.terminal.runID)
        #expect(throws: AgentFailure.self) { try f.delegate.applicationControl.execute(request, response: &response) }
        #expect(!settings.appleMusicLibraryEnabled)
        request.property = "media.seek-step"; request.text_value = "61"
        #expect(throws: AgentFailure.self) { try f.delegate.applicationControl.execute(request, response: &response) }
        request.text_value = "7"
        try f.delegate.applicationControl.execute(request, response: &response)
        #expect(settings.mediaSeekStepInterval == 7)
        #expect(response.configuration?.first?.value == "7.0")
        request.property = "arbitrary.defaults.key"
        #expect(throws: AgentFailure.self) { try f.delegate.applicationControl.execute(request, response: &response) }
    }

    @Test func readOnlyQueriesDoNotWaitForPendingWrites() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        await f.authorize()
        var preparation: CheckedContinuation<Void, Never>?
        f.terminal.prepare = { url in
            await withCheckedContinuation { preparation = $0 }
            return try AgentContent.prepare(url)
        }
        let pending = Task { await f.call(f.request("show")) }
        while preparation == nil { await Task.yield() }
        let query = await f.call(f.request("capabilities"))
        #expect(query.capabilities?.contains("operation.wait") == true)
        preparation?.resume()
        _ = await pending.value
    }

    @Test func pausingCancelsPendingOpenOperations() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let state = AppState(isIncognito: true)
        state.isLoading = true
        let window = FloatingWindowController(appState: state); f.delegate.addWindowController(window)
        let operation = f.delegate.applicationControl.openOperation(window)
        let generation = state.currentMediaRouteGeneration
        f.terminal.paused = true
        #expect(state.currentMediaRouteGeneration > generation)
        #expect(state.agentLoadError == "CONTROL_PAUSED")
        #expect(f.delegate.applicationControl.operations[operation.id]?.value.error == "CONTROL_PAUSED")
    }

}
