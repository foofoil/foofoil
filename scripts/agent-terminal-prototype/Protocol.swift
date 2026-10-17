import Foundation

// S07 实验协议，不能作为正式 CLI 或产品协议使用。
struct ProbeRequest: Codable {
    var id: UUID
    var action: String
    var path: String?
}

struct ProbeResponse: Codable {
    var id: UUID
    var action: String
    var ok: Bool
    var bytes: Int?
    var digest: String?
    var scopeStarted: Bool?
    var bookmarkCreated: Bool?
    var hidden: Bool
    var windows: Int
    var process: Int32
    var errorDomain: String?
    var errorCode: Int?
}
