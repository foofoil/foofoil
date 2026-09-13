//  LocalHTTPServer.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/13.
//

import Foundation
import Network

/// 测试用最小 HTTP 服务：返回空 200 并计数收到的请求，用于验证文档视图没有网络出口。
final class LocalHTTPServer: @unchecked Sendable {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func snapshot() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private let listener: NWListener
    private let queue: DispatchQueue
    private let counter: Counter

    let port: UInt16

    init() throws {
        let queue = DispatchQueue(label: "foofoil.tests.local-http")
        let counter = Counter()
        self.queue = queue
        self.counter = counter

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, _ in
                counter.increment()
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let rawPort = listener.port?.rawValue else {
            listener.cancel()
            throw NSError(domain: "LocalHTTPServer", code: 1)
        }
        port = rawPort
    }

    func requestCount() -> Int {
        counter.snapshot()
    }

    func stop() {
        listener.cancel()
    }
}
