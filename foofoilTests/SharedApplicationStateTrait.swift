import Testing

/// 不同 suite 的 .serialized 不会互相排斥；访问应用单例的测试必须共享同一把异步锁。
nonisolated struct SharedApplicationStateTrait: SuiteTrait, TestTrait, TestScoping {
    typealias TestScopeProvider = Self
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
        await SharedApplicationStateLock.shared.acquire()
        do {
            try await function()
            await SharedApplicationStateLock.shared.release()
        } catch {
            await SharedApplicationStateLock.shared.release()
            throw error
        }
    }
}

extension Trait where Self == SharedApplicationStateTrait {
    nonisolated static var sharedApplicationState: Self { Self() }
}

private actor SharedApplicationStateLock {
    static let shared = SharedApplicationStateLock()
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { isHeld = false }
        else { waiters.removeFirst().resume() }
    }
}

/// 并发回调共享可变测试输入时，用主 actor 隔离的引用保存，避免捕获可变局部变量。
@MainActor
final class MainActorTestValue<Value> {
    var value: Value

    init(_ value: Value) { self.value = value }
}
