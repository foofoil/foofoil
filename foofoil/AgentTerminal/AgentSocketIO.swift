import Foundation
import Darwin

nonisolated struct AgentTransportFailure: Error { let code: String }

/// 单连接单请求，4 字节网络序长度 + UTF-8 JSON；每次交换有绝对截止时间及大小上限。
nonisolated enum AgentSocketIO {
    static let responseBytes = 1_048_576
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AgentTransportFailure(code: "ENDPOINT_UNAVAILABLE") }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in bytes.withUnsafeBytes { destination.copyBytes(from: $0) } }
        return address
    }
    static func configure(_ fd: Int32, seconds: Int) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
    static func read(_ fd: Int32, limit: Int, deadline: Date) throws -> Data {
        func exact(_ count: Int) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: count)
            var offset = 0
            while offset < count {
                guard Date() < deadline else { throw AgentTransportFailure(code: "TIMEOUT") }
                let received = bytes.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
                if received < 0, errno == EINTR { continue }
                guard received > 0 else { throw AgentTransportFailure(code: "TRANSPORT_ERROR") }
                offset += received
            }
            return bytes
        }
        let header = try exact(4)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= limit else { throw AgentTransportFailure(code: "INVALID_REQUEST") }
        return Data(try exact(length))
    }
    static func write(_ data: Data, to fd: Int32) throws {
        guard data.count <= responseBytes else { throw AgentTransportFailure(code: "RESPONSE_TOO_LARGE") }
        let length = UInt32(data.count)
        let packet = Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)]) + data
        var offset = 0
        let deadline = Date().addingTimeInterval(5)
        while offset < packet.count {
            guard Date() < deadline else { throw AgentTransportFailure(code: "TIMEOUT") }
            let sent = packet.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), packet.count - offset, 0) }
            if sent < 0, errno == EINTR { continue }
            guard sent > 0 else { throw AgentTransportFailure(code: "TRANSPORT_ERROR") }
            offset += sent
        }
    }
    static func exchange(_ request: AgentRequest, path: String) throws -> AgentResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentTransportFailure(code: "ENDPOINT_UNAVAILABLE") }
        defer { Darwin.close(fd) }
        configure(fd, seconds: 5)
        var address = try address(path)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
        guard connected == 0 else { throw AgentTransportFailure(code: "ENDPOINT_UNAVAILABLE") }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw AgentTransportFailure(code: "PERMISSION_DENIED") }
        let data = try JSONEncoder().encode(request)
        guard data.count <= AgentLimits.envelopeBytes else { throw AgentTransportFailure(code: "INVALID_REQUEST") }
        try write(data, to: fd)
        configure(fd, seconds: 35)
        let response = try JSONDecoder().decode(AgentResponse.self, from: read(fd, limit: responseBytes, deadline: Date().addingTimeInterval(35)))
        guard response.request_id == request.request_id, response.run_id == request.run_id else { throw AgentTransportFailure(code: "PROTOCOL_MISMATCH") }
        return response
    }
}
