import Foundation
import Darwin

/// 独立前置实验；不接入产品，不扩大权限，不读取真实用户配置。
@MainActor
final class CapabilityProbe {
    private var listener: Int32 = -1
    private var directory: URL?

    func reset() {
        if listener >= 0 { Darwin.close(listener); listener = -1 }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    func startSocket() throws -> [String: String] {
        reset()
        // 短路径避免 Darwin sockaddr_un 的 104 字节上限；目录仅由本次实例持有。
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("p-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        directory = root
        let path = root.appendingPathComponent("s").path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CocoaError(.fileWriteInvalidFileName) }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw posixError() }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, chmod(path, 0o600) == 0,
              listen(listener, 1) == 0, fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else { throw posixError() }
        return ["path": path, "uid": String(getuid())]
    }

    func pollSocket() throws -> [String: String] {
        guard listener >= 0 else { throw CocoaError(.featureUnsupported) }
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { throw posixError() }
        defer { Darwin.close(connection) }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(connection, &uid, &gid) == 0 else { throw posixError() }
        guard uid == getuid() else { throw CocoaError(.fileReadNoPermission) }
        // 实验只发送常量，不等待不受信任客户端输入；避免占住 AppKit 主线程。
        let message = Array("probe-ok\n".utf8)
        let count = message.withUnsafeBytes { Darwin.send(connection, $0.baseAddress, $0.count, 0) }
        guard count == message.count else { throw posixError() }
        return ["peer_uid": String(uid), "bytes": String(count)]
    }

    func shell(path: String, tool: Bool = false, bash: Bool = false) throws -> [String: String] {
        let process = Process()
        process.executableURL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("pty-probe")
        process.arguments = [bash ? "/bin/bash" : "/bin/zsh", path] + (tool ? ["tool"] : [])
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // helper 自带硬超时、输出上限和子进程回收；此实验不运行用户启动脚本。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ["status": String(process.terminationStatus), "output": String(decoding: data, as: UTF8.self)]
    }
}
