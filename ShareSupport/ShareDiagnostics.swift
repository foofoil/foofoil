import OSLog

/// 只记录交接阶段、数量和错误码，不记录共享内容或文件路径。
nonisolated enum ShareDiagnostics {
    static let logger = Logger(subsystem: "com.markonce.foofoil", category: "Sharing")
}
