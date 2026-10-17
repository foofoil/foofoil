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
}
