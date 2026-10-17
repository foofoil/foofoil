import AppKit
import CryptoKit
import Combine

struct AgentOwnership {
    let boardID: String
    let owner: String
    let caller: String
    var revision: UInt64
}

/// 复用 AppDelegate 的窗口集合；只保留授权和请求状态，不另建窗口生命周期。
@MainActor
final class AgentTerminal: ObservableObject {
    let runID = UUID().uuidString
    @Published var paused = false {
        didSet { if paused != oldValue { controlGeneration &+= 1 } }
    }
    private(set) var controlGeneration: UInt64 = 0
    private var sessions = Set<String>()
    private var revoked = Set<String>()
    private var creations: [Date] = []
    private struct Entry {
        let fingerprint: String
        let expires: Date
        var result: AgentResponse?
        var replies: [(AgentResponse) -> Void]
    }
    private struct Job {
        let request: AgentRequest
        let key: String
        let generation: UInt64
        let deadline: Date
    }
    private var ledger: [String: Entry] = [:]
    private var jobs: [Job] = []
    private var draining = false
    private var timeouts: [String: Task<Void, Never>] = [:]
    private let requestTimeout: TimeInterval
    weak var delegate: AppDelegate?
    /// 测试可挂起准备阶段以检查关闭、暂停和撤销竞态。
    var prepare: (URL) async throws -> AgentPreparedContent = { url in
        try await withCheckedThrowingContinuation { continuation in
            AgentContent.io.async {
                do { continuation.resume(returning: try AgentContent.prepare(url)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    init(delegate: AppDelegate? = nil, requestTimeout: TimeInterval = AgentLimits.timeout) {
        self.delegate = delegate
        self.requestTimeout = requestTimeout
    }

    func revokeAll() {
        revoked.formUnion(sessions)
        sessions.removeAll()
        controlGeneration &+= 1
        for controller in delegate?.windowControllers ?? [] { controller.appState.agentOwnership = nil }
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func owner(_ request: AgentRequest) -> String { hash(Data((request.credential ?? "").utf8)) }
    private func response(_ request: AgentRequest, error: String? = nil) -> AgentResponse {
        var value = AgentResponse(request_id: request.request_id, run_id: runID)
        if let error { value.status = "failed"; value.error = error }
        return value
    }

    func receive(_ request: AgentRequest, delivered: [URL], reply: @escaping (AgentResponse) -> Void) {
        guard request.protocol_version == AgentLimits.protocolVersion else { reply(response(request, error: "PROTOCOL_MISMATCH")); return }
        guard (1...128).contains(request.request_id.utf8.count), request.title?.utf8.count ?? 0 <= 512,
              request.caller?.utf8.count ?? 0 <= 128 else { reply(response(request, error: "INVALID_REQUEST")); return }
        if request.action == "hello" { reply(response(request)); return }
        guard request.run_id == runID, let credential = request.credential,
              credential.utf8.count == 64, credential.allSatisfy({ $0.isHexDigit }) else { reply(response(request, error: "PERMISSION_DENIED")); return }
        let owner = owner(request)
        if request.action == "authorize" {
            guard !revoked.contains(owner), sessions.contains(owner) || sessions.count + revoked.count < AgentLimits.sessions else { reply(response(request, error: "PERMISSION_DENIED")); return }
            sessions.insert(owner)
            reply(response(request)); return
        }
        guard sessions.contains(owner), !revoked.contains(owner) else { reply(response(request, error: "PERMISSION_DENIED")); return }
        guard ["show", "update", "list", "close"].contains(request.action) else { reply(response(request, error: "INVALID_ACTION")); return }
        guard request.action == "show" || (request.title == nil && request.incognito == nil),
              ["show", "update"].contains(request.action) || request.path == nil else { reply(response(request, error: "INVALID_REQUEST")); return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(request) else { reply(response(request, error: "INVALID_REQUEST")); return }
        let fingerprint = hash(encoded)
        let key = owner + ":" + request.request_id
        let now = Date()
        ledger = ledger.filter { $0.value.result == nil || $0.value.expires > now }
        if var existing = ledger[key] {
            guard existing.fingerprint == fingerprint else { reply(response(request, error: "REQUEST_ID_CONFLICT")); return }
            if let result = existing.result { reply(result) }
            else if existing.replies.count < AgentLimits.queue { existing.replies.append(reply); ledger[key] = existing }
            else { reply(response(request, error: "QUEUE_FULL")) }
            return
        }
        guard ledger.count < AgentLimits.ledger, jobs.count + (draining ? 1 : 0) < AgentLimits.queue else { reply(response(request, error: "QUEUE_FULL")); return }
        // 所有写操作共用有界 FIFO；同一窗口异步准备绝不越过先接受的操作。
        if ["show", "update"].contains(request.action) {
            guard let path = request.path, delivered.contains(where: { $0.path == path }) else { reply(response(request, error: "CONTENT_UNREADABLE")); return }
        }
        ledger[key] = Entry(fingerprint: fingerprint, expires: now.addingTimeInterval(AgentLimits.dedupSeconds), replies: [reply])
        jobs.append(Job(request: request, key: key, generation: controlGeneration, deadline: now.addingTimeInterval(requestTimeout)))
        timeouts[key] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(self?.requestTimeout ?? AgentLimits.timeout)) } catch { return }
            guard let self, self.ledger[key]?.result == nil else { return }
            let result = self.response(request, error: "TIMEOUT")
            let replies = self.ledger[key]?.replies ?? []
            self.ledger[key]?.result = result
            self.ledger[key]?.replies = []
            self.jobs.removeAll { $0.key == key }
            self.timeouts[key] = nil
            replies.forEach { $0(result) }
        }
        if !draining { draining = true; Task { await drain() } }
    }

    private func controller(_ request: AgentRequest) throws -> FloatingWindowController {
        guard let controller = delegate?.windowControllers.first(where: {
            $0.appState.agentOwnership?.boardID == request.board_id && $0.appState.agentOwnership?.owner == owner(request)
        }) else { throw AgentFailure("BOARD_NOT_FOUND") }
        return controller
    }

    private func validate(_ job: Job) throws {
        guard job.deadline > Date() else { throw AgentFailure("TIMEOUT") }
        guard sessions.contains(owner(job.request)), !revoked.contains(owner(job.request)) else { throw AgentFailure("PERMISSION_DENIED") }
        guard !paused, job.generation == controlGeneration else { throw AgentFailure("CONTROL_PAUSED") }
        if job.request.action != "show" {
            let controller = try controller(job.request)
            if let expected = job.request.expected_revision, controller.appState.agentOwnership?.revision != expected { throw AgentFailure("REVISION_CONFLICT") }
        }
    }

    private func drain() async {
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            var result = response(job.request)
            do {
                if job.request.action == "list" {
                    guard sessions.contains(owner(job.request)) else { throw AgentFailure("PERMISSION_DENIED") }
                    result.boards = (delegate?.windowControllers ?? []).compactMap {
                        let state = $0.appState
                        guard let ownership = state.agentOwnership, ownership.owner == owner(job.request) else { return nil }
                        return AgentBoard(board_id: ownership.boardID, revision: ownership.revision,
                                          title: state.customTitle ?? state.originalImageName ?? "", incognito: state.isIncognito)
                    }
                } else {
                    try validate(job)
                    if job.request.action == "close" {
                        let target = try controller(job.request)
                        result.board_id = target.appState.agentOwnership?.boardID
                        result.revision = target.appState.agentOwnership?.revision
                        target.close()
                    } else {
                        guard let path = job.request.path else { throw AgentFailure("INVALID_REQUEST") }
                        let url = URL(fileURLWithPath: path)
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let content = try await prepare(url)
                        try validate(job)
                        let target: FloatingWindowController
                        let initial = job.request.action == "show"
                        if initial {
                            guard let delegate else { throw AgentFailure("NOT_READY") }
                            guard delegate.windowControllers.filter({ $0.appState.agentOwnership != nil }).count < AgentLimits.windows else { throw AgentFailure("WINDOW_LIMIT") }
                            creations.removeAll { Date().timeIntervalSince($0) > 60 }
                            guard creations.count < 12 else { throw AgentFailure("RATE_LIMITED") }
                            let state = AppState(isIncognito: job.request.incognito == true)
                            state.agentOwnership = AgentOwnership(boardID: UUID().uuidString, owner: owner(job.request), caller: job.request.caller ?? "CLI", revision: 0)
                            state.commitAgentContent(content, title: job.request.title, initial: true)
                            target = FloatingWindowController(appState: state)
                            delegate.prepareNewWindowFrame(for: target)
                            delegate.addWindowController(target)
                            if !NSApp.isHidden { target.window?.orderFront(nil) }
                            creations.append(Date())
                        } else {
                            target = try controller(job.request)
                            target.appState.commitAgentContent(content, title: nil, initial: false)
                        }
                        target.appState.agentOwnership?.revision &+= 1
                        result.board_id = target.appState.agentOwnership?.boardID
                        result.revision = target.appState.agentOwnership?.revision
                        result.warnings = content.warnings
                        // Markdown 排版也纳入串行背压，避免高频更新堆积已取消但尚未退出的解析任务。
                        if content.kind == .markdown { await target.appState.renderTask?.value }
                    }
                }
            } catch {
                result = response(job.request, error: (error as? AgentFailure)?.code ?? "CONTENT_UNREADABLE")
            }
            let replies = ledger[job.key]?.replies ?? []
            if ledger[job.key]?.result == nil { ledger[job.key]?.result = result }
            ledger[job.key]?.replies = []
            timeouts.removeValue(forKey: job.key)?.cancel()
            replies.forEach { $0(result) }
        }
        draining = false
    }
}
