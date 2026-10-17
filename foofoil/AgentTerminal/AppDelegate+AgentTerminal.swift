import AppKit
import Carbon

nonisolated private final class AgentEnvelope: @unchecked Sendable {
    let url: URL
    let scoped: Bool
    let handle: FileHandle
    init(_ url: URL) throws {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= AgentLimits.envelopeBytes else { throw AgentFailure("INVALID_REQUEST") }
            handle = try FileHandle(forUpdating: url)
        }
        catch { if scoped { url.stopAccessingSecurityScopedResource() }; throw error }
    }
    deinit {
        try? handle.close()
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
    func read() throws -> AgentRequest {
        let data = try handle.read(upToCount: AgentLimits.envelopeBytes + 1) ?? Data()
        guard data.count <= AgentLimits.envelopeBytes else { throw AgentFailure("INVALID_REQUEST") }
        return try JSONDecoder().decode(AgentRequest.self, from: data)
    }
    func reply(_ response: AgentResponse) {
        AgentContent.transport.async { [self] in
            do {
                let data = try JSONEncoder().encode(response)
                try handle.seek(toOffset: 0)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: data)
            } catch { /* 调用方超时或退出不撤销已提交结果；不记录正文或凭证。 */ }
        }
    }
}

extension AppDelegate {
    public func applicationWillFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--foil-agent") { didOpenFiles = true }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(receiveAgentOpenEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc private func receiveAgentOpenEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return }
        let urls = (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1)?.fileURLValue }
        let envelopes = urls.filter { $0.pathExtension == "foilrequest" }
        guard !envelopes.isEmpty else {
            // 普通 Finder／文件关联事件继续走既有用户打开流程。
            NSApp.unhide(nil)
            application(NSApp, open: urls)
            return
        }
        didOpenFiles = true
        guard urls.count <= 4, envelopes.count == 1, agentEnvelopeCount < AgentLimits.queue else { return }
        agentEnvelopeCount += 1
        let envelopeURL = envelopes[0]
        AgentContent.transport.async { [weak self] in
            do {
                let envelope = try AgentEnvelope(envelopeURL)
                let request = try envelope.read()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.agentTerminal.receive(request, delivered: urls.filter { $0 != envelopeURL }) { [weak self] result in
                        envelope.reply(result)
                        self?.agentEnvelopeCount -= 1
                    }
                }
            } catch {
                Task { @MainActor [weak self] in self?.agentEnvelopeCount -= 1 }
            }
        }
    }
}
