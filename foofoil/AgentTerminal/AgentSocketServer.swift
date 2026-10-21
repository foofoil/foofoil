import Foundation
import Darwin

/// 只处理传输；16 个连接和短入站超时限制资源，所有业务回到同一主 actor 控制入口。
nonisolated final class AgentSocketServer: @unchecked Sendable {
    let path: String
    private let queue = DispatchQueue(label: "com.foofoil.control.socket")
    private let workers = DispatchQueue(label: "com.foofoil.control.clients", attributes: .concurrent)
    private var active = 0
    private let source: DispatchSourceRead
    private let root: URL
    private let handler: @Sendable (AgentRequest, @escaping @Sendable (AgentResponse) -> Void) -> Void

    init(handler: @escaping @Sendable (AgentRequest, @escaping @Sendable (AgentResponse) -> Void) -> Void) throws {
        self.handler = handler
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ff-\(UUID().uuidString.prefix(12))")
        path = root.appendingPathComponent("s").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: root); throw AgentTransportFailure(code: "ENDPOINT_UNAVAILABLE") }
        do {
            var address = try AgentSocketIO.address(path)
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            } }
            guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw AgentTransportFailure(code: "ENDPOINT_UNAVAILABLE") }
        } catch { Darwin.close(fd); try? FileManager.default.removeItem(at: root); throw error }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let ownedRoot = root
        source.setCancelHandler { Darwin.close(fd); try? FileManager.default.removeItem(at: ownedRoot) }
        source.setEventHandler { [weak self] in self?.acceptConnections(fd) }
        source.resume()
    }
    deinit { source.cancel() }
    func stop() { source.cancel() }

    private func acceptConnections(_ listener: Int32) {
        // 每次回调有界，防止连接洪水占满串行监听队列。
        for _ in 0..<16 {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            guard active < 16 else { Darwin.close(fd); continue }
            var uid: uid_t = 0; var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { Darwin.close(fd); continue }
            active += 1
            guard fcntl(fd, F_SETFL, 0) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { Darwin.close(fd); active -= 1; continue }
            workers.async { [self] in
                defer { Darwin.close(fd); queue.async { self.active -= 1 } }
                AgentSocketIO.configure(fd, seconds: 2)
                do {
                    let data = try AgentSocketIO.read(fd, limit: AgentLimits.envelopeBytes, deadline: Date().addingTimeInterval(5))
                    let request = try JSONDecoder().decode(AgentRequest.self, from: data)
                    let reply = SocketReply()
                    handler(request) { reply.complete($0) }
                    guard reply.done.wait(timeout: .now() + 33) == .success, let response = reply.value() else { return }
                    AgentSocketIO.configure(fd, seconds: 5)
                    try AgentSocketIO.write(JSONEncoder().encode(response), to: fd)
                } catch { /* 无效信封直接断开；不记录请求正文、路径或凭证。 */ }
            }
        }
    }
}

nonisolated private final class SocketReply: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var response: AgentResponse?
    func complete(_ value: AgentResponse) { lock.lock(); response = value; lock.unlock(); done.signal() }
    func value() -> AgentResponse? { lock.lock(); defer { lock.unlock() }; return response }
}
