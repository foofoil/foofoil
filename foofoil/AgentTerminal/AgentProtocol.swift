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
    var boolean_value: Bool?
    var offset: Int?
    var limit: Int?
    var content_version: String?
    var target_id: String?
    var source: String?
    var query: String?
    var operation_id: String?
    var page: Int?
    var line: Int?
    var progress: Double?
    var tail: Int?
    var url: String?
    var clipboard: Bool?
    var output: String?
    var format: String?
    var overwrite: Bool?
    var text_value: String?
    var screen_id: String?
    var frame: AgentFrame?
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
    var next_offset: Int?
    var content_version: String?
    var window: ControlWindow?
    var text_page: AgentTextPage?
    var outline: AgentOutlinePage?
    var operation: AgentOperation?
    var availability: [AgentCapability]?
    var media: AgentMediaState?
    var configuration: [AgentConfiguration]?
    var permissions: [AgentPermission]?
    var history: [AgentHistoryItem]?
    var search: AgentSearchPage?
    var screens: [AgentScreen]?
    var output: String?
    var privacy: AgentPrivacyResult?
    var app_version: String?
    var app_build: String?
    var retryable: Bool?
    var recovery: String?
}

nonisolated struct AgentNavigationTarget: Codable, Sendable {
    var contribution_id: String
    var item_id: String
}

nonisolated struct AgentOutlineItem: Codable, Sendable {
    var target_id: String
    var contribution_id: String
    var item_id: String
    var parent_id: String?
    var title: String
    var enabled: Bool
    var current: Bool
}

nonisolated struct AgentOutlinePage: Codable, Sendable {
    var content_id: String
    var content_version: String
    var items: [AgentOutlineItem]
    var next_offset: Int?
}

nonisolated struct AgentTextPage: Codable, Sendable {
    var content_id: String
    var content_version: String
    var text: String
    var offset: Int
    var next_offset: Int?
    var truncated: Bool
    var offset_unit = "unicode_scalar"
}

/// 只持久化用户配置；不保存继承环境、终端输出、PID 或会话身份。
nonisolated public struct TerminalLaunchConfiguration: Codable, Sendable, Equatable {
    public struct SSH: Codable, Sendable, Equatable {
        public var host: String
        public var username: String
        public var port: Int
        public init(host: String, username: String, port: Int = 22) {
            self.host = host; self.username = username; self.port = port
        }
    }
    public var ssh: SSH?
    public var shellPath: String?
    public var workingDirectory: String?
    public var environment: [String: String]
    public var startupCommands: String
    public init(shellPath: String? = nil, workingDirectory: String? = nil,
                environment: [String: String] = [:], startupCommands: String = "", ssh: SSH? = nil) {
        self.ssh = ssh
        self.shellPath = shellPath; self.workingDirectory = workingDirectory
        self.environment = environment; self.startupCommands = startupCommands
    }

    /// 启动与历史复用共用标准化目录，使 ~、尾斜杠和等价的相对分量不制造不同身份。
    var resolvedWorkingDirectory: String {
        NSString(string: workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path).standardizingPath
    }

    /// 搜索结果展示连接地址与实际目录；SSH 未指定目录时使用远端主目录，不套用本机路径。
    var historySubtitle: String {
        if let ssh {
            let host = ssh.port == 22 ? ssh.host : "\(ssh.host):\(ssh.port)"
            let directory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
            return host + " · " + (directory.flatMap { $0.isEmpty ? nil : $0 } ?? "~")
        }
        return (resolvedWorkingDirectory as NSString).abbreviatingWithTildeInPath
    }

    var abbreviatedWorkingDirectory: String {
        if let ssh {
            let path = workingDirectory.flatMap { $0.isEmpty ? nil : $0 }
            return "\(ssh.username)@\(ssh.host)" + (path.map { ":\($0)" } ?? "")
        }
        return (resolvedWorkingDirectory as NSString).abbreviatingWithTildeInPath
    }
}

nonisolated struct ControlWindow: Codable, Sendable {
    var id: String
    var content_id: String
    var title: String
    var type: String
    var visible: Bool
    var is_loading: Bool
    var observed_at: String
    var incognito: Bool
    var opacity: Double
    var pinned: Bool
    var border: Bool
    var terminal_state: String?
    var terminal_id: String?
    var board_id: String?
    var content_revision: String? = nil
    var state_revision: String? = nil
    var read_only: Bool? = nil
    var load_error: String? = nil
    var location: AgentLocation? = nil
    var screen_id: String? = nil
    var zoom: Double? = nil
    var navigator: String? = nil
    var frame: AgentFrame? = nil
}

nonisolated struct AgentOperation: Codable, Sendable {
    var id: String
    var window_id: String
    var status: String
    var error: String?
    var created_at: String
}
nonisolated struct AgentCapability: Codable, Sendable {
    var name: String
    var available: Bool
    var reason: String?
}
nonisolated struct AgentMediaState: Codable, Sendable {
    var playing: Bool
    var current_time: Double?
    var duration: Double?
    var volume: Double?
    var muted: Bool?
    var mode: String
    var pending: Bool
    var state: String = "paused"
    var error: String? = nil
    var current_item_id: String? = nil
}
nonisolated struct AgentConfiguration: Codable, Sendable {
    var key: String
    var type: String
    var value: String
    var default_value: String
    var minimum: Double? = nil
    var maximum: Double? = nil
    var choices: [String]? = nil
    var dependencies: [String] = []
    var scope = "application"
    var immediate = true
    var restart_required = false
}
nonisolated struct AgentPermission: Codable, Sendable {
    var name: String
    var status: String
    var action_required: Bool
}
nonisolated struct AgentHistoryItem: Codable, Sendable {
    var id: String
    var title: String
    var type: String
    var snippet: String?
}
nonisolated struct AgentSearchMatch: Codable, Sendable {
    var offset: Int
    var length: Int
    var snippet: String
    var line: Int
}
nonisolated struct AgentSearchPage: Codable, Sendable {
    var content_version: String
    var matches: [AgentSearchMatch]
    var next_offset: Int?
    var offset_unit = "unicode_scalar"
}
nonisolated struct AgentFrame: Codable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}
nonisolated struct AgentScreen: Codable, Sendable {
    var id: String
    var frame: AgentFrame
}
nonisolated struct AgentPrivacyResult: Codable, Sendable {
    var incognito: Bool
    var history_action: String
    var participates_in_restore: Bool
    var terminal_output_persisted: Bool
}

nonisolated enum AgentRunIdentity { static let id = UUID().uuidString }

nonisolated struct AgentLocation: Codable, Sendable {
    var page: Int? = nil
    var line: Int? = nil
    var progress: Double? = nil
}
