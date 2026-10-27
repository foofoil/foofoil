import Foundation

nonisolated enum AgentLimits {
    static let protocolVersion = 1
    static let envelopeBytes = 32_768
    static let fileBytes = 16 * 1_048_576
    static let textBytes = 2 * 1_048_576
    static let imagePixels = 24_000_000
    static let imageDimension = 16_384
    static let queue = 16
    static let windows = 32
    static let sessions = 32
    static let ledger = 1024
    static let dedupSeconds: TimeInterval = 600
    static let timeout: TimeInterval = 30
}

nonisolated struct AgentRequest: Codable, Sendable {
    var protocol_version = AgentLimits.protocolVersion
    var request_id = UUID().uuidString
    var action: String
    var run_id: String?
    var credential: String?
    var caller: String?
    var board_id: String?
    var path: String?
    var title: String?
    var incognito: Bool?
    var expected_revision: UInt64?
    var scope: String?
    var force: Bool?
    var terminal: TerminalLaunchConfiguration?
    var property: String?
    var value: Double?
}

nonisolated struct AgentBoard: Codable, Sendable {
    var board_id: String
    var revision: UInt64
    var title: String
    var incognito: Bool
}

nonisolated struct AgentResponse: Codable, Sendable {
    var protocol_version = AgentLimits.protocolVersion
    var request_id: String
    var run_id: String
    var status = "ready"
    var board_id: String?
    var revision: UInt64?
    var boards: [AgentBoard]?
    var warnings: [String] = []
    var error: String?
    var capabilities: [String]?
    var socket_path: String?
    var windows: [ControlWindow]?
    var window: ControlWindow?
}

/// 只持久化用户配置；不保存继承环境、终端输出、PID 或会话身份。
nonisolated public struct TerminalLaunchConfiguration: Codable, Sendable, Equatable {
    public var shellPath: String?
    public var workingDirectory: String?
    public var environment: [String: String]
    public var startupCommands: String
    public init(shellPath: String? = nil, workingDirectory: String? = nil,
                environment: [String: String] = [:], startupCommands: String = "") {
        self.shellPath = shellPath; self.workingDirectory = workingDirectory
        self.environment = environment; self.startupCommands = startupCommands
    }

    /// 启动与历史复用共用标准化目录，使 ~、尾斜杠和等价的相对分量不制造不同身份。
    var resolvedWorkingDirectory: String {
        NSString(string: workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path).standardizingPath
    }

    var abbreviatedWorkingDirectory: String {
        (resolvedWorkingDirectory as NSString).abbreviatingWithTildeInPath
    }
}

nonisolated struct ControlWindow: Codable, Sendable {
    var id: String
    var content_id: String
    var title: String
    var type: String
    var visible: Bool
    var opacity: Double
    var terminal_state: String?
    var terminal_id: String?
    var board_id: String?
}
